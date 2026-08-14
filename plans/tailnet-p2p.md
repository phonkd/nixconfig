# tailnet p2p (direct paths instead of DERP)

**Repo(s):** nixconfig (+ UniFi console, Hetzner console, Cloudflare DNS)
**Status:** draft

## Goal

Remote clients currently reach every homelab host over the **DERP relay on
observability** (Hetzner, Helsinki) instead of a direct WireGuard path. Every
byte of remote traffic to traefik/jellyfin/ssh takes a round trip through
Finland. Make the homelab directly reachable so remote sessions are peer-to-peer.

Internal traffic is already fine — this is purely about the remote case.

## Measured baseline (2026-08-14)

Diagnosis done from g14 tethered to the OnePlus hotspot. Facts, so nobody
re-derives them:

- **UniFi NAT is already ideal — nothing to fix there.** Same source port to two
  independent STUN servers returns the same external port, and it preserves the
  source port:
  ```
  local source port: 39342
    stun.l.google.com   -> 85.195.231.133:39342
    stun.cloudflare.com -> 85.195.231.133:39342
  ```
  That is endpoint-independent, port-preserving NAT (cone). Ideal for hole
  punching.
- **Internal traffic is already direct**, including cross-subnet
  (201/205 on `192.168.3.x`, 203 on `192.168.1.x`):
  ```
  201 -> 205  via 192.168.3.205:41641  1ms
  201 -> 203  via 192.168.1.203:41641  1ms
  201 -> obs  via 89.167.83.90:41641  30ms
  ```
  The `relay "headscale"` shown by `tailscale status` for idle peers is normal —
  Tailscale only upgrades to a direct path once there is traffic. Use
  `tailscale ping`, not `status`, to judge this.
- **The blocker is the client side.** The phone hotspot is **symmetric NAT** —
  same source port, different external port per destination:
  ```
  local source port: 37996
    stun.l.google.com   -> 194.230.147.11:40308
    stun.cloudflare.com -> 194.230.147.11:61334
  ```
  Symmetric NAT cannot be hole-punched. This is why g14→obs *is* direct (obs has
  a real public IP, nothing to punch) while g14→homelab is not.
- **Both 201 and 205 already bind UDP 41641** (the nixpkgs
  `services.tailscale.port` default), and `openFirewall = true` already opens it.
- `MappingVariesByDestIP` is blank in every `netcheck` because the DERP map has a
  single region with one node — Tailscale needs two STUN IPs to classify NAT, so
  it is somewhat blind here. Not the blocker, but worth knowing.

## Approach

Two independent fixes. **Phase 1 is the whole win for the common case** and costs
one UniFi rule; Phase 2 is a longer-term cleanup gated on external actions.

A symmetric-NAT client can always reach a *publicly reachable* endpoint. So
making one homelab host publicly reachable on UDP fixes remote access regardless
of how bad the client's NAT is — no per-client work, no UPnP.

### Phase 1 — one port forward to 201-mono

**201, not 205.** Three reasons:

1. **201 is the traefik entry point.** Split DNS resolves `home.phonkd.net` →
   `100.64.0.5` (201), so every homelab web service hit remotely terminates
   there. Making 201 directly reachable puts the traffic that actually matters on
   a direct path.
2. **201 already advertises exit node** (`--advertise-exit-node`,
   `modules/tailnet.nix`), and g14 already has `--operator=phonkd`, so the exit
   node can be selected without sudo. 205 would need that added.
3. **Exit-node-via-201 also covers the LAN.** With 201 as exit node, traffic to
   `192.168.1.x`/`192.168.3.x` follows the default route into 201, which sits on
   those networks — so LAN-IP access to the other hosts rides the same direct
   path.

**Why not 205-builder:** selecting an exit node does **not** route tailnet peer
traffic through it — exit nodes carry only non-tailnet (internet) traffic.
Traffic to `100.64.0.x` peers keeps its own per-peer session. So a forward to 205
would fix internet egress and leave all traefik-fronted services still relayed.
205 only helps Nix build offload, and the machine that offloads to it (the Mac)
is normally at home and already direct.

### Phase 2 — IPv6 (removes NAT from the picture entirely)

Blocked on external actions, and **will not help the phone hotspot** (see Risks).
Worth doing for any v6-capable remote network.

`obs` is the only DERP region, and Tailscale decides whether it has usable IPv6
by probing DERP over v6. With a v4-only DERP every client reports `IPv6: no` and
will not attempt v6 paths — even 201 and 205, which already have native global v6
(`2a02:168:b066::/64`). So giving obs an IPv6 is the prerequisite for everything
else here.

Hetzner metadata confirms obs is a **v4-only server** (no `public-ipv6` key, and
`network-config` lists only `ipv4: true`), so this needs a console action.

## Steps

### Phase 1

1. [ ] **UniFi**: add a port-forward rule.
   ```
   Protocol     : UDP
   WAN port     : 41641
   Forward IP   : 192.168.3.201
   Forward port : 41641
   ```
   No repo change — 201 already listens on 41641.
