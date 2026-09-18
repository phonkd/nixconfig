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
   Linux. *(The Linux half has since become a **system** unit in its own
   `nixosModules.proxy` — see **System-wide proxy on z14**.)*
   The `sing-box-sel` wrapper is already platform-neutral and is reused
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
      *(The systemd **user** unit half is superseded — see
      **System-wide proxy on z14** below. `homelabDnsServer` is unchanged.)*
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

**Prerequisite: the `"work"` tag — done.** `lib/registry.nix` had dropped it on
purpose (work moved back to the Mac), and dropping it is what took the bedag
`Host *` SOCKS catch-all off the laptop. It is back on z14, which re-arms that
catch-all and with it `homeModules.work-ssh-bypass`. Verified in the rendered
`~/.ssh/config`: the bypass block (tailnet, `*.ts.net`, the host aliases, the
LAN ranges, `github.com`) renders at line 10 with `ProxyCommand none`, ~250
lines above the catch-all's `socat` line, so first-match-wins keeps `201-mono`
off the proxy.

Unfree is *not* the obstacle: `modules/hosts/types/minimal/default.nix` already
sets `nixpkgs.config.allowUnfree = true` host-wide. The manual downloads are —
and that is precisely why DisplayLink and Citrix are each behind their own
`noughty.work.*.enable` flag, defaulting **off**. `requireFile` fails at *build*
time, so wiring either of them on unconditionally would turn every
`deploy z14` into a hard failure until the installer is in the store. The
module wiring is written and evaluated; only the download is outstanding.

- [x] **Teams** — done, nothing outstanding. `pkgs.teams` is darwin-only (its
      `platforms` lists only x86_64/aarch64-darwin), so the Mac cask has no
      nixpkgs counterpart and `teams-for-linux` (GPL3+, unofficial Electron
      wrapper) is the only packaged route; the PWA was the alternative and is
      the same Electron shell with fewer knobs. Screen sharing — billed above
      as "the part that actually breaks" — turned out to need **no** wiring:
      it wants `xdg-desktop-portal-hyprland` (installed by `programs.hyprland`,
      see `modules/hyprland/_nixos.nix`), pipewire (`modules/desktop.nix`), and
      the app started with `--enable-features=WebRTCPipeWireCapturer`. z14
      already had the first two, and the third is in the nixpkgs wrapper
      already, guarded on `NIXOS_OZONE_WL` + `WAYLAND_DISPLAY` — and
      `modules/desktop.nix:407` sets `NIXOS_OZONE_WL = "1"`. An `overrideAttrs`
      re-adding those flags would have been pure duplication.
- [~] **DisplayLink** (the dock) — wired, needs one manual download.
      `noughty.work.displaylink.enable` (default off) sets
      `services.xserver.videoDrivers = [ "displaylink" ]`; membership in that
      list is the sole gate on `hardware/video/displaylink.nix`, which brings
      the `evdi` kernel module, the udev rules and the `dlm` service. To
      finish, on z14 itself:
      `nix-prefetch-url --name displaylink-620.zip <url>` (the exact URL is
      printed by the package's own `requireFile` message — Synaptics puts it
      behind an EULA click-through, so there is no non-interactive route),
      then flip the flag and `deploy z14`.
      **Correction to the earlier note here:** the two Xorg-shaped bits of that
      module are *inert* under Hyprland, not broken, so no override is needed.
      The `sessionCommands` `xrandr --setprovideroutputsource` only ever runs
      in an X session; and `systemd.services.dlm`'s
      `after = [ "display-manager.service" ]` orders against a unit z14 does
      not have (greetd/tuigreet), which systemd simply ignores — ordering
      against an absent unit is a no-op, not a failure. `dlm` has no `wantedBy`
      on any setup: the displaylink package's own udev rules start it when the
      dock appears, which is the behaviour we want anyway.
- [~] **Citrix Workspace** (the ICA sessions) — wired, needs one manual
      download. `noughty.work.citrix.enable` (default off) adds
      `pkgs.citrix-workspace` — `citrix_workspace` became a rename alias on
      2026-06-17 and warns. x86_64-linux, unfree, and also `requireFile`, so
      the same dance as DisplayLink: `nix build` prints the file it wants and
      where to get it. This supersedes the "not installed on Linux" decision
      below rather than contradicting it: the Linux `ica-proxy` branch already
      rewrites the .ica and hands it to `xdg-open`, so this package is exactly
      what supplies the handler that branch assumes exists. `remmina` stays for
      plain RDP.

## System-wide proxy on z14

