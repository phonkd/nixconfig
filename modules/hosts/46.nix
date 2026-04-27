{
  self,
  inputs,
  ...
}:
{
  flake.nixosConfigurations."46" = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules."46"
      self.nixosModules.server-nixos
      self.nixosModules.server-applist
      self.nixosModules.dev-hypervisor
    ];
  };
  flake.nixosModules."46" =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        /etc/nixos/hardware-configuration.nix
      ];
      networking.useDHCP = lib.mkDefault true;
      networking.interfaces.ens18.ipv4.addresses = [
        {
          address = "192.168.1.46";
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
      boot.loader.grub.devices = [ "/dev/sdc" ];

    };
}