2. [ ] **Verify** from an off-LAN client: `tailscale ping 100.64.0.5` should
   report `via 85.195.231.133:41641`, not `via DERP(headscale)`.
3. [ ] **Harden the dependency** (repo): pin `services.tailscale.port = 41641` in
   `modules/tailnet.nix` with a comment noting that a NAT forward depends on it,
   so a future nixpkgs default change can't silently break remote access.
   **Deploy this over the LAN** — see Risks.
4. [ ] **Usage note** for g14 on the hotspot:
   `tailscale set --exit-node=201-mono`, and `tailscale set --exit-node=` to stop.
   It is a persisted pref and survives reboots.

### Phase 2

5. [ ] **Hetzner Cloud console** → obs → Networking → enable public IPv6 (free;
   IPv4 is the billed one). Record the assigned /64.
6. [ ] **Cloudflare** → add `AAAA` for `hs.phonkd.net` (currently A-only; NS is
   `drake/chin.ns.cloudflare.com`).
7. [ ] **Verify obs picks up the prefix.** obs uses scripted networking
   (`networking.useDHCP = true`, networkd inactive), so dhcpcd should configure
   it from the RA with no repo change. Confirm with `ip -6 addr` rather than
   assuming.
8. [ ] **`modules/homelab/apps/headscale.nix`** — make the coordinator dual-stack:
   - `address = "0.0.0.0"` → `"[::]"`
   - `derp.server.stun_listen_addr = "0.0.0.0:3478"` → `"[::]:3478"`

   **Use `"[::]"`, not `"::"`.** The NixOS module builds
   `listen_addr = "${cfg.address}:${toString cfg.port}"`, so `"::"` yields
   `:::443`, which Go rejects ("too many colons") — that would take headscale, and
   with it the whole control plane, down. Firewall needs nothing: NixOS
   `allowedTCPPorts`/`allowedUDPPorts` already emit both iptables and ip6tables
   rules.
9. [ ] **UniFi** → enable IPv6 on the `192.168.1.x` network. 201 and 205
   (`192.168.3.x`) get a global prefix today; **203 gets none**, so it would stay
   v4-only otherwise.
10. [ ] **Verify**: `tailscale netcheck` flips to `IPv6: yes`, then confirm a real
    v6 direct path with `tailscale ping` from a v6-capable network.

## Open decisions

- **Which host gets the forward.** Recommending **201** (above). Alternative is
  205-builder, which is a smaller blast radius but only fixes internet egress —
  rejected because it leaves the traefik-fronted services relayed.
- **UPnP instead of static forwards.** Enabling UPnP/NAT-PMP on the UniFi would
  let every host map its own external port automatically — fixes all hosts with
  no per-host config, and is currently off (`PortMapping:` is empty in every
  netcheck). Rejected as the default because it lets any LAN device open WAN
  ports. Reconsider if more than two hosts ever need direct reachability.
- **A second forward for 203.** Direct `100.64.0.3` access (e.g. SMB by tailnet
  IP) stays relayed under Phase 1; going through 201 as exit node covers it by
  LAN IP. A second forward would fix it properly, but **would** require the
  per-host port pin from step 3, since every host defaults to 41641.
- **Phone APN.** If the OnePlus APN protocol is set to `IPv4` rather than
  `IPv4/IPv6`, switching it may yield a tethered v6 prefix and fix that path for
  free. Untested; costs nothing to try.

## Risks / rollout

- **Deploying any `services.tailscale` change restarts `tailscaled`**, which kills
  deploy-rs's own ssh session when the deploy rides the tailnet — recorded twice
  in `nixconfig-ops`, including a 201 rollback. Step 3 must be deployed over a
  non-tailnet path: `deploy 201 --hostname 192.168.3.201`, which means **being on
  the home LAN**. Do not attempt it from a remote/tethered session.
- **201 fronts everything.** Magic rollback only reverts on *lost connectivity*,
  not on a service that comes up wrong-but-reachable. Watch the result of any 201
  deploy and be ready to roll back.
- **Step 8 touches the control plane.** If headscale fails to start, the tailnet
  loses coordination — existing WireGuard sessions keep working, so ssh survives
  and it is recoverable, but verify headscale is healthy immediately after.
- **Phase 2 does not fix the hotspot.** The OnePlus hotspot offers no IPv6 at all
  (NetworkManager has `ipv6.method = auto` and would accept a prefix; only a
  link-local `fe80::` address exists and there is no v6 default route). Phase 1 is
  the fix for that path; Phase 2 is for v6-capable remote networks.
- **Backing out** is trivial for Phase 1 — delete the UniFi rule. Traffic falls
  back to DERP, which is exactly today's behaviour.
- Exposing UDP 41641 to the internet is low risk: it is WireGuard, and unauthorised
  packets are dropped without response.
