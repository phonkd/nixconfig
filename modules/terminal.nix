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
          clipboard_control = "write-clipboard write-primary read-clipboard no-append";
        };
        keybindings = {
          "cmd+left" = "send_text all \\x01";
          "cmd+right" = "send_text all \\x05";
        };
        shellIntegration.enableZshIntegration = true;
      };
  };
}
