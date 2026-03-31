{ inputs, ... }:

{
  flake.homeModules.test =
    { pkgs, ... }:
    {
      programs.alacritty.enable = true;
    };
}
