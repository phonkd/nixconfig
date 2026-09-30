# One compositor module; shared shell, wallpaper and session services are in gui-session/.
{ self, inputs, ... }:
let
  homeModule = { config, lib, pkgs, osConfig ? null, ... }:
    let
      scope = import ./gui-session/_scope.nix { inherit config lib pkgs self inputs osConfig; };
      inherit (scope) annotate cursorName cursorSize dispatch eeVolume generated groupbarMode
        groupBinds hy3 hy3Plugin hyprctl kitty layout layoutSettings loudnessKnob mod
        monitorsConf moveWindowDispatch scale sinkSwitcher workspaceBinds workspacesConf zen;
      keybinds = {
        bind = [
          "${mod}, H, ${dispatch "movefocus"}, l" "${mod}, J, ${dispatch "movefocus"}, d"
          "${mod}, K, ${dispatch "movefocus"}, u" "${mod}, L, ${dispatch "movefocus"}, r"
          "${mod} SHIFT, H, ${moveWindowDispatch}, l" "${mod} SHIFT, J, ${moveWindowDispatch}, d"
          "${mod} SHIFT, K, ${moveWindowDispatch}, u" "${mod} SHIFT, L, ${moveWindowDispatch}, r"
        ] ++ groupBinds ++ [
          "${mod}, F, fullscreen, 0" "SUPER, Q, ${dispatch "killactive"},"
          "${mod}, B, exec, ${zen}" "${mod}, V, exec, ${kitty}"
          "SUPER, D, exec, ${pkgs.rofi}/bin/rofi -show combi" "SUPER, SPACE, togglefloating,"
          "SUPER, E, exec, ${pkgs.nautilus}/bin/nautilus" "SUPER, L, exec, ${pkgs.hyprlock}/bin/hyprlock"
          "SUPER SHIFT, E, exit," "${mod} SHIFT, code:10, exec, ${annotate "output"}"
          "${mod} SHIFT, code:11, exec, SLURP_ARGS=-r ${annotate "area"}"
          "${mod} SHIFT, code:12, exec, ${annotate "area"}"
          ", Print, exec, ${pkgs.grimblast}/bin/grimblast --freeze copysave area"
          "SHIFT, Print, exec, ${annotate "area"}"
          "SUPER, P, exec, ${pkgs.nwg-displays}/bin/nwg-displays -n 9"
          "SUPER, C, exec, ${pkgs.hyprpicker}/bin/hyprpicker -a"
          "SUPER, V, exec, ${pkgs.cliphist}/bin/cliphist list | ${pkgs.rofi}/bin/rofi -dmenu | ${pkgs.cliphist}/bin/cliphist decode | ${pkgs.wl-clipboard}/bin/wl-copy"
          "SUPER, W, exec, ${pkgs.systemd}/bin/systemctl --user start gui-wallpaper.service"
          "SUPER, code:19, exec, ${sinkSwitcher}"
        ] ++ workspaceBinds;
        bindel = [
          "SUPER, M, exec, ${pkgs.wireplumber}/bin/wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%+"
          "SUPER SHIFT, M, exec, ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
        ] ++ lib.optionals loudnessKnob [
          "${mod}, M, exec, ${eeVolume} up" "${mod} SHIFT, M, exec, ${eeVolume} down"
        ] ++ [
          ", XF86AudioMute, exec, ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
          ", XF86AudioMicMute, exec, ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
          "SUPER, I, exec, ${pkgs.brightnessctl}/bin/brightnessctl set 5%+"
          "SUPER SHIFT, i, exec, ${pkgs.brightnessctl}/bin/brightnessctl set 5%-"
        ];
        bindl = [ "SUPER, B, exec, ${pkgs.playerctl}/bin/playerctl play-pause"
          "SUPER, N, exec, ${pkgs.playerctl}/bin/playerctl next"
          "SUPER SHIFT, N, exec, ${pkgs.playerctl}/bin/playerctl previous" ];
        bindm = [ "SUPER, mouse:272, movewindow" "SUPER, mouse:273, resizewindow" ];
      };
    in {
      config = lib.mkIf scope.hyprlandEnabled {
        wayland.windowManager.hyprland = {
          enable = true; package = null; portalPackage = null;
          systemd.enable = true; xwayland.enable = true; configType = "hyprlang";
          extraConfig = ''
            source = ${monitorsConf}
            source = ${workspacesConf}
          '';
          settings = {
            source = [ generated.hypr ] ++ lib.optional (!hy3) groupbarMode;
            monitor = ",preferred,auto,${scale}";
            env = [ "QT_QPA_PLATFORM,wayland;xcb" "MOZ_ENABLE_WAYLAND,1"
              "XCURSOR_THEME,${cursorName}" "XCURSOR_SIZE,${toString cursorSize}" ];
            general = { gaps_in = 8; gaps_out = 16; border_size = 3; inherit layout; resize_on_border = true; };
            decoration = { rounding = 12; blur = { enabled = true; size = 5; passes = 2; new_optimizations = true; }; };
            animations = { enabled = true; bezier = [ "wind, 0.05, 0.9, 0.1, 1.05" ]; animation = [
              "windows, 1, 5, wind" "windowsOut, 1, 5, default, popin 80%"
              "border, 1, 10, default" "fade, 1, 5, default" "workspaces, 1, 5, default" ]; };
            input = { kb_layout = "ch"; kb_variant = "de_nodeadkeys"; follow_mouse = 1;
              scroll_factor = 0.5;
              touchpad = { natural_scroll = false; disable_while_typing = false; clickfinger_behavior = true;
                scroll_factor = 0.5; }; };
            misc = { disable_hyprland_logo = true; disable_splash_rendering = true; vrr = 1; force_default_wallpaper = 0; };
            windowrule = [ "match:class .*, suppress_event maximize"
              "match:title (Authentication Required), float on"
              "match:title (Authentication Required), stay_focused on"
              "match:class ^com\\.gabm\\.satty$, float on" ];
            layerrule = [ "match:namespace ^caelestia-.*, blur on"
              "match:namespace ^caelestia-.*, ignore_alpha 0.3" ];
            exec-once = lib.optional hy3 "${hyprctl} plugin load ${hy3Plugin} && ${hyprctl} reload config-only";
          } // keybinds // layoutSettings;
        };
        programs.hyprlock = {
          enable = true;
          settings = {
            source = [ generated.hyprlock ];
            general.hide_cursor = true;
            background = [ { path = "screenshot"; blur_passes = 3; blur_size = 8; } ];
            input-field = [ { size = "300, 50"; outline_thickness = 2; dots_center = true;
              outer_color = "$lockAccent"; inner_color = "$lockInner"; font_color = "$lockForeground";
              fail_color = "$lockError"; placeholder_text = ""; position = "0, -40";
              halign = "center"; valign = "center"; } ];
            label = [ { text = "$TIME"; font_size = 64; font_family = "Inter";
              color = "$lockForeground"; position = "0, 120"; halign = "center"; valign = "center"; } ];
          };
        };
        services.hypridle = {
          enable = true;
          settings = {
            general = {
              lock_cmd = "${pkgs.procps}/bin/pidof hyprlock || ${pkgs.hyprlock}/bin/hyprlock";
              before_sleep_cmd = "${pkgs.systemd}/bin/loginctl lock-session";
              after_sleep_cmd = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
            };
            listener = [
              { timeout = 300; on-timeout = "${pkgs.brightnessctl}/bin/brightnessctl -s set 10%";
                on-resume = "${pkgs.brightnessctl}/bin/brightnessctl -r"; }
              { timeout = 600; on-timeout = "${pkgs.systemd}/bin/loginctl lock-session"; }
              { timeout = 900; on-timeout = "${pkgs.hyprland}/bin/hyprctl dispatch dpms off";
                on-resume = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on"; }
            ];
          };
        };
      };
    };
in {
  flake.homeModules.hyprland-session = homeModule;
  flake.nixosModules.hyprland = { config, pkgs, lib, noughtyLib, ... }:
    let enabled = noughtyLib.hostHasTag "hyprland"; in {
      options.noughty.hyprland = {
        loudnessKnob = lib.mkOption { type = lib.types.bool; default = false;
          description = "Use Alt+M for the pre-effects EasyEffects volume."; };
        scale = lib.mkOption { type = lib.types.str; default = "1";
          description = "Hyprland output scale (for example 1, 1.25, or auto)."; };
        layout = lib.mkOption { type = lib.types.enum [ "dwindle" "hy3" ]; default = "hy3";
          description = "Hyprland tiling layout."; };
      };
      config = lib.mkIf (enabled && config.noughty.host.is.nixosDesktop) {
        programs.hyprland = { enable = true; withUWSM = false; xwayland.enable = true; };
        programs.hyprlock.enable = true;
        security.pam.services.hyprlock = { }; security.polkit.enable = true;
        fonts.packages = with pkgs; [ nerd-fonts.jetbrains-mono nerd-fonts.symbols-only
          font-awesome inter noto-fonts noto-fonts-cjk-sans noto-fonts-color-emoji ];
      };
    };
}
