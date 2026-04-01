{
  self,
  inputs,
  pkgs,
  ...
}:
{
  flake.nixOnDroidConfigurations."android" = inputs.nix-on-droid.lib.nixOnDroidConfiguration {
    pkgs = import inputs.nixpkgs { system = "aarch64-linux"; };
    modules = [
      {
        home-manager.config = {pkgs, lib, ...}: {
          imports = [ self.homeModules.base ];
          home.username = "nix-on-droid";
          home.stateVersion = lib.mkForce "24.05";
        };
      }
    ];
  };
}
