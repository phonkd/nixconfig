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
      ];
    };
}
