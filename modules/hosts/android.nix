{
  self,
  inputs,
  ...
}:
{
  flake.nixOnDroidConfigurations."android" = inputs.nix-on-droid.lib.nixOnDroidConfiguration {
    pkgs = import inputs.nixpkgs-unstable-droid { system = "aarch64-linux"; };
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
              };

            };
          user.shell = pkgs.zsh;
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
