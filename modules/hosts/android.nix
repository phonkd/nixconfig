{
  self,
  inputs,
  pkgs,
  ...
}:
{
  flake.nixOnDroidConfigurations."android" = inputs.nix-on-droid.lib.nixOnDroidConfiguration {
    pkgs = import inputs.nixpkgs-unstable-droid { system = "aarch64-linux"; };
    home-manager-path = inputs.home-manager.outPath;
    modules = [
      {
        system.stateVersion = "24.05";
        home-manager.config = {pkgs, lib, ...}: {
          imports = [ self.homeModules.base ];
          home.username = lib.mkForce "nix-on-droid";
          #home.stateVersion = lib.mkForce "24.05";
        };
      }
    ];

  };
}
