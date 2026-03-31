{ withSystem, inputs, self, ... }:

{
  flake.homeModules.work =
    { pkgs, ... }:
    {
      imports = [
        self.homeModules.work-tools
        self.homeModules.work-external-config
      ];
    };
  flake.module.darwin."work" = {pkgs, ...}: {
    imports = [
      self.modules.darwin.work-privoxy
    ];
  };
}
