{
  self,
  inputs,
  ...
}:
{
  # Android tracks nixpkgs-unstable rather than the 26.05 the other hosts pin,
  # so it stays in step with home-manager (which follows master). Don't hand-pin
  # a nixpkgs rev here: home-manager's services-modular reads
  # `${pkgs.path}/lib/services/lib.nix`, so a rev older than home-manager fails
  # eval with "path .../lib/services/lib.nix does not exist".
  flake.nixOnDroidConfigurations."android" = inputs.nix-on-droid.lib.nixOnDroidConfiguration {
    pkgs = import inputs.nixpkgs-android {
      system = "aarch64-linux";
      config.allowUnfree = true;

    };
    home-manager-path = inputs.home-manager.outPath;
    modules = [
      (
        { pkgs, ... }:
        {
          system.stateVersion = "24.05";
          home-manager.config =
            { pkgs, lib, ... }:
            {
              imports = [ self.homeModules.base ];
              home.username = lib.mkForce "nix-on-droid";
              # home.packages = with pkgs; [
              #   openssh
              # ];
              #home.stateVersion = lib.mkForce "24.05";
              programs.zellij = {
               enable = true;
               enableZshIntegration = true;
               attachExistingSession = true;  # reattach if session exists
               exitShellOnExit = true;        # exit zsh when you exit zellij
               extraConfig = ''
                default_shell "zsh"
                show_startup_tips false
               '';
               settings = {
                 theme = "everforest-dark";
               };
              };

            };
            user.shell = pkgs.zsh;
            #nixpkgs.config.allowUnfree = true;

          environment.packages = with pkgs; [
            openssh
            gawk
          ];
          nix.extraOptions = ''
            experimental-features = nix-command flakes
          '';
          nix.registry.nixpkgs = {
            flake = inputs.nixpkgs-unstable;
          };
          nix.nixPath = [ "nixpkgs=${inputs.nixpkgs-unstable}" ];

        }
      )
    ];

  };
}
