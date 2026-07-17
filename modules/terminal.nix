{ inputs, ... }:

{
  flake.homeModules.terminal =
    { pkgs, ... }:
    {
      programs.kitty = {
        enable = true;
        package = pkgs.kitty;
        themeFile = "cherry-midnight";
        settings = {
          pixel_scroll = "yes";
          font_size = 16;
          clipboard_control = "write-clipboard write-primary read-clipboard no-append";
          # Smoother redraws for fast-updating TUIs like cava.
          repaint_delay = 6;
          input_delay = 1;
          sync_to_monitor = "yes";
        };
        keybindings = {
          "cmd+left" = "send_text all \\x01";
          "cmd+right" = "send_text all \\x05";
        };
        shellIntegration.enableZshIntegration = true;
      };
  };
}
