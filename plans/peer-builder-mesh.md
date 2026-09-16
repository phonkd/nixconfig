# Peer builder mesh

**Repo(s):** nixconfig   **Status:** draft

## Goal

Stop 205-builder being the single point of build throughput. Let a rebuild fan
its derivations out across every *fat, reachable* tailnet host at once, so a big
closure finishes in the time the slowest derivation takes rather than the time
205 takes to grind the whole list.

Two hard requirements from the ask:

1. **A dead peer must cost < 5s**, not a two-minute TCP stall. Roaming laptops
   and a desktop that has been offline 16 days are normal here, so "the builder
   is down" is the common case, not the exception.
2. **Non-205 peers clean up after themselves.** 205's warm store is an asset
   (it is the de-facto cache, and `plans/binary-cache.md` wants to serve it over
   HTTP). A laptop's store filling with someone else's build spoil is not.

## What is there now

Single builder, everyone points at it:

- `modules/hosts/types/server/builder.nix:15` — `builder-client`: two
  `nix.buildMachines` entries, both `100.64.0.2` (native x86_64-linux, and
  aarch64-linux via 205's qemu-user binfmt). Imported by every oldblac VM and by
  blac / g14 / z14 via `extraModules` in `lib/registry.nix`.
- `modules/hosts/types/server/builder.nix:88` — `builder-server`: the `nixremote`
  account, its authorized key, `trusted-users`, `max-jobs = 8`. Imported only by
  205.
- `modules/hosts/205-builder.nix:49` — 205 `mkForce`-disables the client wiring
  it inherits via `oldblac-vm` so it never offloads to itself. **This
  self-exclusion pattern is the one the mesh generalises.**
- `modules/hosts/mac.nix:193` — the Mac hand-rolls the same two entries.

One shared `nixremote` keypair (private half in sops, public half authorized on
205) already does all the auth. The mesh reuses it rather than growing an N²
key matrix.

## Measured inventory

Taken live over the tailnet while writing this plan — not guessed.

| host | tailnet IP | cores | RAM | free on /nix | verdict |
|---|---|---|---|---|---|
| 205-builder | 100.64.0.2 | 12 | 15G | 98G | **primary**, keep store warm |
| g14 | 100.64.0.9 | 16 | 22G | 94G | **peer** — fattest box in the fleet |
| z14 | 100.64.0.17 | 12 | 25G | 416G | **peer** — most disk by far |
| blac | 100.64.0.13 | ? | ? | ? | **peer**, but offline 16d — Phase 3 |
| 201-mono | 100.64.0.5 | 8 | 15G | 96G | exclude — reverse proxy, see below |
| 203-media | 100.64.0.3 | 8 | 31G | 43G | exclude — tightest disk, runs ollama |
| 204-agent | 100.64.0.1 | 4 | **3G** | 83G | exclude — will OOM on `big-parallel` |
| observability | 100.64.0.4 | — | — | — | exclude — offsite (Hetzner), WAN closure copies |
| ext-mail | 100.64.0.19 | — | — | — | exclude — offsite |
| mac | 100.64.0.6 | — | — | — | can't build linux; darwin-only, out of scope |

**So the answer to "all my machines" is no, and deliberately so.** Adding
204-agent (3 GB RAM) hands kernel/chromium-class derivations to a box that will
OOM and fail the client's whole build. Adding 201-mono lets a build storm eat the
8 cores that front every service in the homelab. Adding the Hetzner pair means
pushing and pulling closures over WAN to save local CPU that isn't scarce. The
mesh worth building is **205 + g14 + z14 (+ blac)** — four fat x86_64-linux
boxes, ~52 cores between them.

**Wrinkle spotted:** z14 is enrolled in headscale under the node name
`g14-irpwhkmw` (100.64.0.17), not `z14`. Addressing peers by IP sidesteps it, but
it will confuse anyone reading `tailscale status`. Worth a separate re-enroll;
not a blocker for this plan.

## Approach

### Registry-driven builder list

`lib/registry.nix` is already the single source of truth for hosts, so the
builder facts belong there rather than hand-maintained in three places (the two
`builder.nix` lists plus `mac.nix`). Add an optional stanza:

```nix
builder = {
  ip = "100.64.0.9";
  maxJobs = 8;
  speedFactor = 3;
  supportedFeatures = [ "big-parallel" "kvm" "nixos-test" "benchmark" ];
};
```

`builder-client` then derives `nix.buildMachines` from every registry host that
has a `builder` stanza, **filtered to exclude the host it is evaluating on**.
That one filter replaces 205's `mkForce`-to-empty hack and makes self-exclusion
automatic for every future peer.

`speedFactor` is a *preference* dial, not a measurement — nix prefers higher
values when choosing where to send the next job. Proposed: 205 = 4 (always on,
dedicated), g14 = 3, z14 = 3, blac = 2 (when it is up at all). Laptops get
`maxJobs` at roughly half their core count so a build burst doesn't make the
machine unusable for the person typing on it.

### Requirement 1 — sub-5s failover

`nix.buildMachines` has **no timeout field**; the ssh connect timeout comes from
ssh config. The build hook runs as root under nix-daemon, so it must be the
*system* config, not the user's:

```nix
programs.ssh.extraConfig = ''
  Host 100.64.0.*
    ConnectTimeout 3
    ServerAliveInterval 5
    ServerAliveCountMax 2
'';
```

`ConnectTimeout` only bounds the TCP connect — it is what turns "peer is
asleep" from a ~2 min kernel retry into 3s. `ServerAliveInterval` /
`ServerAliveCountMax` cover the other half: a peer that vanishes *mid-build*
(laptop lid closed), which `ConnectTimeout` would never catch.

Worst case is additive: 3 dead peers ≈ 9s before the build lands somewhere, and
it does land — nix walks to the next machine on a connection failure, falling
back to local. That additive cost is exactly why the ceiling has to be low.

Verify during implementation that the nix-daemon's ssh actually reads
`/etc/ssh/ssh_config` on both NixOS and nix-darwin; if darwin disagrees, the
fallback is `NIX_SSHOPTS = "-o ConnectTimeout=3 ..."` in the daemon's
environment. Don't assume — test it with a deliberately-downed peer (step 7).

### Requirement 2 — peers clean up right after the build

**Why aggressive GC is safe on a peer and not on 205:** a path a peer built for
someone else has *no GC root* on that peer once the requesting client has copied
it back. Plain `nix-collect-garbage` — no `-d`, no `--delete-older-than` —
deletes exactly those unreachable paths and leaves every system generation
intact. The peer's own rollback history is untouched; only foreign spoil goes.
On 205 the same sweep would throw away the warm store that makes the next
rebuild a copy instead of a compile, which is the entire point of having a
dedicated builder.

New `builder-peer` module, imported by g14 / z14 / blac and **not** by 205:

1. **Debounced post-build sweep** — nix's `post-build-hook` fires after each
   derivation. Running GC inline there is wrong: GC takes a global store lock
   and would serialize a parallel build burst. Instead the hook re-arms a
   transient timer each time it fires:

   ```
   systemd-run --unit=nix-peer-gc --on-active=120 \
     nix-collect-garbage    # no -d: generations survive
   ```

   Re-arming replaces the pending unit, so the sweep runs ~2 min after the
   *last* build of the burst, not after each one. That is the literal
   "immediately after the build is finished" behaviour, debounced enough to not
   fight the build it is cleaning up after.

2. **`min-free` / `max-free` safety net** — the mechanism that actually prevents
   the failure mode. The daemon GCs *during* a build when free space drops below
   `min-free`, freeing up to `max-free`:

   ```nix
   nix.settings.min-free = 20 * 1024 * 1024 * 1024;  # 20G
   nix.settings.max-free = 60 * 1024 * 1024 * 1024;  # 60G
   ```

   The timer handles the steady state; this handles a single closure bigger than
   the free space, which no after-the-fact sweep can.

205 keeps what it has (weekly GC / 30d retention, `nix.optimise.automatic`), and
gains only a low `min-free` floor as pure insurance.

## Steps

1. **Registry** — add the `builder` stanza shape to the field docs at the top of
   `lib/registry.nix`, and fill it in for `205-builder` only. No behaviour change
   yet.
2. **`builder-client` reads the registry** — derive `nix.buildMachines` from
   registry hosts with a `builder` stanza, excluding self. Drop the hardcoded
   pair. Keep the aarch64-linux-via-binfmt entry as a property of 205's stanza
   (a peer without `boot.binfmt.emulatedSystems` must not advertise it).
3. **Delete 205's `mkForce` self-exclusion** (`modules/hosts/205-builder.nix:49`)
   — step 2's filter subsumes it. Confirm by evaluating that 205's
   `buildMachines` is empty while the mesh is still one host.
4. **Mac** — point `modules/hosts/mac.nix:193` at the same derived list instead
   of its hand-rolled copy.
5. **ssh timeouts** — the `Host 100.64.0.*` block above, into `builder-client`
   so every build client gets it.
6. **`builder-peer` module** — the post-build hook + `min-free`/`max-free` from
   the section above. Written now, imported by nobody yet.
7. **Deploy Phase 1 and verify no regression.** `deploy` each VM + the Mac. The
   mesh is still one builder, so a clean run proves the refactor is inert.
   Then prove the timeout: `sudo tailscale down` on 205, time a build, confirm
   the stall is ~3s and the build completes locally. Bring it back up.
8. **Phase 2 — g14 and z14 become builders.** Add their `builder` stanzas, and
   import `builder-server` + `builder-peer` on both. Seed host keys into
   `programs.ssh.knownHosts` alongside 205's existing pin. Deploy both.
9. **Verify the mesh.** `nix store ping --store ssh://nixremote@100.64.0.9`
   from a client; then a real rebuild with `-L`, watching log lines attribute
   derivations to different machines. Confirm the GC timer fires: `systemctl
   list-timers | grep nix-peer-gc` shortly after, and that `nix-env --list-
   generations --profile /nix/var/nix/profiles/system` on z14 is unchanged.
10. **Phase 3 — blac**, once it is online (offline 16d as of writing). Same as
    step 8, `speedFactor = 2`.
11. Mark this plan `done`.

## Open decisions

- **201-mono as a low-priority peer.** Recommended **out**: 8 cores that front
  every service in the homelab, and this repo's own rules flag 201 as
  risky-by-default. If you want the cores anyway, `maxJobs = 2` +
  `speedFactor = 1` so it only ever gets overflow. Your call — it is the one
  exclusion above that is a judgement rather than a hardware fact.
- **Sweep debounce window.** 120s is a guess that trades store churn against
  disk headroom. If a peer is also a client (laptops are), a short window can
  delete paths it is about to want again. 5–10 min is the conservative
  alternative; `min-free` makes the window non-critical either way.
- **`nix-collect-garbage` vs `--delete-older-than 7d` on peers.** The former
  (recommended) keeps every generation and sweeps only unrooted foreign paths.
  The latter also trims the peer's own rollback history — more space, less
  safety net on a machine you actually use.
- **Laptops and `big-parallel`.** Advertising it means a laptop can be handed a
  kernel/chromium build; if the lid closes mid-build the client's build fails
  (nix re-dispatches on a *connection* failure, but a mid-build drop is not
  reliably retried). Dropping `big-parallel` from laptop stanzas costs some
  parallelism and removes the sharpest edge. Recommended: keep it on z14
  (desk-bound most of the time, 416G disk), drop it on g14 if it turns out to
  roam more.

## Risks / rollout

- **Laptop suspends mid-build → client build fails.** The main new failure mode.
  Mitigated by `ServerAliveInterval` (fails fast rather than hanging) and by the
  `big-parallel` decision above. Worst case is a retry, not a broken host.
- **New passwordless-ssh build account on personal machines.** g14/z14/blac gain
  the `nixremote` account that 205 has had all along. Same key, same tailnet ACL,
  and these are all your machines — but it is a real if small widening of
  attack surface on boxes that previously accepted no build jobs.
- **Trust.** A peer builder produces store paths its clients import. Already true
  of 205; the mesh multiplies it by the number of peers.
- **Circular offload.** Prevented structurally by the self-exclusion filter
  (step 2) rather than by remembering to `mkForce` each new peer.
- **Rollout** is phased precisely so each phase is separately reversible:
  Phase 1 is a pure refactor and should change nothing observable; Phase 2 adds
  two peers; Phase 3 adds a third.
- **Back out** by deleting the `builder` stanza for the offending peer and
  redeploying clients — the filter drops it from every client's list with no
  other edit. A total revert is `git revert` of the phase commit + `deploy`.
- **Deploys:** every build client (all oldblac VMs + the Mac) in Phase 1, then
  g14/z14 in Phase 2, blac in Phase 3.
