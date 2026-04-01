{
  self,
  inputs,
  ...
}:
{
  flake.homeModules.base =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      modules = [
        self.homeModules.shell
        self.homeModules.system-minimal
        self.homeModules.code-editors
      ];
    };
}
