# clan.lol migration — secrets, tailscale/headscale deploy, module system

**Repo(s):** nixconfig   **Status:** draft — needs a decision before any code lands

Evaluated against **clan-core `26.05`**, rev `4519eabe0e3a65ffabfbb67b75d6329c67187bc1`
(2026-09-23). Input URL is `https://git.clan.lol/clan/clan-core/archive/26.05.tar.gz`
— the GitHub mirror has **no** `26.05` branch or tag, only `main` and old `demo-v*`
tags, so stable sources come from git.clan.lol. That branch pins
`nixos-26.05`, the same release line this repo's `nixpkgs` is on.

## Goal

Answer, with evidence rather than vibes, whether clan.lol should take over three
things this repo does by hand:

1. **secrets** — sops-nix, one shared age recipient, 45 keys in
   `modules/homelab/global-secrets/secret.yaml` plus 3 per-app files, consumed by
   45 distinct `sops.secrets.*` references across 20 modules and 4 `sops.templates`;
2. **tailscale/headscale + deploy** — headscale on `observability`,
   `services.tailscale` on every server and NixOS desktop, deploy-rs over the
   tailnet via `modules/deploy.nix`;
3. **the module system** — `lib/registry.nix` (10 hosts) → `modules/builder.nix`
   (`alwaysImport` + `extraModules`), with ~20 tags gated through
   `noughtyLib.hostHasTag` at 41 call sites across 25 files.

## Verdict

| Ask | Verdict |
|---|---|
| **Secrets → clan** | **Yes, and cheaper than expected.** `clan secrets import-sops` + clanCore's auto-declaration keeps every existing consumer working *verbatim* — zero edits to the 20 modules. Full `vars` adoption is a separate, much larger step that is **not** required to get here. |
| **tailscale/headscale → clan** | **No. Clan cannot own this.** There is no tailscale and no headscale clan service; the string "headscale" appears **zero times** in clan-core. Clan can only *ride* the tailnet. |
| **deploy-rs → `clan machines update`** | **Not recommended.** `clan machines update` has **no magic rollback** — a straight capability regression for hosts reachable only over the mesh. |
| **Module system → clan inventory** | **Partially, and it is optional.** Tags survive intact (verified). The registry's *other* fields have nowhere to live: `inventory.machines.<name>` has no freeform type. |

The honest summary: **one of the three asks is a clear win, one is impossible, and
one is a lateral move.** Adopting clan wholesale would trade a working, understood
setup for a younger one that is missing the single piece this homelab is built on.

## What was verified here, by evaluation

Not read from docs — actually evaluated, against clan-core 26.05, in throwaway
flakes. Reproductions are in the appendix.

1. **Coexistence works.** `clan-core.flakeModules.default` and a hand-written
   `flake.nixosConfigurations.<name>` merge in one flake-parts flake, as long as
   machine names don't overlap. `nix eval .#nixosConfigurations --apply
   builtins.attrNames` → `[ "clanhost" "legacyhost" ]`. This is the load-bearing
   unknown for any staged migration, and upstream has no documented example
   (clan-core issue #5276 asks for exactly this and is open).

2. **`modules/parts.nix` collides — and must lose one line.** It declares
   `options.flake.darwinModules` as `lazyAttrsOf raw`; clan-core declares the same
   option as `lazyAttrsOf deferredModule`:

   ```
   error: The option `flake.darwinModules' in `clan-core/flakeModules/clan.nix'
          is already declared in `<repo>/flake.nix'.
   ```

   Nuance worth knowing: the error is **lazy**. `nixosConfigurations` still
   evaluates fine; it only fires when `flake.darwinModules` is actually read —
   which this repo does, via `self.darwinModules.macm4` in the Mac's registry
   entry. Fix: delete that declaration, clan-core supplies it.
   `options.flake.homeModules` is untouched by clan and stays.

3. **sops-nix double import is a hard error, with a one-line fix.** clanCore does
   `imports = [ ./clanCore inputs.sops-nix."${_class}Modules".sops ]` using
   *clan-core's own* sops-nix input, and sops-nix exports a bare path, so two
   store paths means two declarations:

   ```
   error: The option `sops.gnupg.home' in `/nix/store/AAA-source/modules/sops'
          is already declared in `/nix/store/BBB-source/modules/sops'.
   ```

   Adding `inputs.clan-core.inputs.sops-nix.follows = "sops-nix";` makes it
   evaluate. Verified both ways.

