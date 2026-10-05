# One compositor module; shared shell, wallpaper and session services are in gui-session/.
{ self, inputs, ... }:
let
  homeModule = { config, lib, pkgs, osConfig ? null, ... }:
    let
      scope = import ./gui-session/_scope.nix { inherit config lib pkgs self inputs osConfig; };
      monique = inputs.monique.packages.${pkgs.system}.default;
      inherit (scope) cursorName cursorSize dispatch generated groupbarMode
        groupBinds hy3 hy3Plugin hyprctl kitty layout layoutSettings mod
        monitorsConf moveWindowDispatch scale sinkSwitcher workspaceBinds zen;
      # Lid close follows Caelestia's "keep awake" toggle. That toggle is only a
      # Wayland idle inhibitor -- hypridle honours it, logind's lid switch does
      # not -- so Hyprland holds logind's handle-lid-switch lock (exec-once
      # below) and decides here instead: keep awake on -> only blank the panel,
      # so music, wifi and downloads carry on; off -> suspend as before. Docked
      # (another monitor up) does nothing, like logind's
      # HandleLidSwitchDocked=ignore. A shell that doesn't answer isn't "true",
      # so it falls back to suspend.
      jq = "${pkgs.jq}/bin/jq";
      lidClose = pkgs.writeShellScript "hypr-lid-close" ''
        monitors=$(${hyprctl} monitors -j)
        [ "$(echo "$monitors" | ${jq} length)" -gt 1 ] && exit 0
        if [ "$(${lib.getExe' config.programs.caelestia.package "caelestia-shell"} ipc call idleInhibitor isEnabled)" = true ]; then
          for m in $(echo "$monitors" | ${jq} -r '.[].name | select(startswith("eDP"))'); do
            ${hyprctl} dispatch dpms off "$m"
          done
        else
          ${pkgs.systemd}/bin/systemctl suspend
        fi
      '';
      # The loop ends once Hyprland's socket is gone, handing the lid back to
      # logind for the greeter or a tty.
      lidInhibit = "${pkgs.systemd}/bin/systemd-inhibit --what=handle-lid-switch --who=Hyprland"
        + " --why='Lid follows the Caelestia keep-awake toggle' --mode=block"
        + " ${pkgs.bash}/bin/sh -c 'while ${hyprctl} version >/dev/null 2>&1; do sleep 30; done'";
      # SHORTCUTS: add or change a line in the lists below.
      # Each line is "MODIFIERS, KEY, ACTION, ARGUMENT". For example:
      #   "SUPER SHIFT, T, exec, ${kitty}"
      # SUPER is the Windows key; `mod` is Alt. Use `exec` to launch a program.
      # A trailing comma means the action takes no argument.
      # bind = normal key; bindel = repeat while held; bindl = works while locked;
      # bindm = mouse drag. Group and workspace shortcuts are appended below;
      # their layout-aware definitions live in gui-session/_scope.nix.
      keybinds = {
        bind = [
          # Focus and move windows with Alt+H/J/K/L (left/down/up/right).
          "${mod}, H, ${dispatch "movefocus"}, l"
          "${mod}, J, ${dispatch "movefocus"}, d"
          "${mod}, K, ${dispatch "movefocus"}, u"
          "${mod}, L, ${dispatch "movefocus"}, r"
          "${mod} SHIFT, H, ${moveWindowDispatch}, l"
          "${mod} SHIFT, J, ${moveWindowDispatch}, d"
          "${mod} SHIFT, K, ${moveWindowDispatch}, u"
          "${mod} SHIFT, L, ${moveWindowDispatch}, r"
        ] ++ groupBinds ++ [
          # Window actions and apps.
          "${mod}, F, fullscreen, 0"
          "SUPER, Q, ${dispatch "killactive"},"
          "SUPER, SPACE, togglefloating,"
          "${mod}, B, exec, ${zen}"
          "${mod}, V, exec, ${kitty}"
          "SUPER, D, exec, ${pkgs.rofi}/bin/rofi -show combi"
          "SUPER, E, exec, ${pkgs.nautilus}/bin/nautilus"
          "SUPER, L, exec, ${pkgs.hyprlock}/bin/hyprlock"
          "SUPER SHIFT, E, exit,"

          # Screenshots. code:10/11/12 are the physical 1/2/3 keys, so
          # Alt+Shift still works with the Swiss keyboard layout.
          "${mod} SHIFT, code:10, exec, grim -g \"$(slurp -o)\" - | satty -f -"
          "${mod} SHIFT, code:11, exec, grim -g \"$(slurp)\" - | satty -f -"
          "${mod} SHIFT, code:12, exec, grim -g \"$(slurp)\" - | satty -f -"
          ", Print, exec, ${pkgs.grimblast}/bin/grimblast --freeze copysave area"
          "SHIFT, Print, exec, grim -g \"$(slurp)\" - | satty -f -"

          # Desktop tools.
          "SUPER, P, exec, ${monique}/bin/monique"
          "SUPER, C, exec, ${pkgs.hyprpicker}/bin/hyprpicker -a"
          "SUPER, V, exec, ${pkgs.cliphist}/bin/cliphist list | ${pkgs.rofi}/bin/rofi -dmenu | ${pkgs.cliphist}/bin/cliphist decode | ${pkgs.wl-clipboard}/bin/wl-copy"
          "SUPER, W, exec, ${pkgs.systemd}/bin/systemctl --user start gui-wallpaper.service"
          "SUPER, code:19, exec, ${sinkSwitcher}"
        ] ++ workspaceBinds;
        bindel = [
          # Volume and brightness repeat while the keys are held.
          "SUPER, M, exec, ${pkgs.wireplumber}/bin/wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%+"
          "SUPER SHIFT, M, exec, ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
          ", XF86AudioMute, exec, ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
          ", XF86AudioMicMute, exec, ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
          "SUPER, I, exec, ${pkgs.brightnessctl}/bin/brightnessctl set 5%+"
          "SUPER SHIFT, i, exec, ${pkgs.brightnessctl}/bin/brightnessctl set 5%-"
        ];
        bindl = [
          "SUPER, B, exec, ${pkgs.playerctl}/bin/playerctl play-pause"
          "SUPER, N, exec, ${pkgs.playerctl}/bin/playerctl next"
          "SUPER SHIFT, N, exec, ${pkgs.playerctl}/bin/playerctl previous"
          ", switch:on:Lid Switch, exec, ${lidClose}"
          ", switch:off:Lid Switch, exec, ${hyprctl} dispatch dpms on"
        ];
        bindm = [
          "SUPER, mouse:272, movewindow"
          "SUPER, mouse:273, resizewindow"
        ];
      };
    in {
      config = lib.mkIf scope.hyprlandEnabled {
        wayland.windowManager.hyprland = {
          enable = true; package = null; portalPackage = null;
          systemd.enable = true; xwayland.enable = true; configType = "hyprlang";
          extraConfig = ''
            source = ${monitorsConf}
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
              scroll_factor = 0.25;
              touchpad = { natural_scroll = false; disable_while_typing = false; clickfinger_behavior = true;
                scroll_factor = 0.25; }; };
            misc = { disable_hyprland_logo = true; disable_splash_rendering = true; vrr = 1; force_default_wallpaper = 0; };
            windowrule = [ "match:class .*, suppress_event maximize"
              "match:title (Authentication Required), float on"
              "match:title (Authentication Required), stay_focused on"
              "match:class ^com\\.gabm\\.satty$, float on" ];
            layerrule = [ "match:namespace ^caelestia-.*, blur on"
              "match:namespace ^caelestia-.*, ignore_alpha 0.3" ];
            exec-once = [ lidInhibit ] ++ lib.optional hy3 "${hyprctl} plugin load ${hy3Plugin} && ${hyprctl} reload config-only";
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
      config = lib.mkIf (enabled && config.noughty.host.is.nixosDesktop) {
        programs.hyprland = { enable = true; withUWSM = false; xwayland.enable = true; };
        environment.systemPackages = lib.optionals config.noughty.host.is.laptop [
          inputs.screenening.packages.${pkgs.system}.default
        ];
        programs.hyprlock.enable = true;
        security.pam.services.hyprlock = { }; security.polkit.enable = true;
        fonts.packages = with pkgs; [ nerd-fonts.jetbrains-mono nerd-fonts.symbols-only
          font-awesome inter noto-fonts noto-fonts-cjk-sans noto-fonts-color-emoji ];
      };
    };
}
