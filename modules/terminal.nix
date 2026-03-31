{ inputs, ... }:

{
  flake.homeModules.terminal =
    { pkgs, ... }:
    {
      programs.ghostty = {
        enable = true;
        package = if pkgs.stdenv.isDarwin then pkgs.ghostty-bin else pkgs.ghostty;
        settings = {
          theme = "Dracula";
          font-size = 16;
          confirm-close-surface = false;
          keybind = [ "super+enter=new_split:auto" ];
        };
      };
      programs.kitty = {
        enable = false;
        package = pkgs.kitty;
        settings = {
          pixel_scroll = "yes";
          #    momentum_scroll = 0.96;
        };
      };
    };
}
