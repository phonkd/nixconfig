{
  self,
  inputs,
  pkgs,
  ...
}:
{
  imports = [
    #inputs.nix-on-droid
    inputs.home-manager.flakeModules.home-manager
  ];
  flake.darwinConfigurations."Eliss-MacBook-Pro" = inputs.nix-darwin.lib.darwinSystem {
    modules = [
      self.darwinModules.macm4
      inputs.home-manager.darwinModules.home-manager
      {
        imports = [ self.module.darwin.work ];
      }
    ];

  };
  flake.nixOnDroidConfigurations."android" = inputs.nix-on-droid.lib.nixOnDroidSystem {
    modules = [
      {
        home-manager.config = {pkgs, ...}: {
          imports = [ self.homeModules.shell ];
        };
      }
    ];
  };
}
