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
        };
        keybindings = {
          "cmd+left" = "send_text all \\x01";
          "cmd+right" = "send_text all \\x05";
          # New tabs/windows inherit the active tab's working directory
          # (relies on shell integration's OSC 7 cwd reporting below).
          "cmd+t" = "new_tab_with_cwd";
          "cmd+enter" = "new_window_with_cwd";
          "cmd+n" = "new_os_window_with_cwd";
        };
        shellIntegration.enableZshIntegration = true;
      };
  };
}
