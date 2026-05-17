{
  inputs,
  lib,
  self,
  ...
}:
{
  flake.nixosModules.server-nixos = {
    imports = [
      inputs.sops-nix.nixosModules.sops
      self.nixosModules.server-sops
      self.nixosModules.server-globalconfig
      self.nixosModules.system-minimal
      #(modulesPath + "/profiles/qemu-guest.nix")
    ];
  };
}
