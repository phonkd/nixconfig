{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
{
  flake.nixosModules.driftwm-sel = {
    programs.driftwm ={
      enable= true;
    };
  };
  flake.homeModules.driftwm-sel =
  {pkgs, ...}:
  {
    xdg.configFile."driftwm/config.toml".text = ''
      # # Sloppy focus: keyboard focus follows the pointer to windows.
      # # Moving to empty canvas keeps focus; click empty canvas to unfocus.
      focus_follows_mouse = true

      window_placement = "auto"
      #focus_placement = "bottom_right"
      # # Example:
      # # autostart = ["waybar", "swaync"]
      
      [keybindings]
      "alt+v" = "exec ${pkgs.kitty}/bin/kitty"
      "mod+d" = "exec ${pkgs.rofi}/bin/rofi -show drun"
      [session]

      [env]
      # # Environment variables set before any clients launch.
      # # Child processes (autostart, exec bindings) inherit these.
      # # These override the compositor's built-in toolkit defaults
      # # (MOZ_ENABLE_WAYLAND, QT_QPA_PLATFORM, SDL_VIDEODRIVER, GDK_BACKEND, ELECTRON_OZONE_PLATFORM_HINT).
      # # Example:
      QT_WAYLAND_DISABLE_WINDOWDECORATION = "1"
      MOZ_ENABLE_WAYLAND = "1"


      [input.keyboard]
      layout = "ch"              # XKB layout (e.g., "us,ru" for multi-layout)
    '';
  };
}
