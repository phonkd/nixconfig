# work setup on NixOS

**Repo(s):** nixconfig + `~/git/bedag-setup`   **Status:** in-progress

## Goal

Make the bedag work setup usable on a NixOS laptop (z14 first), not just the
Mac. Today *none* of it lands on Linux: `homeModules.work` is imported by
exactly one file (`modules/hosts/mac.nix`), the NixOS half is written into a
namespace nothing reads, and the sing-box proxy every work ssh host depends on
is a `launchd` agent. After this, `ssh sshgwcobe`, the `cmk*`/`bedag` aliases,
the work gitconfig and the tunnel script all work on z14 the same way they do
on the Mac.

## Approach

Four moves, smallest-useful-slice ordered so each is verifiable alone:

1. **Unblock eval.** `modules/work/external.nix` imports
   `${bedagSetup}/jjconfig.nix`, which does not exist in the bedag-setup
   checkout (untracked on the Mac at best). Drop the import — decided by the
   user, not guessed.
2. **Fix the wiring.** `flake.module.nixos."work"` is dead: the flake consumes
   `flake.nixosModules.*` (via `alwaysImport` in `modules/builder.nix`), never
   `flake.module.*`. Rename it, self-gate it on a new `"work"` host tag the way
   every other cross-host feature module gates (`noughtyLib.hostHasTag`), add it
   to `alwaysImport`, and tag z14. The module also pulls `homeModules.work` into
   HM, mirroring the `nixosModules.gui` pattern.
3. **Split the proxy by platform.** `homeModules.proxy` keeps its single
   definition but branches on `pkgs.stdenv.hostPlatform.isDarwin`:
   `launchd.agents.sing-box` on macOS, `systemd.user.services.sing-box` on
   Linux. The `sing-box-sel` wrapper is already platform-neutral and is reused
   verbatim, except that its `.phonkd.net → 127.0.0.1` DNS split becomes an
   option: that route exists only because macOS scoped resolvers are invisible
   to sing-box, and on Linux 127.0.0.1 is a dead resolver (`darwinModules.dns`
   is Mac-only; the laptops have no local dnsmasq).
4. **De-macOS the bedag-setup modules.** `gsed`/`open -a`, the hardcoded
   `/Users/phonkd` paths, and `/usr/bin/glab` all have to go or be guarded.

## Steps

**nixconfig**

- [x] `modules/work/external.nix`: drop the `jjconfig.nix` import.
- [x] `modules/work/default.nix`: `flake.module.nixos."work"` →
      `flake.nixosModules.work`, gated on `hostHasTag "work"`; it wires
      `home-manager.users.<user>.imports = [ self.homeModules.work ]`.
- [x] `modules/builder.nix`: add `work` to `alwaysImport`.
- [x] `lib/registry.nix`: add the `"work"` tag to z14.
- [x] `modules/proxy.nix`: platform branch (launchd vs systemd user unit) +
      `homelabDnsServer` wrapper option (null on Linux).
- [x] `modules/work/tools.nix`: add the five packages z14 was missing —
      `glab`, `kubie`, `ejson`, `teleport`, `socat`.
- [x] `modules/hosts/mac.nix` / `gui/default.nix`: unchanged behaviour — the Mac
      still gets `homeModules.proxy` from `gui-darwin`.

**bedag-setup**

- [x] `home-manager/ica-proxy.nix`: `gsed` → `${pkgs.gnused}/bin/sed`,
      `open -a "Citrix Workspace"` → `xdg-open` on Linux; whole script guarded
      so the Linux branch is honest about what it can do.
- [x] `home-manager/shell.nix`: `/Users/phonkd` → `${config.home.homeDirectory}`,
      `/usr/bin/glab` → `glab`, and fix the `initContent`-nested-inside-
      `siteFunctions` bug (it has never taken effect on either platform).
- [x] `bdg_gwup.sh`: `/Users/phonkd/.ssh/id_ed25519` → `$HOME/.ssh/id_ed25519`.

## Open decisions

- **`kube_ps1` is dropped, not packaged.** It is not in nixpkgs under any name,
  and the `PROMPT='$(kube_ps1)'` line it came from was inside the broken
  `siteFunctions` nesting, so it has never run. `modules/shell.nix` already
  enables starship's `kubernetes` module, which is the same information.
  Alternative: vendor kube-ps1 as a `fetchFromGitHub` + `initContent` source.
- **Citrix Workspace is not installed on Linux.** `citrix_workspace` is unfree
  *and* `requireFile` — it needs a manually downloaded installer, so it cannot
  be added non-interactively. The Linux `ica-proxy` branch rewrites the .ica and
  hands it to `xdg-open`, which does the right thing once a handler exists.
  `remmina` (already in `work-tools`) covers plain RDP meanwhile.
- **Tag name `"work"`** rather than reusing `formFactor`/username — matches the
  existing `gigaplayer-client` / `reverse-proxy` idiom and keeps blac and g14
  opted out until asked for.
- **z14 only.** g14 and blac get nothing until they're tagged; the work ssh
  config carries a `Host *` catch-all and shouldn't land on a machine by
  surprise.

## Risks / rollout

- The bedag `Host *` catch-all (`ProxyCommand socat - SOCKS:…:2080`) applies to
  **every** ssh destination. On the Mac this is survived by the tailnet/homelab
  match blocks in `mac.nix` rendering *above* it. z14 has no such blocks: it
  reaches the homelab over the tailnet by name, and those names must not get
  proxied. Mitigated by the `no_proxy` session var plus tailnet match blocks
  added ahead of the catch-all — **verify `ssh 201-mono` still works on z14
  after deploy** before calling this done.
- sing-box exits immediately if `~/git/bedag-setup/singbox.json` is absent; the
  systemd unit gets `RestartSec`/`StartLimit` backoff mirroring the launchd
  `ThrottleInterval = 30`, and is `wantedBy` nothing on a host without the tag.
- Rollout: `deploy z14`. Back out by dropping the `"work"` tag from the registry
  entry and redeploying — every other change is inert without it.