The original approach (step 3) made sing-box a systemd **user** unit, mirroring
the Mac's launchd agent. That was the wrong shape for what was actually wanted
— one proxy the whole machine goes through, with homelab traffic riding the
tailnet and bedag traffic riding the ssh tunnels. A user unit cannot be that:

- `home.sessionVariables` reaches only what home-manager's session init touches.
  Units under `systemd --system`, anything greetd starts before the user session
  exists, and every non-login context never saw the proxy at all.
- Transparent capture needs `NET_ADMIN`, which an unprivileged user agent has no
  way to hold.

So the Linux half moved out of `homeModules.proxy` into a new
`flake.nixosModules.proxy` (same file), gated on `noughty.proxy.enable`, which
`nixosModules.work` sets. macOS is untouched and keeps the launchd agent — it
has no second traffic class to route, and a LaunchDaemon there would buy
nothing but root.

- [x] `modules/proxy.nix`: add `flake.nixosModules.proxy` — `systemd.services.sing-box`
      (system), `environment.sessionVariables` for the proxy env in **both**
      cases (`http_proxy` *and* `HTTP_PROXY`; plenty of tooling reads only the
      upper forms), `sing-box` + `socat` in `environment.systemPackages`.
- [x] `modules/proxy.nix`: drop the Linux branch from `homeModules.proxy`; it is
      a darwin-only module now.
- [x] `modules/work/default.nix`: restructure to `options` + `config` (options
      may not live inside `mkIf`), set `noughty.proxy.enable = true`, stop
      importing `homeModules.proxy` into HM.
- [x] `modules/builder.nix`: add `proxy` to `alwaysImport`.

Deliberately unchanged: the listener is still the mixed inbound on
`127.0.0.1:2080`, so the work ssh catch-all's `socat` ProxyCommand keeps
working; and the bedag SOCKS outbounds are still the *user's* own `ssh -fN`
tunnels on loopback, opened interactively against a yubikey. Loopback is shared
between system and user and the unit takes no `PrivateNetwork`, so root dialling
a tunnel phonkd opened is fine.

Two judgement calls worth knowing about:

- **`ConditionPathExists` replaces the restart backoff.** The merged config
  lives in the private work checkout. Rather than crash-looping with
  `StartLimitBurst` when that is absent, the unit now simply stays inactive.
- **System services stay unproxied.** `systemd --system` units do not source
  `/etc/set-environment`, so `nix-daemon` and friends never see `http_proxy`.
  That is on purpose: builds must not start failing the moment the bedag
  tunnels are down.

### Homelab via tailscale — done, as a real outbound

