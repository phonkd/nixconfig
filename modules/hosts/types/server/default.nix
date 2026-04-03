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
      #(modulesPath + "/profiles/qemu-guest.nix")
    ];
  };
}
