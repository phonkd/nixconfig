{
  self,
  inputs,
  pkgs,
  ...
}:
{
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
