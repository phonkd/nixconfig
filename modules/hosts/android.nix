{
  self,
  inputs,
  ...
}:
{
  flake.nixOnDroidConfigurations."android" = inputs.nix-on-droid.lib.nixOnDroidConfiguration {
    pkgs = import inputs.nixpkgs-unstable-droid {
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
            flake = inputs.nixpkgs-unstable-droid;
          };
          nix.nixPath = [ "nixpkgs=${inputs.nixpkgs-unstable-droid}" ];

        }
      )
    ];

  };
}
