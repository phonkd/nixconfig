{
  self,
  inputs,
  ...
}:
{
  flake.nixosConfigurations."203-spot" = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules."203-spot"
      self.nixosModules.gigaplayer-server
      self.nixosModules.server-nixos
      self.nixosModules.server-applist
      self.nixosModules.oldblac-vm
    ];
  };
  flake.nixosModules."203-spot" =
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
          address = "192.168.1.203";
          prefixLength = 24;
        }
      ];
      networking.firewall.allowedTCPPorts = [
        22
      ];
      nix.gc = {
        automatic = true;
        dates = "daily";
        options = "--delete-older-than 3d";
      };
    };
}