The bypass is gone. sing-box now runs **its own userspace tailscale node**
(`endpoints`, `type = "tailscale"` — the pinned sing-box 1.13.19 is built
`with_tailscale`, confirmed from `sing-box version`), and homelab traffic is
routed to it:

    homelab (100.64.0.0/10, *.ts.net, *.phonkd.net) -> tailscale endpoint
    bedag (the work config's own domain/ip rules)   -> SOCKS ssh tunnels
    everything else                                 -> direct

Both rule forms are needed: `ip_cidr` catches what is already resolved into the
CGNAT range (raw `100.64.x.y`, deploy targets), the suffix rule catches names
resolved inside sing-box before an address exists to match on. MagicDNS is
answered by a `type = "tailscale"` DNS server bound to the endpoint, because
with the tun capturing the tailnet we can no longer assume the host resolver is
the one that knows those names.

`route_exclude_address` for the tailnet is dropped **exactly when** the endpoint
is in play — keeping both would mean those packets never reach sing-box and the
new rules could never match. The wrapper enforces that with one flag, so the two
states cannot drift apart.

#### The auth key never enters this repo or the store

The endpoint needs a headscale pre-auth key, and this repo is public. Three
things together make that a non-issue:

1. **No new secret was minted.** It reuses `sops.secrets.headscale_authkey` —
   the *reusable* key `modules/tailnet.nix` already gives tailscaled. A second
   node can register with it, so nothing was created, encrypted or committed.
2. **The key is not in the Nix store.** The generated config (store, public)
   holds only the endpoint *tag*. The endpoint itself is a `sops.templates`
   file rendered at activation to `/run/secrets/rendered/singbox-tailscale.json`.
   Verified: the store copy contains `<SOPS:…:PLACEHOLDER>`, not a key.
3. **sing-box merges three `--config` files**, split by who may see them —
   store/public, private work checkout, sops-rendered secret.

- [x] `endpoints` entry via `sops.templates`, reusing the existing authkey.
- [x] Route + DNS rules pointing the homelab at it.
- [x] `StateDirectory = sing-box` so the tsnet node keeps its identity across
      restarts instead of re-registering every boot.

**Consequence to know about: this is a second node on the mesh.** tsnet is a
separate identity from the host's tailscaled, so headscale gains a
`z14-singbox` machine next to `z14`. The alternative that avoids it — a plain
`direct` outbound with `bind_interface = "tailscale0"`, which needs no key at
all but makes sing-box depend on tailscaled being up — was not taken, because
an explicit tailscale outbound was what was asked for. It remains the obvious
fallback if the duplicate node is annoying.

### Transparent mode — on by default

`noughty.proxy.transparent` defaults **true** now, by request: the tun inbound
with `auto_route` is what makes this a system-wide proxy rather than one that
only catches things reading `$http_proxy`. `strict_route` stays **false** —
strict mode also hijacks other interfaces' traffic, which is exactly the fight
not to pick with `tailscale0`.

Still true, and still the risk: `auto_route` rewrites the default route. The
agreed safety net is rolling back to the previous generation from the boot menu,
not a default-off flag.

What has actually been verified is the *config*, not the routing:
`sing-box check` passes on the real generated config merged with the real bedag
config and a stand-in for the rendered endpoint file. That says the schema and
tag references are right. It says nothing about whether the routes behave.

#### Pre-flight before the first switch

- [ ] Confirm the pre-auth key is still valid and reusable —
      `headscale preauthkeys list` on observability, **as root** (the CLI needs
      the socket; plain Tailscale SSH gets permission denied). If it has
      expired, the endpoint will not register and the homelab goes dark while
      transparent mode is on, because 100.64.0.0/10 is then routed to a dead
      outbound.
- [ ] Watch `journalctl -u sing-box -f` on the first start and look for the
      tsnet node coming up.
- [ ] Re-check `ssh 201-mono` — it now leaves via the tailscale endpoint rather
      than via tailscale0, so this exercises genuinely new ground.

Rollback, cheapest first: `noughty.proxy.tailscaleOutbound.enable = false`
(back to the bypass, tun still on) → `noughty.proxy.transparent = false` (back
to an `$http_proxy`-only proxy) → previous generation from the boot menu.

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
  after deploy** before calling this done. Checked at build time: in the
  rendered `~/.ssh/config` the bypass block sits at line 10 with
  `ProxyCommand none`, ~250 lines above the catch-all's `socat` line. Still
  worth running once on the live system, since that only proves the file.
- sing-box exits immediately if `~/git/bedag-setup/singbox.json` is absent. The
  system unit handles this with `ConditionPathExists` — it stays cleanly
  inactive rather than crash-looping — and is `wantedBy` nothing on a host
  without the tag. (The `RestartSec`/`StartLimit` backoff the *user* unit used
  for this is gone with it; `Restart = on-failure` / `RestartSec = 30` remain
  for real crashes.)
- **The homelab now depends on sing-box.** Previously the tailnet was carved
  out and tailscaled carried it regardless of the proxy's health; now
  100.64.0.0/10 is routed to sing-box's own tailscale endpoint. If sing-box is
  down the tun goes with it and tailscaled takes over again (safe), but if
  sing-box is *up* and the endpoint failed to register, homelab traffic is
  routed to a dead outbound — `deploy` and homelab ssh included. That is the
  single most likely way this bites, and the pre-auth key expiring is the most
  likely cause; see the pre-flight above.
- The proxy env vars are now system-wide (`/etc/set-environment`), so they are
  no longer scoped to home-manager's shells. Verified in the built generation:
  `http_proxy`/`HTTP_PROXY` → `http://localhost:2080` and the matching
  `no_proxy`/`NO_PROXY` bypass list. Anything that was silently unproxied
  before because it never sourced hm-session-vars is now proxied — watch for
  that on first login.
- Rollout: **not `deploy z14`** — that was wrong in this plan from the start.
  z14 carries no `deploy.hostname` (laptops are deploy *clients*, not targets)
  and `deploy --list` does not include it. It rebuilds itself:

      sudo nixos-rebuild switch --flake ~/git/nixconfig#z14 --impure

  `--impure` is load-bearing: `lib/registry.nix` reaches for
  `/etc/nixos/hardware-configuration.nix` and `modules/work/external.nix`
  probes for the private checkout with `builtins.pathExists`.

  `nixos-rebuild build` (no sudo) has been run and succeeds, so the switch is
  the only step left. Back out by dropping the `"work"` tag from the registry
  entry and rebuilding — every other change here is inert without it.
