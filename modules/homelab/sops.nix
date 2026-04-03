{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."server-sops" = { config, pkgs, lib, ... }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
      ];
      sops.age = lib.mkIf isVM {
        keyFile = "/home/phonkd/.config/sops/age/keys.txt";
      };
      sops.defaultSopsFile = ./global-secrets/secret.yaml;
    };

}
