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
    lib.mkIf (noughtyLib.hostHasTag "work") {
      # Smartcard stack for the yubikey the work tunnel script reads TOTPs
      # from. `yubikey-manager` also arrives via modules/desktop.nix, but pcscd
      # and the udev rules do not, and without them ykman sees no device.
      services.pcscd.enable = lib.mkForce true;
      programs.yubikey-manager.enable = lib.mkForce true;
      services.udev.packages = [ pkgs.yubikey-personalization ];
      environment.systemPackages = with pkgs; [
        yubioath-flutter
      ];

      home-manager.users.${config.noughty.user.name}.imports = [
        self.homeModules.work
        # The Linux import of the sing-box proxy -- see the note in
        # `homeModules.work` for why it hangs off the platform modules rather
        # than off `work` itself. On NixOS it runs as a systemd user unit.
        self.homeModules.proxy
        self.homeModules.work-ssh-bypass
      ];
    };
}
