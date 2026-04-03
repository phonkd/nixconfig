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
        self.homeModules.system-minimal
        self.homeModules.code-editors
      ];
    };
  flake.nixosModules.base =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        self.nixosModules.system-minimal
      ];
    };
}
