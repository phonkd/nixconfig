{
  withSystem,
  inputs,
  self,
  ...
}:

{
  # Cross-platform HM half of the work setup. Imported by mac.nix directly,
  # and on NixOS by `nixosModules.work` below.
  #
  # Deliberately thin: the work config itself is private, in the separate work
  # repo (imported by path in external.nix); this repo carries only the
  # wiring, never the content.
  flake.homeModules.work =
    { pkgs, ... }:
    {
      imports = [
        self.homeModules.work-external-config
        # `homeModules.proxy` is deliberately NOT imported here even though the
        # work ssh config's `Host *` catch-all depends on it: on the Mac,
        # gui-darwin already imports it for every darwin desktop, and a second
        # import path to the same function module would duplicate its option
        # definitions, colliding on `home.sessionVariables`. On Linux the proxy
        # is a *system* service (`nixosModules.proxy`, enabled below), so
        # `homeModules.proxy` stays darwin-only and reached by one path.
      ];
    };

  # Everything that must NOT go through the work proxy.
  #
  # The work repo's ssh.nix ends in a `Host *` catch-all whose ProxyCommand is
  # `socat - SOCKS:127.0.0.1:%h:%p,socksport=2080`, and ssh_config is
  # first-match-wins *per keyword*: a block that matches earlier but says
  # nothing about ProxyCommand still inherits the catch-all's, so bypassing it
  # takes an explicit `ProxyCommand none` (same reason mac.nix spells it out on
  # every tailnet entry). home-manager renders all `matchBlocks` before
  # `extraConfig` (where that catch-all blob lands), so this is guaranteed to
  # sit above it.
  #
  # Linux counterpart of the mac.nix blocks, imported ONLY from
  # nixosModules.work (the Mac declares its own; two definitions of the same
  # matchBlock name would collide). No `hostname` mapping needed here: NixOS
  # hosts accept MagicDNS (modules/tailnet.nix), so short names resolve.
  flake.homeModules.work-ssh-bypass =
    { lib, ... }:
    {
      programs.ssh.matchBlocks."work-proxy-bypass" = {
        host = lib.concatStringsSep " " [
          # Tailnet: raw CGNAT IPs (deploy targets) and the MagicDNS names.
          "100.64.0.*"
          "*.ts.net"
          "201-mono"
          "203-media"
          "204-agent"
          "205-builder"
          "observability"
          "obs"
          # Local VMs and forwarded services must never cross the work proxy.
          "localhost"
          "127.0.0.1"
          # Non-enrolled LAN boxes (Proxmox et al) and forge access, which have
          # no business crossing a work proxy either.
          "192.168.1.*"
          "192.168.3.*"
          "github.com"
        ];
        proxyCommand = "none";
        extraOptions = {
          # The catch-all's own `Host *` preamble sets StrictHostKeyChecking no
          # + UserKnownHostsFile /dev/null, which would otherwise apply to these
          # hosts too (nothing earlier sets either keyword). Put normal
          # host-key checking back for the machines we actually own.
          StrictHostKeyChecking = "accept-new";
          UserKnownHostsFile = "~/.ssh/known_hosts";
        };
      };
    };

  # NixOS half, gated on the "work" host tag (lib/registry.nix). Wired via
  # builder.nix alwaysImport, same as every other cross-host feature module.
  flake.nixosModules.work =
    {
      pkgs,
      lib,
      config,
      noughtyLib,
      ...
    }:
    let
      # Citrix Workspace, for the ICA sessions. Pulled from nixpkgs-unstable's
      # `citrix-workspace` (our pin only has `citrix_workspace_26_01_0`, which
      # links libsoup 2.4 -- nixpkgs marks it insecure and needs a
      # `permittedInsecurePackages` allowance, and current nixpkgs has already
      # replaced it with a `throw` for that reason). Unstable's build is the
      # GCC 11 line (libsoup 3 + WebKitGTK 4.1, no allowance needed) and
      # carries the `wfica` X11 pin (NixOS/nixpkgs#540102): wfica is an X11
      # client under XWayland, and without the pin Mesa's EGL loader selects
      # the Wayland platform for its startup GL probe and segfaults in
      # wl_proxy_create_wrapper -- every launch, since Hyprland is the only
      # session on the host carrying this tag.
      #
      # `import`, not the `inputs.nixpkgs-unstable.legacyPackages.<sys>`
      # spelling used elsewhere: that pulls *free* packages via the input's own
      # default config (allowUnfree false); ours is set on the host.
      unstable = import inputs.nixpkgs-unstable {
        inherit (pkgs.stdenv.hostPlatform) system;
        config.allowUnfree = true;
      };

      # Re-pinned to 26.08.0.153, the current *tech preview* build (same GCC 11
      # line the expression is written against). Citrix rotates tech previews
      # out of the download portal and demotes old ones to "Earlier Versions",
      # where only a GCC 8 tarball remains -- not interchangeable with this
      # GCC 11 expression (different checksum, assumes libsoup 3 + no
      # WebKitGTK 4.0 bundle). Nothing else in the expression reads `version`
      # (only `src.name` and the requireFile message), so this stays a clean
      # two-field override. Expect to redo this: bump both fields to whatever
      # the tech preview page currently offers when the hash stops matching.
      citrixWorkspace = unstable.citrix-workspace.overrideAttrs (prev: {
        version = "26.08.0.153";
        src = unstable.requireFile {
          name = "linuxx64-26.08.0.153.tar.gz";
          sha256 = "17f0nlg18bz2b6qq86i04igm551b54nym41zi13m81906fzgi4h7";
          message = ''
            Citrix Workspace is `requireFile`: it cannot be fetched
            automatically, and the download is behind a click-through.

            Get the x86_64 *tarball* for version 26.08.0.153 from the tech
            preview listing -- NOT the "Earlier Versions" section, whose
            remaining 26.x tarballs are the GCC 8 build and will not satisfy
            this hash:

              https://www.citrix.com/downloads/workspace-app/

            The file must be named linuxx64-26.08.0.153.tar.gz (no `gcc-8` in
            the name). Then:

              nix-prefetch-url "file://$PWD/linuxx64-26.08.0.153.tar.gz"
          '';
        };
      });
    in
    {
      # Declared outside the tag gate -- options may not live inside mkIf.
      # Both default false because both packages are `requireFile`: nixpkgs
      # cannot fetch them, so a build only succeeds once the installer has been
      # added to the store by hand. Flipping either of these on a machine that
      # has not done that turns every `deploy z14` into a hard eval failure,
      # which is why neither is simply on with the tag.
      options.noughty.work = {
        displaylink.enable = lib.mkEnableOption ''
          the DisplayLink dock driver (evdi + DisplayLinkManager).

          Prerequisite, once per release, on the machine itself:

              nix-prefetch-url --name displaylink-620.zip <url>

          The exact URL is printed by the package's own requireFile message --
          Synaptics puts the download behind an EULA click-through, so there
          is no non-interactive route
        '';

        citrix.enable = lib.mkEnableOption ''
          Citrix Workspace, the ICA session client.

          Same requireFile prerequisite as displaylink above: `nix build` will
          print the file it wants and where to get it. This is what supplies
          the .ica handler that the work repo's `ica-proxy` already assumes
          exists on Linux -- that branch rewrites the file and hands it to
          `xdg-open`, which needs something on the other end
        '';
      };

      config = lib.mkIf (noughtyLib.hostHasTag "work") {
        # Smartcard stack for the yubikey the work tunnel script reads TOTPs
        # from. `yubikey-manager` also arrives via modules/desktop.nix, but pcscd
        # and the udev rules do not, and without them ykman sees no device.
        services.pcscd.enable = lib.mkForce true;
        programs.yubikey-manager.enable = lib.mkForce true;
        services.udev.packages = [ pkgs.yubikey-personalization ];
        environment.systemPackages =
          with pkgs;
          [
            yubioath-flutter

            # Teams. `pkgs.teams` (the Mac cask's counterpart) is darwin-only,
            # so this unofficial Electron wrapper is the packaged route here.
            # Screen sharing needs nothing added here even though it looks like
            # it should: it wants xdg-desktop-portal-hyprland, pipewire, and
            # `--enable-features=WebRTCPipeWireCapturer` guarded on
            # NIXOS_OZONE_WL + WAYLAND_DISPLAY, all already true (the wrapper
            # sets the flag itself; modules/desktop.nix sets NIXOS_OZONE_WL).
            teams-for-linux
          ]
          # let-bound above, not a pkgs attribute -- a `let` binding wins over
          # `with`, which is what makes naming it here work.
          ++ lib.optional config.noughty.work.citrix.enable citrixWorkspace;

        # DisplayLink. Membership in this list is the *sole* gate on
        # nixos/modules/hardware/video/displaylink.nix (evdi kernel module,
        # udev rules, dlm service). Two things that module does are Xorg-shaped
        # and simply inert here, not broken: its `sessionCommands` xrandr call
        # only runs in an X session, and its `display-manager.service`
        # ordering targets a unit z14 doesn't have (greetd) -- systemd ignores
        # ordering against absent units. dlm starts via the package's own udev
        # rules when the dock appears.
        services.xserver.videoDrivers = lib.mkIf config.noughty.work.displaylink.enable [
          "displaylink"
        ];

        # The Linux side of the sing-box proxy: a *system* service, so this
        # just flips the switch on `nixosModules.proxy` (self-gated on this
        # option). See the note in `homeModules.work` for why the proxy hangs
        # off the platform modules rather than off `work` itself.
        #
        # Opt-in HTTP/SOCKS proxy on 127.0.0.1:2080 only -- no tun, nothing
        # captured; the homelab rides tailscaled and anything ignoring
        # `$http_proxy` goes direct. modules/proxy/nixos.nix has the why.
        noughty.proxy.enable = true;

        home-manager.users.${config.noughty.user.name}.imports = [
          self.homeModules.work
          self.homeModules.work-ssh-bypass
        ];
      };
    };
}
