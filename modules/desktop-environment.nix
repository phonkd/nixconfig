{
  self,
  inputs,
  config,
  pkgs,
  ...
}:

{
  flake.homeModules.desktop-environment =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    {
      imports = [
        self.homeModules.hyprland
        self.homeModules.bar-nstuff
      ];
    };
  flake.homeModules.hyprland =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    {
      home.packages = with pkgs; [
        waypaper
        swaybg
        grimblast
        grim
        hyprshot
        rofi
        rofi-obsidian
        rofi-systemd
        rofi-rbw
        sqlite
        wdisplays
        cliphist
        hyprcursor
        xdg-desktop-portal
        xdg-desktop-portal-gtk
        swappy
        slurp
        wl-clipboard
        nwg-look
        hyprlock
        bibata-cursors
        nwg-displays
        hyprviz
      ];
      wayland.windowManager.hyprland = {
        enable = true;
        xwayland.enable = true;
        systemd.enable = true;
        plugins = [
        ];
        sourceFirst = false;
        #extraConfig = builtins.readFile ../dotconfig/hypr/hyprland.conf;
        extraConfig = ''
          -- Programs
          local terminal    = "kitty"
          local fileManager = "thunar"
          local menu        = "noctalia-shell ipc call launcher toggle"
          local mainMod     = "SUPER"

          -- Autostart (was `exec-once = ...`)
          hl.on("hyprland.start", function()
            hl.exec_cmd("noctalia-shell")
            hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP")
            hl.exec_cmd("lxqt-policykit-agent")
          end)

          -- Env vars: hl.env(name, value), one call per var
          hl.env("XCURSOR_SIZE",       "40")
          hl.env("XCURSOR_THEME",      "Bibata-Modern-Amber")
          hl.env("HYPRCURSOR_SIZE",    "40")
          hl.env("HYPRCURSOR_THEME",   "Bibata-Modern-Amber")
          hl.env("MOZ_ENABLE_WAYLAND", "1")
          hl.env("QT_CURSOR_THEME",    "Bibata-Modern-Amber")
          hl.env("QT_CURSOR_SIZE",     "40")

          -- Monitor (was `monitor = ,preferred,auto,1.25`)
          hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1.25 })

          -- Main config tree
          hl.config({
            misc = {
              vrr = 1,
              force_default_wallpaper = 0,
              disable_hyprland_logo = true,
            },
            general = {
              gaps_in = 5,
              gaps_out = 15,
              border_size = 3,
              ["col.active_border"]   = "rgba(f1f1f1aa)",
              ["col.inactive_border"] = "rgba(000000aa)",
              layout = "dwindle",
            },
            decoration = {
              rounding = 15,
              active_opacity = 0.8,
              inactive_opacity = 0.6,
              fullscreen_opacity = 1.0,
              blur = {
                enabled = true,
                size = 4,
                passes = 3,
                vibrancy = 0.8,
                ignore_opacity = true,
              },
            },
            animations = { enabled = true },
            -- dwindle.pseudotile is no longer a config key in 0.55+; it's a dispatcher (`pseudo`).
            dwindle    = { preserve_split = true },
            master     = { new_status = "master" },
            input = {
              kb_layout  = "ch",
              kb_variant = "de_nodeadkeys",
              follow_mouse = 1,
              sensitivity = 0,
              touchpad = {
                natural_scroll = false,
                disable_while_typing = false,
              },
            },
          })

          -- hy3 plugin block — left as a Lua block comment for now; port if/when re-enabled.
          --[[
          plugin.hy3 = {
            no_gaps_when_only = 0, node_collapse_policy = 2,
            group_inset = 10, tab_first_window = false,
            tabs = {
              height = 22, padding = 6, from_top = false, radius = 6,
              border_width = 2, render_text = true, text_center = true,
              text_font = "Sans", text_height = 8, text_padding = 3,
              ["col.active"] = "rgba(33ccff40)",
              -- ... (full color set omitted)
              blur = true, opacity = 1.0,
            },
            autotile = { enable = true, ephemeral_groups = true, trigger_width = 0, trigger_height = 0, workspaces = "all" },
          }
          --]]

          -- Beziers + animations
          hl.curve("myBezier", { type = "bezier", points = { { 0.05, 0.9 }, { 0.1, 1.05 } } })
          hl.animation({ leaf = "windows",     enabled = true, speed = 7,  bezier = "myBezier" })
          hl.animation({ leaf = "windowsOut",  enabled = true, speed = 7,  bezier = "default", style = "popin 80%" })
          hl.animation({ leaf = "border",      enabled = true, speed = 10, bezier = "default" })
          hl.animation({ leaf = "borderangle", enabled = true, speed = 8,  bezier = "default" })
          hl.animation({ leaf = "fade",        enabled = true, speed = 7,  bezier = "default" })
          hl.animation({ leaf = "workspaces",  enabled = true, speed = 6,  bezier = "default" })

          -- Per-device input
          hl.device({ name = "logitech-usb-receiver",                     sensitivity = -0.4, accel_profile = "flat" })
          hl.device({ name = "haste-2-wireless-mouse",                    sensitivity = -0.4, accel_profile = "flat" })
          hl.device({ name = "hp,-inc-hyperx-pulsefire-haste-2-wireless", sensitivity = -0.4, accel_profile = "flat" })
          hl.device({ name = "company--usb-device--1",                    sensitivity = -0.4, accel_profile = "flat" })


          --------------------------------------------------------------------
          -- Keybinds
          --------------------------------------------------------------------
          hl.bind("ALT+V",                  hl.dsp.exec_cmd(terminal))
          hl.bind(mainMod .. "+Q",          hl.dsp.window.close())
          hl.bind(mainMod .. "+SHIFT+E",    hl.dsp.exit())
          hl.bind(mainMod .. "+E",          hl.dsp.exec_cmd(fileManager))
          hl.bind(mainMod .. "+W",          hl.dsp.exec_cmd("librewolf"))

          -- Applets
          hl.bind(mainMod .. "+O",          hl.dsp.exec_cmd("rofi -show rofi-obsidian:rofi-obsidian"))
          hl.bind(mainMod .. "+SHIFT+O",    hl.dsp.exec_cmd("~/.config/rofi-pulse-select sink"))
          hl.bind("SUPER+V",                hl.dsp.exec_cmd("noctalia-shell ipc call launcher clipboard"))
          hl.bind(mainMod .. "+Z",          hl.dsp.exec_cmd("rofi-zed-recent"))

          -- Brightness
          hl.bind(mainMod .. "+I",          hl.dsp.exec_cmd("light -A 5"))
          hl.bind(mainMod .. "+SHIFT+I",    hl.dsp.exec_cmd("light -U 5"))

          -- Music
          hl.bind(mainMod .. "+B",          hl.dsp.exec_cmd("playerctl play-pause"))
          hl.bind(mainMod .. "+N",          hl.dsp.exec_cmd("playerctl next"))
          hl.bind(mainMod .. "+SHIFT+N",    hl.dsp.exec_cmd("playerctl previous"))
          hl.bind(mainMod .. "+M",          hl.dsp.exec_cmd("pactl set-sink-volume @DEFAULT_SINK@ +5%"))
          hl.bind(mainMod .. "+SHIFT+M",    hl.dsp.exec_cmd("pactl set-sink-volume @DEFAULT_SINK@ -5%"))
          -- ALT_L isn't a modifier name; just use ALT (same physical key in practice).
          hl.bind("ALT+SHIFT+M",            hl.dsp.exec_cmd([[bash -c 'for input in $(pactl list short sink-inputs | awk "{print $1}"); do pactl set-sink-input-volume "$input" -5%; done']]))
          hl.bind("ALT+M",                  hl.dsp.exec_cmd([[bash -c 'for input in $(pactl list short sink-inputs | awk "{print $1}"); do pactl set-sink-input-volume "$input" +5%; done']]))

          -- Screenshot
          hl.bind(mainMod .. "+C",          hl.dsp.exec_cmd("grimblast save area - | swappy -f -"))

          -- Layout
          hl.bind(mainMod .. "+SPACE",      hl.dsp.window.float())
          hl.bind(mainMod .. "+D",          hl.dsp.exec_cmd(menu))
          hl.bind(mainMod .. "+F",          hl.dsp.window.fullscreen({ mode = "fullscreen" }))

          -- Focus
          hl.bind(mainMod .. "+H", hl.dsp.focus({ direction = "left"  }))
          hl.bind(mainMod .. "+L", hl.dsp.focus({ direction = "right" }))
          hl.bind(mainMod .. "+K", hl.dsp.focus({ direction = "up"    }))
          hl.bind(mainMod .. "+J", hl.dsp.focus({ direction = "down"  }))

          -- Move window
          hl.bind("SUPER+SHIFT+H", hl.dsp.window.move({ direction = "left"  }))
          hl.bind("SUPER+SHIFT+L", hl.dsp.window.move({ direction = "right" }))
          hl.bind("SUPER+SHIFT+K", hl.dsp.window.move({ direction = "up"    }))
          hl.bind("SUPER+SHIFT+J", hl.dsp.window.move({ direction = "down"  }))

          -- hy3 dispatchers / i3-style tabgroups (commented; restore when hy3 plugin re-enabled)
          -- hl.bind(mainMod .. ", H",        hl.plugin.hy3.movefocus("l"))
          -- hl.bind(mainMod .. ", comma",    hl.plugin.hy3.changegroup("opposite"))
          -- hl.bind(mainMod .. " SHIFT, comma", hl.plugin.hy3.changegroup("toggletab"))


          -- Workspaces 1..9 + move-to-workspace
          -- Switch: focus dispatcher with workspace selector. Move window: window.move with workspace.
          for i = 1, 9 do
            hl.bind(mainMod .. "+" .. i,       hl.dsp.focus({ workspace = i }))
            hl.bind(mainMod .. "+SHIFT+" .. i, hl.dsp.window.move({ workspace = i }))
          end
          hl.bind(mainMod .. "+SHIFT+0", hl.dsp.window.move({ workspace = 10 }))

          -- Groups
          hl.bind(mainMod .. "+SHIFT+W", hl.dsp.group.toggle())
          -- changegroupactive f/b → group.next / group.prev
          hl.bind(mainMod .. "+right",   hl.dsp.group.next())
          hl.bind(mainMod .. "+left",    hl.dsp.group.prev())

          -- Scroll workspaces (relative): e+1 / e-1 are valid workspace selector strings
          hl.bind(mainMod .. "+mouse_down", hl.dsp.focus({ workspace = "e+1" }))
          hl.bind(mainMod .. "+mouse_up",   hl.dsp.focus({ workspace = "e-1" }))

          -- Mouse drag (was `bindm`)
          hl.bind(mainMod .. "+mouse:272", hl.dsp.window.drag(),   { drag = true })
          hl.bind(mainMod .. "+mouse:273", hl.dsp.window.resize(), { drag = true })

          --------------------------------------------------------------------
          -- Window rules
          --------------------------------------------------------------------
          -- (cosmetic red border for floating windows omitted — `floating` isn't a valid match key in the new API)
          hl.window_rule({ match = { class = ".*" },                      name = "suppress_event maximize" })
          hl.window_rule({ match = { title = "Authentication Required" }, name = "float on" })
          hl.window_rule({ match = { title = "Authentication Required" }, name = "stay_focused on" })
          hl.window_rule({ match = { class = "^(Waydroid)$" },            name = "opacity 1 1" })
          hl.window_rule({ match = { class = "^(Waydroid)$" },            name = "float on" })

          -- Noctalia HVE overlay: hyprlang `source = ...conf` has no direct Lua API.
          -- If/when noctalia ships a .lua overlay, use:
          --   dofile(os.getenv("HOME") .. "/.cache/noctalia/HVE/overlay.lua")
        '';
      };

    };
  flake.homeModules.bar-nstuff =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    {
      imports = [
        inputs.noctalia.homeModules.default
      ];
      programs.noctalia-shell = {
        enable = true;
        settings = (builtins.fromJSON (builtins.readFile ../dotconfig/noctalia/settings.json)).settings;
      };
      home.packages = [
        inputs.noctalia.packages.${pkgs.system}.default
      ];
      home.file.".config/rofi-pulse-select" = {
        source = ../dotconfig/rofi-pulse-select;
        executable = true;
      };
    };
}
