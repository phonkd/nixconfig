{ inputs, ... }:

{
  flake.homeModules.terminal =
    { pkgs, ... }:
    {
      programs.kitty = {
        enable = true;
        package = pkgs.kitty;
        settings = {
          pixel_scroll = "yes";
          font_size = 16;
        };
        shellIntegration.enableZshIntegration = true;
      };
  };
}
