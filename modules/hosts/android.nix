{
  self,
  inputs,
  pkgs,
  ...
}:
{
  imports = [
    inputs.nix-on-droid
    inputs.home-manager.flakeModules.home-manager
  ];
  flake.nixOnDroidConfigurations."android" = inputs.nix-on-droid.lib.nixOnDroidConfiguration {
    modules = [
      {
        home-manager.config = {pkgs, ...}: {
          imports = [ self.homeModules.shell ];
        };
      }
    ];
  };
}
