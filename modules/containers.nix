{ ... }:

{
  # Rootless podman on NixOS desktops -- the container backend distrobox needs
  # (modules/hosts/types/gui/default.nix ships the distrobox packages; without
  # a backend `distrobox create` aborts with "Missing dependency"). Rootless
  # so containers run as the calling user and $HOME/uid map straight through
  # (needs no manual /etc/subuid: autoSubUidGidRange defaults true). Servers
  # stay out of scope: 201 already enables podman on its own terms for
  # homelab/apps/affine.nix's oci-containers stack.
  #
  # Wired via builder.nix alwaysImport; self-gates on host.is.nixosDesktop.
  flake.nixosModules.containers =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    lib.mkIf config.noughty.host.is.nixosDesktop {
      # `virtualisation.containers.enable` is implied by this -- the upstream
      # podman module sets it, so don't set it again here.
      virtualisation.podman = {
        enable = true;
        # Container name resolution on the default bridge, for multi-container
        # setups; the podman module opens UDP 53 on the interface to match.
        defaultNetwork.settings.dns_enabled = true;
      };
    };
}
