{
  inputs,
  lib,
  self,
  ...
}:
{
  flake.nixosModules.server-nixos = {
    imports = [
      self.nixosModules.server-teleport
      inputs.sops-nix.nixosModules.sops
      self.nixosModules.server-sops
      self.nixosModules.server-globalconfig
      self.nixosModules.oldblac-server
      #(modulesPath + "/profiles/qemu-guest.nix")
    ];
  };
}
