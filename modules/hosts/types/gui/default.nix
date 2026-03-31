{
  self,
  inputs,
  ...
}:
{
  flake.homeModules.gui =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        self.homeModules.base
        self.homeModules.system-minimal
        self.homeModules.terminal
        self.homeModules.code-editors
        self.homeModules.gui-apps
      ];
    };
}
