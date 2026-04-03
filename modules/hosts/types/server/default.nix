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
      #(modulesPath + "/profiles/qemu-guest.nix")
    ];
  };
}
