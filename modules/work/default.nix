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
  # Deliberately thin. The work config itself is private and lives in the
  # separate work repo (imported by path in external.nix) -- this repo is
  # public, so it carries only the wiring, never the content. There used to be
  # a `work-tools` module here duplicating that repo's own tools.nix package
  # list almost exactly; both were imported, so the public copy was redundant
  # as well as a needless disclosure of the work toolchain. It is gone, and
  # the private list is now the single source.
  flake.homeModules.work =
    { pkgs, ... }:
    {
      imports = [
        self.homeModules.work-external-config
        # NB: `homeModules.proxy` is deliberately NOT imported here even though
        # the work ssh config's `Host *` catch-all depends on it. On the Mac,
        # gui-darwin already imports it for every darwin desktop, and a second
        # import path to the same function module would duplicate its option
        # definitions (Nix can't dedupe function modules), colliding on
        # `home.sessionVariables`. The Linux side picks it up in
        # `nixosModules.work` below, so each platform imports it exactly once.
      ];
    };

  # Everything that must NOT go through the work proxy.
  #
  # The work repo's ssh.nix ends in a `Host *` catch-all whose ProxyCommand is
  # `socat - SOCKS:127.0.0.1:%h:%p,socksport=2080`, and ssh_config is
  # first-match-wins *per keyword*: a block that matches earlier but says
  # nothing about ProxyCommand still inherits the catch-all's. So bypassing it
  # takes an explicit `ProxyCommand none`, not merely an earlier block --
  # the same reason modules/hosts/mac.nix spells it out on every tailnet entry.
  #
  # Ordering is in our favour: home-manager renders all `matchBlocks` first and
  # only then `extraConfig` (which is where that whole blob lands), so
  # anything declared here is guaranteed to sit above the catch-all.
  #
  # This is the Linux counterpart of those mac.nix blocks and is imported ONLY
  # from nixosModules.work -- the Mac already declares its own, and two
  # definitions of the same matchBlock name would collide. Unlike the Mac, no
  # `hostname` mapping is needed: NixOS hosts accept MagicDNS (tailscaled owns
  # resolv.conf -- see modules/tailnet.nix), so the short names resolve.
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
  #
  # This replaces a `flake.module.nixos."work"` that was dead code: nothing in
  # this flake ever read `flake.module.*` -- the builder consumes
  # `flake.nixosModules.*` -- so the yubikey/pcscd bits below never reached a
  # single host despite being written years ago.
  flake.nixosModules.work =
    {
      pkgs,
      lib,
      config,
      noughtyLib,
      ...
    }:
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

            # Teams. `pkgs.teams` is the Mac cask's counterpart and is
            # darwin-only (its `platforms` lists only x86_64/aarch64-darwin),
            # so this unofficial Electron wrapper is the only packaged route
            # on Linux -- the alternative was the PWA, which is the same
            # Electron shell with fewer knobs.
            #
            # Screen sharing -- the part that actually breaks -- needs nothing
            # added here, which is worth stating because it looks like it
            # should. It wants three things and z14 already has all three:
            # xdg-desktop-portal-hyprland (installed by programs.hyprland, see
            # modules/hyprland/_nixos.nix), pipewire (modules/desktop.nix), and
            # the app launched with `--enable-features=WebRTCPipeWireCapturer`.
            # The last one is in the nixpkgs wrapper already, guarded on
            # `NIXOS_OZONE_WL` + `WAYLAND_DISPLAY` being set -- and
            # modules/desktop.nix:407 sets NIXOS_OZONE_WL = "1". So an
            # overrideAttrs re-adding those flags would be pure duplication.
            teams-for-linux
          ]
          ++ lib.optional config.noughty.work.citrix.enable citrix-workspace;

        # DisplayLink. Membership in this list is the *sole* gate on
        # nixos/modules/hardware/video/displaylink.nix, which is what brings
        # the evdi kernel module, the udev rules and the dlm service.
        #
        # Two things that module does are Xorg-shaped and simply inert here,
        # rather than broken: its `sessionCommands` xrandr call only runs in an
        # X session, and its `after = [ "display-manager.service" ]` orders
        # against a unit z14 does not have (greetd, per modules/desktop.nix) --
        # systemd ignores ordering against absent units, so nothing blocks.
        # dlm is not `wantedBy` anything either way: the displaylink package's
        # own udev rules start it when the dock appears, which is what we want.
        services.xserver.videoDrivers = lib.mkIf config.noughty.work.displaylink.enable [
          "displaylink"
        ];

        # The Linux side of the sing-box proxy. It is no longer a home-manager
        # import at all: on NixOS it is a *system* service, so all this does is
        # flip the switch on `nixosModules.proxy` (which alwaysImport already
        # carries and which self-gates on this option). See the note in
        # `homeModules.work` for why the proxy hangs off the platform modules
        # rather than off `work` itself, and modules/proxy.nix for why the Linux
        # half went system-wide.
        noughty.proxy.enable = true;

        home-manager.users.${config.noughty.user.name}.imports = [
          self.homeModules.work
          self.homeModules.work-ssh-bypass
        ];
      };
    };
}
