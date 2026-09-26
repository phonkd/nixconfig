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
        # `home.sessionVariables`. Linux does not import it at all any more:
        # the proxy is a *system* service there (`nixosModules.proxy`, which
        # `nixosModules.work` below just enables), so `homeModules.proxy` is
        # darwin-only and still reached by exactly one path.
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
    let
      # Citrix Workspace, for the ICA sessions.
      #
      # This used to read `citrix-workspace` straight out of `pkgs`, which does
      # not exist on our pin -- nixpkgs only renamed the attribute away from
      # `citrix_workspace*` later. `lib.optional` is lazy and the option below
      # defaults false, so the missing attribute never evaluated and the
      # mistake stayed invisible: the first `citrix.enable = true` would have
      # failed eval with `attribute 'citrix-workspace' missing` rather than
      # installing anything.
      #
      # Naming the pin's real attribute instead would mean
      # `citrix_workspace_26_01_0`, which is a trap of its own: it links
      # libsoup 2.4, which nixpkgs marks insecure, so that does not evaluate
      # either without a system-wide
      # `permittedInsecurePackages = [ "libsoup-2.74.3" ]` on this host. It is
      # also a dead end -- current nixpkgs has already replaced that attribute
      # with a `throw` for exactly that reason, so it would break at the next
      # flake bump. Unstable's `citrix-workspace` is the GCC 11 package line,
      # links libsoup 3 + WebKitGTK 4.1, and needs no allowance.
      #
      # It also carries the `wfica` X11 pin (NixOS/nixpkgs#540102) that the pin
      # lacks, and that one matters here specifically: wfica is an X11 client
      # running under XWayland, and on a Wayland session Mesa's EGL loader
      # otherwise selects the Wayland platform for its startup GL probe and it
      # segfaults in wl_proxy_create_wrapper. Hyprland is the only session on
      # the one host carrying this tag, so that would be every launch.
      #
      # `import` rather than the `inputs.nixpkgs-unstable.legacyPackages.<sys>`
      # spelling used in modules/zed-editor.nix and modules/desktop.nix: those
      # pull *free* packages, and an input's bare legacyPackages carries that
      # input's own default config, where allowUnfree is false. Ours is set on
      # the host, not on the input.
      unstable = import inputs.nixpkgs-unstable {
        inherit (pkgs.stdenv.hostPlatform) system;
        config.allowUnfree = true;
      };

      # Re-pinned off nixpkgs' 26.04.0.105, which cannot be obtained any more.
      #
      # That version is a *tech preview* build, and Citrix does not keep those
      # around: by the time this was wired up, 26.04 had been demoted to
      # "Earlier Versions", where only the `linuxx64-gcc-8-26.04.0.105.tar.gz`
      # variant is still published. The GCC 8 tarball is not interchangeable
      # with the GCC 11 one this expression is written against -- different
      # build line, different checksum, and the expression strips a
      # WebKitGTK 4.0 bundle and links libsoup 3 on the assumption of GCC 11 --
      # so feeding it the file that *is* still downloadable would not have
      # worked either.
      #
      # 26.08.0.153 is the current tech preview and the same GCC 11 line, so
      # only the version and the file it asks for change. Nothing else in the
      # expression reads `version` (it appears in `src.name` and in the
      # requireFile message, nothing more), which is what makes this a clean
      # two-field override rather than a fork of the package.
      #
      # Expect to redo this. Citrix rotates tech previews out of the download
      # portal, so the version here goes stale the same way 26.04 did; when the
      # build starts asking for a tarball the portal no longer lists, bump both
      # fields to whatever the tech preview page currently offers.
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
          # let-bound above, not a pkgs attribute -- a `let` binding wins over
          # `with`, which is what makes naming it here work.
          ++ lib.optional config.noughty.work.citrix.enable citrixWorkspace;

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
        # rather than off `work` itself.
        #
        # What this gets is an opt-in HTTP/SOCKS proxy on 127.0.0.1:2080.
        # Nothing is captured: the tun that briefly made this a system-wide
        # proxy has been removed, so the homelab rides tailscaled and anything
        # ignoring `$http_proxy` goes direct. modules/proxy/nixos.nix has the
        # why; the README next to it has what the tun cost to get working,
        # should it ever be wanted again.
        noughty.proxy.enable = true;

        home-manager.users.${config.noughty.user.name}.imports = [
          self.homeModules.work
          self.homeModules.work-ssh-bypass
        ];
      };
    };
}