4. **The tag gate survives.** `config.clanConfig.inventory.machines.<me>.tags`
   evaluates inside a machine module with no infinite recursion, and
   `lib.mkIf (hostHasTag "…")` fires correctly off it:

   ```json
   {"gate":true,"negative":false,"tags":"reverse-proxy,homelab-server,all,nixos"}
   ```

   (`all` and `nixos` are clan's reserved auto-tags, appended for free.)
   `clanConfig` is a declared, read-only option in
   `nixosModules/clanCore/dependencies.nix` — real, but undocumented in the
   guides, so treat it as semi-internal.

5. **The secrets bridge works — this is the important one.** With a legacy
   `sops/secrets/<name>/` store (what `clan secrets import-sops` writes), clanCore
   auto-declares `sops.secrets.<name>` for every secret the machine can decrypt.
   An untouched consumer resolves, and `sops.templates` still renders:

   ```json
   {"declared":["sonarr-api-key"],
    "bridgePath":"/run/secrets/sonarr-api-key",
    "templateRendered":"KEY=<SOPS:317c4e2a…:PLACEHOLDER>"}
   ```

   So `config.sops.secrets."sonarr-api-key".path` and the four `sops.templates`
   blocks in `arr-slime.nix` / `ocis.nix` / `proxy/nixos.nix` need **no changes at
   all**.

6. **`clan.core.enableRecommendedDefaults` (default `true`) is a deploy hazard
   here.** Measured on one machine, both ways:

   | | `= true` (clan default) | `= false` |
   |---|---|---|
   | `networking.useNetworkd` | **`true`** | `false` |
   | `networking.domain` | `"clan"` | `null` |
   | `networking.fqdn` | `on.clan` | *(unset)* |
   | `clan.core.networking.targetHost` | `root@on.clan` | `null` |

   Silently switching every server to systemd-networkd, and defaulting the deploy
   target to a name that resolves nowhere, is exactly the class of failure
   `plans/201-activation-dns-race.md` and the 203 empty-`resolv.conf` incident came
   from. **Set `enableRecommendedDefaults = false` on every machine.**

## Why headscale/tailscale cannot move

This is the part that kills the middle ask, so it is worth stating precisely.

- clan-core ships 31 official services. The networking ones are `internet`,
  `wireguard`, `zerotier`, `mycelium`, `yggdrasil`, `tor`, `p2p-ssh-iroh`,
  `data-mesher`/`dm-dns`. There is no `tailscale` and no `headscale`.
- `grep -ri headscale` over a full clan-core clone returns **nothing**.
  `tailscale` appears only as an interface-name pattern used to *exclude*
  `tailscale0` from zerotier/yggdrasil/data-mesher peering
  (`nixosModules/user-firewall`, `pkgs/network-status`).
- The 26.05 mesh-vpn guide says so outright: *"Currently ZeroTier is the only
  mesh-vpn that is fully integrated into clan. In the future we plan to add
  additional network technologies like tinc, head/tailscale."* That page has since
  been **deleted** from the unstable docs.
- Nothing in clan-community or its 11 forks has one either.
- `clan.core.networking.*` has exactly four options — `targetHost`, `buildHost`,
  `forwardAgent`, `internalListenAddresses`. It is not a VPN abstraction.

### "But unstable has a mesh WireGuard service"

It has a `wireguard` service, and its README opens with *"a WireGuard-based VPN
**mesh** network"* and lists *"Full mesh connectivity between all machines"* under
Features. That wording does not survive contact with the source.

- **`main` and `26.05` are byte-identical** here — `clanServices/wireguard/default.nix`
  `diff`s clean between the two branches (812 lines). Unstable has nothing 26.05
  doesn't.
- **It is a star, not a mesh.** In `roles.peer`, the WireGuard `peers` list is
  built from `roles.controller.machines` only — the literal comment in the source
  is `# Connect to all controllers`. A peer never gets a WireGuard peer entry for
  another peer. Only `roles.controller` peers with everything
  (`allOtherControllers ++ allPeers`). The README's own Connectivity section
  admits it: *"All traffic between peers flows through controllers"*, which is why
  controllers need IPv6 forwarding. "Full mesh" means full *reachability*, not
  full *peering*.
- **There is no NAT traversal.** The only relevant machinery is
  `persistentKeepalive = 25` — plain WireGuard hole-punch maintenance. No STUN, no
  relay, no endpoint discovery, no roaming. `endpoint` is a static config string,
  and only controllers have one (*"Controllers must have a publicly accessible
  endpoint"*).

For this homelab that is a hard no. The only host with a public endpoint is
`observability` in Hetzner, so it would be the sole controller — meaning
**201↔203 traffic, two VMs in the same house, would hairpin through Hetzner**, as
would every closure push to `205-builder`. Today those are direct P2P WireGuard
sessions; `plans/headscale-mesh.md` records direct P2P verified across
home↔Hetzner at 30 ms. Tailscale's NAT traversal (with DERP only as *fallback*) is
precisely the thing clan's wireguard service does not implement.

The nearest thing clan has to real P2P is `p2p-ssh-iroh` (priority 3000), which
does NAT-traversed connections via iroh — but it is marked experimental in its own
README and only exposes a machine's **SSH**, not a general network. And `zerotier`,
the only VPN clan calls "fully integrated", defaults to relaying through clan's own
TCP relay at `65.21.12.51:4443` and mandates exactly one controller.

Re-checked at the time of writing: `clanServices/` on `main` is
`admin borgbackup certificates coredns data-mesher dm-dns dyndns emergency-access
garage hello-world importer installer internet kde localbackup matrix-synapse
monitoring mycelium ncps p2p-ssh-iroh packages pki sshd syncthing tor
trusted-nix-caches users wifi wireguard yggdrasil zerotier` — still no
`tailscale`, still no `headscale`.

### What clan does offer instead

What clan *does* have is a network-priority system driven by service **exports**
(`manifest.exports.out = [ "networking" "peer" ]`, `networking.priority`,
`peer.hosts`). Shipped priorities: `p2p-ssh-iroh` 3000, `internet` 2000,
`yggdrasil` 2000, `wireguard` 1000, `zerotier` 900, `mycelium` 800, `tor` 10. The
default technology module is `clan_lib.network.direct` — plain SSH, reachability
probed with `nc -z <host> 22`.

So clan can **ride** the tailnet three ways, in increasing order of effort:

```nix
# (a) simplest — short-circuits clan's whole network stack
inventory.machines."201-mono".deploy.targetHost = "root@100.64.0.5";

# (b) fleet-wide, no per-host lines: meta.domain drives networking.domain
#     drives the targetHost default
clan.meta.domain = "ts.phonkd.net";   # => root@<host>.ts.phonkd.net

# (c) a ~40-line private clan.service modelled on clanServices/internet that
#     exports networking.priority + peer.hosts with MagicDNS names, so
#     `clan network list/ping` understands the tailnet. No Python plugin needed.
```

Option (b) is tempting because `dns.base_domain` in
`modules/homelab/apps/headscale.nix` is already `ts.phonkd.net`. But note clan's
doc prose about `clan.core.networking.targetHost` "bypassing all networking
modules" is **wrong** — in `clan_lib/network/network.py` the inventory
`deploy.targetHost` short-circuits, while the machine-level
`clan.core.networking.targetHost` is tried **last**, after every network fails.

Two live footguns if the tailnet becomes the deploy path:

- **Host-key churn.** Tailscale SSH serves `:22` on the tailnet with tailscaled's
  own key, while the real sshd is on `:5432`. Clan always passes a
  `StrictHostKeyChecking` mode (default `ask` for `machines update`, `tofu` for
  `clan ssh`) and writes your ordinary `~/.ssh/known_hosts`. Same hostname reached
  both ways → `REMOTE HOST IDENTIFICATION HAS CHANGED`. Pin the port explicitly.
- **`--host-key-check` defaults to `ask`**, which hangs in any scripted or agent
  context. Always pass `accept-new`.

## Why `clan machines update` should not replace `deploy`

- **There is no rollback.** A full-tree grep for `rollback` in clan-core hits only
  btrfs impermanence disk templates. Today `modules/deploy.nix` sets
  `magicRollback = true; autoRollback = true;` — a host that drops off the network
  after activation reverts itself. Clan has no equivalent.
- 26.05's safety improvement is the *opposite* shape: it runs
  `switch-to-configuration boot` **before** `switch`, so the new generation is
  already the boot default. A config that kills tailscaled leaves you rebooting
  into the broken generation, not out of it. This repo already has the scar —
  hence `deploy 203 --hostname 192.168.1.203` in the `deploy` CLI's help text.
- **Default build location flips.** With no `buildHost`, `clan machines update`
  builds **on the target**. Restoring today's behaviour (build on the Mac,
  offloaded to 205 via `nix.buildMachines`) means `deploy.buildHost = "localhost"`
  per machine. Clan adds no `--builders`/`--max-jobs` flags, so the existing
  offload then applies unchanged.
- **Every run evaluates and generates vars for the whole fleet**, not just the
  named host (`run_generators(all_machines, …)` before the deploy loop).
- Good news: clan emits plain `nixosConfigurations`, so **deploy-rs keeps working
  alongside it unchanged**. The two are not mutually exclusive. If a non-clan
  deployer is used with clan vars, `clan vars upload <machine>` must run first.

## Why the module system is a lateral move

- `inventory.machines.<name>` has **no freeform type**. Its entire option set is
  `name, description, icon, machineClass, installedAt, tags,
  deploy.{targetHost,buildHost,forwardAgent}`. `lib/registry.nix` carries
  `kind, platform, formFactor, desktop, gpu.{vendors,compute}, username,
  userTags, extraModules` — none of which have anywhere to go. The registry
  would have to survive anyway, as a second source of truth.
- Machine **tags are not a NixOS option** either (`clan.core.settings` exposes
  only `directory, name, icon, tld, domain, machine.{name,icon,description}`).
  The `clanConfig` escape hatch verified above is what makes the 41 `hostHasTag`
  call sites portable — without it, every one of them would need restructuring
  into an `importer` instance.
- There is **no "import this module on every machine" option**. `alwaysImport`
  would become an `importer` instance with `roles.default.tags = [ "all" ]` —
  strictly more indirection for the same result.
- `roles.<role>.extraModules` is imported once per (instance × role × machine).
  **Function modules do not dedupe** (Nix function equality is always false) —
  the exact hazard `modules/builder.nix` already warns about. Use paths or
  `self.nixosModules.<x>` attrs, never inline lambdas.
- Per-tag `settings` (`roles.<r>.tags.<tag>.settings`) **do not exist in 26.05** —
  the code is commented out with a TODO. They are main-only.
- Autoincludes cannot be disabled: `${clan.directory}/machines/*/` is always
  scanned, and `${clan.directory}/inventory.json` is always merged. Harmless today
  (neither exists here) but it means creating a `machines/` directory later
  silently mints clan machines.

## Approach

Adopt the part that pays, skip the parts that don't. Everything below is
additive and independently revertible.

**Phase 0 — spike (done; this PR).** No repo code changed. Findings above.

**Phase 1 — wire clan-core in, additively, one host.**
`205-builder` is the right guinea pig: lowest blast radius, no traefik, no
inbound services, and it can be reached on the LAN if the tailnet path breaks.

1. `flake.nix`: add
   ```nix
   clan-core = {
     url = "https://git.clan.lol/clan/clan-core/archive/26.05.tar.gz";
     inputs.nixpkgs.follows = "nixpkgs";
     inputs.flake-parts.follows = "flake-parts";
     inputs.sops-nix.follows = "sops-nix";   # MANDATORY — see finding 3
     inputs.nix-darwin.follows = "nix-darwin";
   };
   ```
   Note this drags in 9 more inputs, two of which (`nix-select`, `data-mesher`)
   float on `main` even on the stable branch — any `nix flake update` moves them.
2. `modules/parts.nix`: delete the `options.flake.darwinModules` declaration
   (finding 2). Keep `homeModules`.
3. New `modules/clan.nix`: `imports = [ inputs.clan-core.flakeModules.default ];`
   plus `clan.meta.name`, `clan.specialArgs = { inherit inputs; }`, and one
   `clan.machines."205-builder"` reproducing what `modules/builder.nix` builds for
   it — with `clan.core.enableRecommendedDefaults = false;` and
   `nixpkgs.hostPlatform = "x86_64-linux";` (clan passes no `system` argument).
4. `modules/builder.nix`: skip any registry name that `clan.machines` defines, or
   the two builders collide on that attr name.
5. Verify with `nix eval .#nixosConfigurations --apply builtins.attrNames` — all
   10 names present, exactly one produced by clan. Then `deploy 205` as usual:
   deploy-rs reads the same output and neither knows nor cares which builder made it.

**Phase 2 — secrets onto the clan store.** The win, and it is cheap.

6. `clan vars keygen --user phonkd` (registers the existing
   `~/.config/sops/age/keys.txt` into `sops/users/phonkd/key.json`), then
   `clan secrets groups add-user admins phonkd`.
7. Register each server's machine key. Clan generates a *fresh* age keypair by
   default and uploads the private half to `/var/lib/sops-nix/key.txt`. To keep
   today's model instead, pre-register ssh-host-key-derived keys:
   ```bash
   clan secrets machines add 205-builder \
     "$(ssh-keyscan 100.64.0.2 2>/dev/null | ssh-to-age)"
   ```
8. `clan secrets import-sops --group admins --machine … \
   modules/homelab/global-secrets/secret.yaml` and once per per-app file.
   Non-string values are skipped with a warning; existing names are skipped.
9. **No consumer module changes** (finding 5). Optionally drop the bare
   `sops.secrets.<name> = { };` declarations, but keep any that set
   `owner`/`group`/`mode` — 10 of them do.
10. Keep `sops.defaultSopsFile` and `sops.age.keyFile` as they are; clan sets both
    at `mkDefault`, so this repo's explicit values still win.

**Phase 3 — vars: opt-in, per secret, or not at all.** Read this before starting:

- `migrateFact` **no longer exists**; the facts system was removed outright.
- There is **no importer from a sops YAML into `vars/`**. `import-sops` targets
  the legacy store only.
- Interactive prompts cannot be piped (`termios`/`tty.setraw`), and hidden prompts
  demand the value twice. For 45 opaque API keys that is ~90 manual entries. The
  scriptable path is `echo -n "$V" | clan vars set <machine> <gen>/<file>`, but the
  var must be **declared in nix first**.
- **clan vars has no `sops.templates` equivalent.** The four template blocks here
  either keep using sops-nix templates (which works — clan's sops backend puts
  vars into `config.sops.secrets`, and sops-nix derives a placeholder for every
  entry) or become generators that assemble the env file themselves.
- The sops secret **name changed between 26.05 and main** —
  `vars/<generator>/<file>` → `vars/per-machine/<machine>/<gen>/<file>`. Anything
  hardcoding the name or `/run/secrets` path breaks on the next release.

Recommendation: adopt vars only for secrets that are genuinely *generatable*
(passwords, keypairs, the headscale pre-auth key), and leave the 45 opaque
third-party API keys in the legacy store where Phase 2 already puts them.

**Phase 4 — tags into the inventory, registry keeps the rest.** Optional.
Mirror `lib/registry.nix` tags into `clan.inventory.machines.<name>.tags`, and
feed them back to `noughty.host.tags` in the builder's generated module so
`noughtyLib.hostHasTag` keeps working at all 41 sites unchanged. The registry
stays the source of truth for everything the inventory cannot hold.

**Phase 5 — replacing `deploy`. Not recommended.** Documented here so the
decision is recorded, not so it gets done. If it ever happens, it needs an
out-of-band path (LAN address / console) on every host first, because the magic
rollback that covers that today would be gone.

## Open decisions

1. **Does clan earn its keep at all?** With headscale off the table and deploy-rs
   staying, what remains is "a different encrypted-secret store with a CLI".
   The alternative is to do nothing and keep `sops-secret` + `.sops.yaml`.
   *Recommendation: run Phases 0–2 on 205-builder only, then decide.* That is a
   few hours and fully revertible.
2. **Machine keys: clan-generated or ssh-host-key-derived?** Clan's default mints
   a new age key per machine and leaves the private half at
   `/var/lib/sops-nix/key.txt` — persistent, on disk, not tmpfs. Step 7 above
   keeps the existing model instead. *Recommendation: ssh-derived.*
3. **Inventory in nix, or in `inventory.json`?** The clan CLI writes **and
   `git commit`s** config on your behalf (`clan_lib/persist/inventory_store.py`).
   In a hand-authored flake-parts repo that is a cultural collision.
   *Recommendation: nix-declared, read-only to the CLI.*
4. **`meta.domain = "ts.phonkd.net"`** (fleet-wide MagicDNS targetHost default) vs
   per-machine `deploy.targetHost` mirrored from the registry.
   *Recommendation: per-machine — it matches the registry and short-circuits
   clan's network probing entirely.*

## Risks / rollout

- **Upgrade treadmill.** Two stable releases exist (25.11, 26.05). The 25.11
  branch's last commit is 2026-05-18 — it went dark when 26.05 shipped. There is
  no overlapping support window: expect a breaking, migration-guide-shaped upgrade
  every ~6 months. The docs already ship seven migration guides, covering two full
  rewrites of the core abstraction in about a year (`facts`→`vars`,
  `clanModules`→`clanServices` with ~20 modules deleted).
- **Nixpkgs matrix.** Clan recommends `nixpkgs.follows = "clan-core/nixpkgs"` and
  warns that your own nixpkgs is untested by their CI. This repo has five
  deliberate nixpkgs inputs with load-bearing comments; following clan's is not an
  option. Pinning clan-core to the **26.05 branch** (which pins nixos-26.05)
  is the mitigation — never pin `main`.
- **Live upstream bugs on the exact path this would use:** #6963 *"updating to
  latest clan fails decrypting secrets"* (open since 2026-03-05), #7084
  `clan machines update` fails with yubikey + multiple machines, #6032
  `clan secrets set` only encrypts for the current user, #7260 `update` and
  `build` differ in what they build.
- **Darwin is barely supported.** Documented feature set is exactly
  "`clan machines update` for existing nix-darwin installations" plus vars.
  `darwinModules/` contains one file. Clan services on macOS is issue #5717, open
  with zero comments since 2025-11-01. Leave `Eliss-MacBook-Pro` on the existing
  builder.
- **Almost no prior art.** No Discourse, Reddit or HN write-up of migrating an
  existing sops-nix + deploy-rs homelab onto clan. The 26.05 release post on
  Discourse has zero replies. Budget for filing issues rather than finding them.
- **Exit cost is low, which is the saving grace.** Clan vars are sops-nix
  underneath, and on disk each secret is a standalone SOPS JSON file with age
  recipients. `sops -d` recovers everything; un-migrating is a scripting job, not
  a data-loss event.
- **Rollout:** every phase is `deploy <host>` as today. Phase 1 and 2 touch
  `205-builder` only. Back out by reverting the commit — the `sops/` and `vars/`
  directories are inert to the current builder.

## Appendix — reproducing the spikes

Each is a standalone throwaway flake; none touches this repo. Run outside the
checkout.

```nix
# coexistence + the parts.nix collision
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    flake-parts.url = "github:hercules-ci/flake-parts";
    clan-core = {
      url = "https://git.clan.lol/clan/clan-core/archive/26.05.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };
  };
  outputs = inputs@{ flake-parts, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];
      imports = [
        inputs.clan-core.flakeModules.default
        # verbatim from modules/parts.nix
        ({ lib, ... }: {
          options.flake.darwinModules = lib.mkOption {
            type = lib.types.lazyAttrsOf lib.types.raw; default = { };
          };
          options.flake.homeModules = lib.mkOption {
            type = lib.types.lazyAttrsOf lib.types.raw; default = { };
          };
        })
      ];
      # the "foreign builder", i.e. what modules/builder.nix does
      flake.nixosConfigurations.legacyhost = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [{
          boot.loader.grub.devices = [ "/dev/sda" ];
          fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
          system.stateVersion = "26.05";
        }];
      };
      clan = {
        meta.name = "spike";
        machines.clanhost = {
          nixpkgs.hostPlatform = "x86_64-linux";
          clan.core.enableRecommendedDefaults = false;
          boot.loader.grub.devices = [ "/dev/sda" ];
          fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
          system.stateVersion = "26.05";
        };
      };
    };
}
```

```bash
git init . && git add -A
nix eval --impure .#nixosConfigurations --apply builtins.attrNames
#   => [ "clanhost" "legacyhost" ]          (coexistence works)
nix eval --impure .#darwinModules --apply builtins.attrNames
#   => error: The option `flake.darwinModules' ... is already declared ...
```

For the secrets bridge, create the store clan's importer would write and read it
back with no `sops.secrets` declaration of your own:

```bash
mkdir -p sops/secrets/sonarr-api-key/machines sops/machines/h
echo '{"data":"ENC[AES256_GCM,data:fake,type:str]"}' > sops/secrets/sonarr-api-key/secret
ln -sfn ../../../machines/h sops/secrets/sonarr-api-key/machines/h
echo '{"publickey":"age1…","type":"age"}' > sops/machines/h/key.json

nix eval --impure --json .#nixosConfigurations.h.config --apply \
  'c: { declared = builtins.attrNames c.sops.secrets;
        bridgePath = c.environment.etc."bridge-proof".text; }'
#   => {"declared":["sonarr-api-key"],"bridgePath":"/run/secrets/sonarr-api-key"}
```

(That machine needs `sops.validateSopsFiles = false;` since the fake secret is not
real SOPS output.)
