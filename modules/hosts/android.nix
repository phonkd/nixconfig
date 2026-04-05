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
            };
          user.shell = pkgs.zsh;
          environment.packages = with pkgs; [
            openssh
            gawk
          ];
        }
      )
    ];

  };
}
