{ ... }:

{
  # Rootless podman on NixOS desktops -- the container backend distrobox
  # needs. The distrobox packages themselves ship from the `gui-nixos` HM
  # module (modules/hosts/types/gui/default.nix); with no backend on the
  # system side `distrobox create` aborts with "Missing dependency: we need
  # a container manager", which is exactly what blac was doing.
  #
  # Rootless is the point: distrobox containers run as the calling user so
  # $HOME and the uid map straight through. That needs no manual /etc/subuid
  # entry -- users-groups.nix defaults autoSubUidGidRange to true for every
  # isNormalUser, which covers `phonkd` on all three desktops.
  #
  # Servers stay out of scope deliberately. 201 already enables podman on its
  # own terms for the oci-containers stack (homelab/apps/affine.nix), and this
  # module's gate keeps the two from meeting.
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
      # `virtualisation.containers.enable` (the /etc/containers policy and
      # registry config that image pulls need) is implied by this -- the
      # upstream podman module sets it, so don't set it again here.
      virtualisation.podman = {
        enable = true;
        # Container name resolution on the default bridge. distrobox itself
        # doesn't need it, but anything multi-container does, and the podman
        # module opens UDP 53 on the podman interface to match.
        defaultNetwork.settings.dns_enabled = true;
      };
    };
}
