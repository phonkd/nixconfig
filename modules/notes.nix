{ inputs, self, ... }:

{
  flake.homeModules.notes =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    {
      programs.obsidian = {
        enable = true;
      };
    };
}
