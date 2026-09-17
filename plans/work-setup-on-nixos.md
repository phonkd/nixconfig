# work setup on NixOS

**Repo(s):** nixconfig + `~/git/bedag-setup`   **Status:** in-progress

## Goal

Make the work setup usable on a NixOS laptop (z14 first), not just the Mac.
Today *none* of it lands on Linux: `homeModules.work` is imported by exactly
one file (`modules/hosts/mac.nix`), the NixOS half is written into a namespace
nothing reads, and the sing-box proxy every work ssh host depends on is a
`launchd` agent. After this, the gateway ssh aliases, the work gitconfig and
the tunnel script all work on z14 the same way they do on the Mac.

**This repo is public; the work config is not.** Specifics — hostnames,
gateway aliases, tunnel ports, script contents — stay in the private work repo
and are deliberately not restated here. What follows is the wiring on the
nixconfig side, which is this repo's own business.

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
4. **De-macOS the work repo's modules.** `gsed`/`open -a`, the hardcoded
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
- [x] **Deleted `modules/work/tools.nix`.** It duplicated the private repo's own
      tools.nix package list almost exactly, and both were imported — so the
      public copy was redundant *and* an unnecessary disclosure of the work
      toolchain. The missing packages were added to the private list instead.
- [x] `modules/hosts/mac.nix` / `gui/default.nix`: unchanged behaviour — the Mac
      still gets `homeModules.proxy` from `gui-darwin`.

**work repo** (private — details there, not here)

- [x] `ica-proxy.nix`: `gsed` → `${pkgs.gnused}/bin/sed`, and the macOS-only
      opener → `xdg-open` on Linux, guarded by platform.
- [x] `shell.nix`: `/Users/phonkd` → `${config.home.homeDirectory}`, an absolute
      `/usr/bin` path → PATH lookup, and a fix for the
      `initContent`-nested-inside-`siteFunctions` bug (it has never taken
      effect on either platform).
- [x] The tunnel script: hardcoded Mac path to the ssh key → `$HOME`.
- [x] Absorbed the package list that used to be duplicated in this repo.

## Remaining: DisplayLink, Citrix, Teams

The three apps the work day actually runs on, and the three this plan never
delivered on Linux. On the Mac all three arrive through
`modules/hosts/types/gui/default.nix` as homebrew casks (`displaylink`,
`microsoft-teams`) or by hand (Citrix); none of that path exists on NixOS. Top
three worst apps of all time, and all three are load-bearing.

**Prerequisite: the `"work"` tag is gone from z14.** `lib/registry.nix` dropped
it on purpose — work moved back to the Mac, and dropping it is what took the
bedag `Host *` SOCKS catch-all off the laptop. Nothing below lands until that
tag comes back, and re-adding it re-arms that catch-all — so the `ssh 201-mono`
check under **Risks / rollout** applies again, unchanged.

Unfree is *not* the obstacle: `modules/hosts/types/minimal/default.nix` already
sets `nixpkgs.config.allowUnfree = true` host-wide. The manual downloads are.

- [ ] **DisplayLink** (the dock). `pkgs.displaylink` is `requireFile` — the
      Synaptics EULA means no non-interactive install. Add the zip to the store
      first (`nix-prefetch-url --name displaylink-620.zip <url>`, the exact URL
      is in the package's own `requireFile` message), then set
      `services.xserver.videoDrivers = [ "displaylink" ]` — membership in that
      list is the sole gate on `hardware/video/displaylink.nix`, which is what
      brings the `evdi` kernel module, the udev rules and the `dlm` service.
      Two Wayland caveats, because that module is written for Xorg: its
      `displayManager.sessionCommands` `xrandr --setprovideroutputsource` is
      dead weight under Hyprland, and `systemd.services.dlm` is ordered
      `after = [ "display-manager.service" ]`, which z14 does not run
      (greetd/tuigreet, per `modules/desktop.nix`). Expect to override the
      unit's ordering rather than take the module as-is.
- [ ] **Citrix Workspace** (the ICA sessions). Now `pkgs.citrix-workspace` —
      `citrix_workspace` became a rename alias on 2026-06-17 and warns.
      x86_64-linux, unfree, and also `requireFile`, so the same
      manual-download dance as DisplayLink. This supersedes the "not installed
      on Linux" decision below rather than contradicting it: the Linux
      `ica-proxy` branch already rewrites the .ica and hands it to `xdg-open`,
      so installing this package is exactly what supplies the handler that
      branch assumes exists. `remmina` stays for plain RDP.
- [ ] **Teams**. `pkgs.teams` is darwin-only — its `platforms` lists only
      x86_64/aarch64-darwin — so the Mac cask has no nixpkgs counterpart here.
      Pick one: `teams-for-linux` (GPL3+, in nixpkgs, an unofficial Electron
      wrapper) or the PWA in a browser. Then wire screen sharing, which is the
      part that actually breaks: it needs `xdg-desktop-portal-hyprland` plus
      pipewire, not just the app.

## Open decisions

- **`kube_ps1` is dropped, not packaged.** It is not in nixpkgs under any name,
  and the `PROMPT='$(kube_ps1)'` line it came from was inside the broken
  `siteFunctions` nesting, so it has never run. `modules/shell.nix` already
  enables starship's `kubernetes` module, which is the same information.
  Alternative: vendor kube-ps1 as a `fetchFromGitHub` + `initContent` source.
- **Citrix Workspace is not installed on Linux.** *(Superseded — see
  **Remaining: DisplayLink, Citrix, Teams** above; kept for the reasoning.)*
  `citrix_workspace` is unfree
  *and* `requireFile` — it needs a manually downloaded installer, so it cannot
  be added non-interactively. The Linux `ica-proxy` branch rewrites the .ica and
  hands it to `xdg-open`, which does the right thing once a handler exists.
  `remmina` (in the private repo's package list) covers plain RDP meanwhile.
- **Tag name `"work"`** rather than reusing `formFactor`/username — matches the
  existing `gigaplayer-client` / `reverse-proxy` idiom and keeps blac and g14
  opted out until asked for.
- **z14 only.** g14 and blac get nothing until they're tagged; the work ssh
  config carries a `Host *` catch-all and shouldn't land on a machine by
  surprise.

## Risks / rollout

- The work `Host *` catch-all (`ProxyCommand socat - SOCKS:…:2080`) applies to
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
