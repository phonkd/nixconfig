{
  self,
  inputs,
  ...
}:
{
  # server-sops imports the sops-nix module unconditionally, so we use
  # the long-form pattern (imports outside, config gated). Gate on
  # is.server so only servers wire up the default sops file path.
  flake.nixosModules.server-sops =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
      ];
      config = lib.mkIf config.noughty.host.is.server {
        sops.age = {
          keyFile = "/home/phonkd/.config/sops/age/keys.txt";
        };
        sops.defaultSopsFile = ./global-secrets/secret.yaml;
      };
    };
}
