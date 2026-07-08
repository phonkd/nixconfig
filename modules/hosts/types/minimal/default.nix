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
      programs.jujutsu = {
        enable = true;
        settings = {
          user = {
            email = "phonkd@phonkd.net";
            name = "Phonkd";
          };
        };
      };
      programs.fastfetch.enable = true;
      programs.ssh = {
        enable = true;
        matchBlocks = {
          "homelab" = {
            host = "192.168.3.*";
            identityFile = "~/.ssh/id_ed25519_priv";
            identitiesOnly = true;
            user = "phonkd";
          };
          "github" = {
            host = "github.com";
            identityFile = "~/.ssh/id_ed25519_priv";
            identitiesOnly = true;
          };
        };
        matchBlocks."*" = {
          addKeysToAgent = "yes";
          # kitty's xterm-kitty terminfo isn't on most servers; force a
          # widely-known TERM. SetEnv TERM is special-cased by ssh and always
          # applied to the pty, regardless of the server's AcceptEnv.
          extraOptions.SetEnv = "TERM=xterm-256color";
        };
      };
      services.ssh-agent = {
        enable = true;
      };
      services.gpg-agent = {
        enable = true;
        enableZshIntegration = true;
        defaultCacheTtl = 7200;
      };
    };
  flake.nixosModules.system-minimal = { pkgs, ... }: {
    imports = [
      inputs.sops-nix.nixosModules.sops
    ];
    time.timeZone = "Europe/Zurich";
    i18n.defaultLocale = "en_US.UTF-8";

    # Configure keymap
    services.xserver.xkb = {
      layout = "ch";
      variant = "";
    };
    console.keyMap = "sg";
    users.users.phonkd = {
      isNormalUser = true;
      description = "phonkd";
      #extraGroups = [ "wheel" ];
      group = "phonkd";
      shell = pkgs.zsh;
    };
    users.groups.phonkd = { };
    sops.age = {
      keyFile = "/home/phonkd/.config/sops/age/keys.txt";
    };
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    programs.zsh.enable = true;
    nixpkgs.config.allowUnfree = true;
  };
}
