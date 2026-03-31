{
  inputs,
  lib,
  ...
}:
{
  flake.homeModules.system-minimal =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      home = {
        username = "phonkd";
        stateVersion = "26.05";
        enableNixpkgsReleaseCheck = true;
      };
      nixpkgs.config.allowUnfree = true;
      #home.homeDirectory = if pkgs.stdenv.isDarwin then "/Users/phonkd" else "/home/phonkd";
      programs.git = {
        enable = true;
        settings = {
          user = {
            email = "phonkd@phonkd.net";
            name = "Phonkd";
          };
          pull.rebase = true;
        };
        includes = [
          {
            condition = "hasconfig:remote.*.url:*github.com*/**";
            contents = {
              core.sshCommand = "ssh -i ~/.ssh/id_ed25519_priv";
            };
          }
        ];
      };
      programs.ssh = {
        enable = true;
        matchBlocks = {
          "homelab" = {
            host = "192.168.1.*";
            identityFile = "~/.ssh/id_ed25519_priv";
            identitiesOnly = true;
          };
          "github" = {
            host = "github.com";
            identityFile = "~/.ssh/id_ed25519_priv";
            identitiesOnly = true;
          };
        };
        matchBlocks."*" = {
          addKeysToAgent = "yes";
        };
      };
      services.ssh-agent = {
        enable = true;
      };
    };
}
