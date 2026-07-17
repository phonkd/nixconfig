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
          # Translucent background with strong macOS blur behind it.
          background_opacity = "0.6";
          background_blur = 64;
          # Cherry-pink border framing the (inset) window.
          draw_minimal_borders = "no";
          window_margin_width = 8;
          window_border_width = "2pt";
          active_border_color = "#ff4d8d";
          inactive_border_color = "#5c2a3d";
        };
        keybindings = {
          "cmd+left" = "send_text all \\x01";
          "cmd+right" = "send_text all \\x05";
        };
        shellIntegration.enableZshIntegration = true;
      };
  };
}
