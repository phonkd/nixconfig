{
  self,
  inputs,
  ...
}:
{
  # server-sops imports the sops-nix module unconditionally, so we use
  # the long-form pattern (imports outside, config gated). Wired up on
  # servers AND NixOS desktops: the latter now enrol in the headscale
  # tailnet (modules/tailnet.nix), whose pre-auth key comes from this same
  # global secret file. Decryption is by the shared user age key at
  # /home/phonkd/.config/sops/age/keys.txt (a recipient of secret.yaml) --
  # so a desktop only needs that keyfile present, no re-encryption.
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
      config = lib.mkIf (config.noughty.host.is.server || config.noughty.host.is.nixosDesktop) {
        sops.age = {
          keyFile = "/home/phonkd/.config/sops/age/keys.txt";
        };
        sops.defaultSopsFile = ./global-secrets/secret.yaml;
      };
    };
}
