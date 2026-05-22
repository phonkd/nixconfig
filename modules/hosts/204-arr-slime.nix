{
  self,
  inputs,
  ...
}:
{
  flake.nixosConfigurations."204-arr-slime" = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules."204-arr-slime"
      self.nixosModules.server-nixos
      self.nixosModules.server-applist
      self.nixosModules.oldblac-vm
    ];
  };
  flake.nixosModules."204-arr-slime" =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      label.labels = [ "vm" ];
      networking.useDHCP = lib.mkDefault true;
      networking.interfaces.ens18.ipv4.addresses = [
        {
          address = "192.168.3.204";
          prefixLength = 24;
        }
      ];
      networking.firewall.allowedTCPPorts = [
        22
      ];
      nix.gc = lib.mkForce {
        automatic = true;
        dates = "daily";
        options = "--delete-older-than 3d";
      };
      nix.settings.require-sigs = false;
    };
}
