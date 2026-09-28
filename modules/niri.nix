{ ... }:
{
  flake.nixosModules.niri-sel =
    {
      config,
      pkgs,
      ...
    }:
    {
      programs.niri.enable = true;

      home-manager.users.${config.noughty.user.name}.xdg.configFile."niri/config.kdl".text = ''
        prefer-no-csd

        binds {
          Mod+D { spawn "${pkgs.rofi}/bin/rofi" "-show" "drun"; }
          Mod+Shift+F { fullscreen-window; }
          Mod+Q repeat=false { close-window; }

          Mod+M { spawn "${pkgs.wireplumber}/bin/wpctl" "set-volume" "-l" "1.4" "@DEFAULT_AUDIO_SINK@" "5%+"; }
          Mod+Shift+M { spawn "${pkgs.wireplumber}/bin/wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%-"; }
          Mod+I { spawn "${pkgs.brightnessctl}/bin/brightnessctl" "set" "5%+"; }
          Mod+Shift+I { spawn "${pkgs.brightnessctl}/bin/brightnessctl" "set" "5%-"; }

          Alt+Q { focus-workspace 1; }
          Alt+W { focus-workspace 2; }
          Alt+E { focus-workspace 3; }
          Alt+A { focus-workspace 4; }
          Alt+S { focus-workspace 5; }
          Alt+D { focus-workspace 6; }

          Alt+Shift+Q { move-window-to-workspace 1; }
          Alt+Shift+W { move-window-to-workspace 2; }
          Alt+Shift+E { move-window-to-workspace 3; }
          Alt+Shift+A { move-window-to-workspace 4; }
          Alt+Shift+S { move-window-to-workspace 5; }
          Alt+Shift+D { move-window-to-workspace 6; }

          Mod+Space { toggle-window-floating; }
          Alt+V { spawn "${pkgs.kitty}/bin/kitty"; }
        }
      '';
    };
}
