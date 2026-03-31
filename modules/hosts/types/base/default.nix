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
      imports = [
        self.homeModules.shell
      ];
    };
}
