# Hyprland: a second, fully declarative session on the KDE desktops.
#
# This is *additive*. KDE is untouched -- SDDM simply grows a "Hyprland" entry
# next to "Plasma", and every systemd user unit below is bound to
# `hyprland-session.target`, which only Hyprland ever starts. Log in to Plasma
# and nothing here runs. Back it out by dropping the "hyprland" host tag in
# lib/registry.nix.
#
# Three things are mirrored from the Plasma side on purpose, because the point
# is that the two sessions feel the same:
#
#   * Keybindings, from modules/kde.nix -- which in turn mirrors
#     AeroSpace on the Mac. Alt is Option. See the table further down.
#   * A rotating wallpaper, like modules/kde.nix's Plasma slideshow.
#   * ...and the new part: the colour scheme is re-derived from each wallpaper
#     as it changes, and pushed into the bar, the compositor, notifications,
#     the launcher, the lock screen and GTK.
#
# Why Waybar is a defensible choice here rather than a compromise
# ---------------------------------------------------------------
# The usual way to repaint a bar from a wallpaper is to SIGUSR2 it, or kill and
# respawn it, after rewriting its CSS. None of that is needed. Waybar 0.15
# (our pinned nixpkgs) has, quoting its own waybar(5):
#
#   reload_style_on_change -- Option to enable reloading the css style if a
#   modification is detected on the style sheet file or any imported css files.
#
# So Waybar watches the generated `colors.css` itself and restyles in place.
# Hyprland and mako have documented reload commands (`hyprctl reload`,
# `makoctl reload`); rofi and hyprlock read their config at launch. Every
# consumer is repainted through a first-class feature of that consumer.
#
# Colour generation is matugen (Material You extraction + templating). Two of
# its behaviours are not obvious and were found by running it, not by reading:
#
#   * matugen 4 PROMPTS. Given an image it offers several candidate source
#     colours and waits for an arrow-key pick, so in a systemd unit it dies
#     with "Failed to get source color / IO error: not a terminal".
#     `--source-color-index 0` takes the top candidate and makes it silent.
#   * matugen 4 no longer sets wallpapers. The `wallpaper_tool` key older
#     guides mention is gone from the binary, hence awww (swww) below.
#
# Home Manager's files vs. matugen's files
# ----------------------------------------
# These must not overlap: an HM-managed path is a read-only symlink into the
# store, and matugen writing one would fail every rotation. So matugen only
# ever owns a separate `colors.*` file, which an HM-owned file pulls in by
# absolute path (relative imports would resolve against /nix/store).
#
# That is load-bearing for GTK4 in particular: HM writes gtk-4.0/gtk.css by
# itself whenever a GTK4 theme is set -- and one is, Nordic-darker from
# modules/desktop.nix -- so pointing matugen at that path would collide. Going
# through `gtk.gtk{3,4}.extraCss` leaves the file HM's and the colours ours.
{
  self,
  inputs,
  ...
}:
{
  # ---------------------------------------------------------------------------
  # NixOS half: the knobs, the compositor, the fonts. Self-gates on the
  # "hyprland" host tag, so it is safe to sit in modules/builder.nix's
  # alwaysImport or to be named from a registry entry's extraModules.
  # ---------------------------------------------------------------------------
  flake.nixosModules.hyprland =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    let
      enabled = noughtyLib.hostHasTag "hyprland";
    in
    {
      options.noughty.hyprland = {
        wallpaperDir = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          # Same tree the Plasma slideshow uses (noughty.kde.wallpaperDir).
          # Deliberately a separate option rather than a reference to the KDE
          # one: the two sessions should be able to disagree, and this module
          # must not break if the KDE module is renamed or reshaped.
          # Searched recursively, like Plasma's ImageWallpaper::findAll.
          default = "/home/phonkd/Downloads/Walls";
          description = ''
            Directory of wallpapers, searched recursively. Each rotation picks
            one at random and re-derives the whole colour scheme from it.
            Null disables the wallpaper/theming timer entirely.
          '';
        };

        wallpaperInterval = lib.mkOption {
          type = lib.types.ints.positive;
          # Matches noughty.kde.wallpaperInterval. As there, the reason the
          # rotation exists is OLED burn-in, not variety.
          default = 300;
          description = "Seconds between wallpaper (and colour scheme) changes.";
        };

        colorMode = lib.mkOption {
          type = lib.types.enum [
            "dark"
            "light"
          ];
          default = "dark";
          description = "Which Material You scheme matugen derives from the wallpaper.";
        };

        colorScheme = lib.mkOption {
          # matugen's own `--type` values.
          type = lib.types.str;
          default = "scheme-tonal-spot";
          description = ''
            matugen scheme algorithm (`matugen --type`). "scheme-tonal-spot" is
            matugen's default and the most muted; "scheme-vibrant" and
            "scheme-content" track the wallpaper's own colours more closely.
          '';
        };
      };

      config = lib.mkIf (enabled && config.noughty.host.is.nixosDesktop) {
        # The NixOS module is what makes Hyprland a *session*: it installs the
        # wayland-sessions desktop entry SDDM lists, wires the portals, and sets
        # the polkit/pam bits. Home Manager's module below only writes config --
        # it is given `package = null` for exactly this reason.
        programs.hyprland = {
          enable = true;
          withUWSM = true;
          xwayland.enable = true;
        };

        # Screen locker. The PAM service is what lets hyprlock actually unlock;
        # without it the password is always rejected.
        programs.hyprlock.enable = true;
        security.pam.services.hyprlock = { };

        # Plasma brings its own polkit agent; a bare Hyprland session has none,
        # and without one every pkexec prompt (ProtonVPN, mounting, ...) fails
        # silently. Started from the session, not as a system service.
        security.polkit.enable = true;

        # Fonts. The KDE session gets its own from AeroThemePlasma's Segoe set,
        # which is a Windows 7 look and not what a Waybar config wants. These
        # are the ones this module's Waybar/rofi/kitty configs actually name:
        #   * JetBrainsMono Nerd Font -- the bar's glyphs (battery, network,
        #     volume icons) are Nerd Font private-use codepoints, so without a
        #     patched font the bar is a row of tofu boxes.
        #   * Font Awesome -- the other glyph set Waybar examples use.
        #   * Inter -- proportional UI font for rofi/GTK.
        #   * Noto + Noto Emoji + CJK -- fallback coverage, so a window title in
        #     Japanese or an emoji in a notification renders at all.
        fonts.packages = with pkgs; [
          nerd-fonts.jetbrains-mono
          nerd-fonts.symbols-only
          font-awesome
          inter
          noto-fonts
          noto-fonts-cjk-sans
          noto-fonts-color-emoji
        ];

        # Same wiring as flake.nixosModules.gui: `home-manager.users.phonkd` is
        # a submodule, so a second `imports` definition merges with the one the
        # gui bundle already sets rather than replacing it.
        home-manager.users.phonkd.imports = [ self.homeModules.hyprland ];
      };
    };

  # ---------------------------------------------------------------------------
  # Home half: the actual session. Self-gates the same way the KDE home modules
  # do -- on osConfig -- so it is inert if it is ever imported on a host without
  # the tag.
  # ---------------------------------------------------------------------------
  flake.homeModules.hyprland =
    {
      config,
      lib,
      pkgs,
      osConfig ? null,
      ...
    }:
    let
      hostTags = osConfig.noughty.host.tags or [ ];
      enabled = osConfig == null || builtins.elem "hyprland" hostTags;

      cfg = osConfig.noughty.hyprland or { };
      wallpaperDir = cfg.wallpaperDir or null;
      wallpaperInterval = cfg.wallpaperInterval or 300;
      colorMode = cfg.colorMode or "dark";
      colorScheme = cfg.colorScheme or "scheme-tonal-spot";

      cfgHome = config.xdg.configHome;

      # -- Keybindings -------------------------------------------------------
      #
      # Straight from modules/kde.nix, which is itself AeroSpace's
      # Option-key layout with Option spelled Alt. `mod` is the single knob:
      # set it to SUPER and the whole set moves off Alt at once, exactly like
      # its KDE counterpart.
      #
      # The Alt-vs-menu-mnemonics caveat from the KDE module applies here too:
      # on Linux Alt+<letter> is also how Qt/GTK apps reach their menu bars,
      # and a compositor bind wins over the focused app.
      mod = "ALT";

      # AeroSpace's workspace letters in AeroSpace's own order (built-in
      # display, then external 2, then external 3) onto workspaces 1..9.
      workspaceKeys = [
        "Q"
        "W"
        "E"
        "A"
        "S"
        "D"
        "U"
        "I"
        "O"
      ];

      workspaceBinds = lib.flatten (
        lib.imap1 (i: key: [
          "${mod}, ${key}, workspace, ${toString i}"
          "${mod} SHIFT, ${key}, movetoworkspace, ${toString i}"
        ]) workspaceKeys
      );

      # Launchers. Absolute store paths, for the same reason the KDE half uses
      # them: `exec` is run by the compositor, not by a login shell, so nothing
      # guarantees the user profile is on its PATH.
      zen = "${inputs.zen-browser.packages.${pkgs.system}.default}/bin/zen";
      kitty = "${config.programs.kitty.package}/bin/kitty";
      spotify = "${pkgs.spotify}/bin/spotify";

      # -- matugen templates -------------------------------------------------
      #
      # Each renders one `colors.*` file. They live in the store and are named
      # from ~/.config/matugen/config.toml by absolute path, so the only
      # matugen file in $HOME is that config -- and running `matugen image
      # some.jpg` by hand therefore does exactly what the timer does.
      #
      # `hex_stripped` is the same value without the leading '#', which is what
      # Hyprland's rgb()/rgba() literals want.

      waybarTemplate = pkgs.writeText "matugen-waybar.css" ''
        /* Generated by matugen. Waybar watches this file itself -- see
           reload_style_on_change in the bar settings -- so editing it by hand
           restyles the bar live, and the next wallpaper rotation overwrites it. */
        @define-color background     {{colors.surface.default.hex}};
        @define-color foreground     {{colors.on_surface.default.hex}};
        @define-color surface        {{colors.surface_container.default.hex}};
        @define-color surface_high   {{colors.surface_container_high.default.hex}};
        @define-color primary        {{colors.primary.default.hex}};
        @define-color on_primary     {{colors.on_primary.default.hex}};
        @define-color secondary      {{colors.secondary.default.hex}};
        @define-color tertiary       {{colors.tertiary.default.hex}};
        @define-color outline        {{colors.outline.default.hex}};
        @define-color error          {{colors.error.default.hex}};
        @define-color on_error       {{colors.on_error.default.hex}};
      '';

      hyprTemplate = pkgs.writeText "matugen-hypr.conf" ''
        # Generated by matugen; sourced from hyprland.conf. post_hook runs
        # `hyprctl reload`, so borders repaint without restarting anything.
        $primary = rgb({{colors.primary.default.hex_stripped}})
        $on_primary = rgb({{colors.on_primary.default.hex_stripped}})
        $secondary = rgb({{colors.secondary.default.hex_stripped}})
        $tertiary = rgb({{colors.tertiary.default.hex_stripped}})
        $surface = rgb({{colors.surface.default.hex_stripped}})
        $on_surface = rgb({{colors.on_surface.default.hex_stripped}})
        $outline = rgb({{colors.outline.default.hex_stripped}})
        $shadow = rgb({{colors.shadow.default.hex_stripped}})

        general {
            col.active_border = $primary $tertiary 45deg
            col.inactive_border = rgba({{colors.outline_variant.default.hex_stripped}}66)
        }

        decoration {
            shadow {
                color = rgba({{colors.shadow.default.hex_stripped}}99)
            }
        }
      '';

      hyprlockTemplate = pkgs.writeText "matugen-hyprlock.conf" ''
        # Generated by matugen; sourced from hyprlock.conf. hyprlock reads its
        # config when it starts, so the next lock picks these up.
        $lockBackground = rgb({{colors.surface.default.hex_stripped}})
        $lockForeground = rgb({{colors.on_surface.default.hex_stripped}})
        $lockAccent = rgb({{colors.primary.default.hex_stripped}})
        $lockInner = rgb({{colors.surface_container_high.default.hex_stripped}})
        $lockError = rgb({{colors.error.default.hex_stripped}})
      '';

      # Global keys ONLY -- deliberately no `[criteria]` section. mako parses an
      # include in the enclosing context and Home Manager emits the settings
      # alphabetically, which puts `include=` in the middle of the file
      # (between `font` and `margin`). A section header in the included file
      # would therefore still be open when mako read the *parent's* remaining
      # keys, silently scoping margin/padding/width to that criteria instead of
      # to every notification. Urgency colours are set in mako's own config
      # below, where the section nesting is under Home Manager's control.
      makoTemplate = pkgs.writeText "matugen-mako" ''
        # Generated by matugen; included from mako's config. post_hook runs
        # `makoctl reload`.
        background-color={{colors.surface_container.default.hex}}ee
        text-color={{colors.on_surface.default.hex}}
        border-color={{colors.primary.default.hex}}
      '';

      rofiTemplate = pkgs.writeText "matugen-rofi.rasi" ''
        /* Generated by matugen; @import-ed from rofi's config. rofi reads this
           when it launches, which for a launcher is every time you use it. */
        * {
            background:     {{colors.surface.default.hex}};
            background-alt: {{colors.surface_container.default.hex}};
            foreground:     {{colors.on_surface.default.hex}};
            selected:       {{colors.primary.default.hex}};
            on-selected:    {{colors.on_primary.default.hex}};
            active:         {{colors.tertiary.default.hex}};
            urgent:         {{colors.error.default.hex}};
            outline:        {{colors.outline.default.hex}};
        }
      '';

      # GTK. Only @define-color lines: the actual gtk.css stays HM's (see the
      # header note about GTK4), and these override the named colours the
      # theme's own stylesheet already refers to.
      gtkTemplate = pkgs.writeText "matugen-gtk.css" ''
        /* Generated by matugen; @import-ed from the gtk.css Home Manager owns. */
        @define-color theme_bg_color {{colors.surface.default.hex}};
        @define-color theme_fg_color {{colors.on_surface.default.hex}};
        @define-color theme_base_color {{colors.surface_container_low.default.hex}};
        @define-color theme_text_color {{colors.on_surface.default.hex}};
        @define-color theme_selected_bg_color {{colors.primary.default.hex}};
        @define-color theme_selected_fg_color {{colors.on_primary.default.hex}};
        @define-color borders {{colors.outline_variant.default.hex}};
        @define-color warning_color {{colors.tertiary.default.hex}};
        @define-color error_color {{colors.error.default.hex}};

        /* libadwaita's own names, so GTK4 apps follow too. */
        @define-color window_bg_color {{colors.surface.default.hex}};
        @define-color window_fg_color {{colors.on_surface.default.hex}};
        @define-color view_bg_color {{colors.surface_container_low.default.hex}};
        @define-color view_fg_color {{colors.on_surface.default.hex}};
        @define-color headerbar_bg_color {{colors.surface_container.default.hex}};
        @define-color headerbar_fg_color {{colors.on_surface.default.hex}};
        @define-color popover_bg_color {{colors.surface_container_high.default.hex}};
        @define-color popover_fg_color {{colors.on_surface.default.hex}};
        @define-color accent_bg_color {{colors.primary.default.hex}};
        @define-color accent_fg_color {{colors.on_primary.default.hex}};
        @define-color accent_color {{colors.primary.default.hex}};
        @define-color destructive_bg_color {{colors.error.default.hex}};
        @define-color destructive_fg_color {{colors.on_error.default.hex}};
      '';

      # Where each template lands. Everything under $XDG_CONFIG_HOME so the
      # files survive a reboot and a first login has something to read even
      # before the first rotation (see the seeding activation script below).
      generated = {
        waybar = "${cfgHome}/waybar/colors.css";
        hypr = "${cfgHome}/hypr/colors.conf";
        hyprlock = "${cfgHome}/hypr/hyprlock-colors.conf";
        mako = "${cfgHome}/mako/colors";
        rofi = "${cfgHome}/rofi/colors.rasi";
        gtk3 = "${cfgHome}/gtk-3.0/colors.css";
        gtk4 = "${cfgHome}/gtk-4.0/colors.css";
      };

      # GTK3 apps re-read their CSS when XSETTINGS changes, which is what this
      # toggle provokes. It is the one repaint here that is a nudge rather than
      # a documented reload -- GTK has no "reload your css" command. GTK4 /
      # libadwaita apps ignore it and keep their colours until restarted; new
      # windows of either toolkit are always correct.
      gtkNudge = pkgs.writeShellScript "hyprland-gtk-nudge" ''
        set -u
        gs=${pkgs.glib}/bin/gsettings
        key="org.gnome.desktop.interface gtk-theme"
        current="$($gs get $key 2>/dev/null | tr -d "'")" || exit 0
        [ -n "$current" ] || exit 0
        $gs set $key "''${current}-matugen-nudge" 2>/dev/null || exit 0
        $gs set $key "$current" 2>/dev/null || true
      '';

      matugenConfig = {
        config = { };
        templates = {
          waybar = {
            input_path = "${waybarTemplate}";
            output_path = generated.waybar;
            # No post_hook: Waybar's reload_style_on_change watches this file.
          };
          hyprland = {
            input_path = "${hyprTemplate}";
            output_path = generated.hypr;
            post_hook = "hyprctl reload || true";
          };
          hyprlock = {
            input_path = "${hyprlockTemplate}";
            output_path = generated.hyprlock;
          };
          mako = {
            input_path = "${makoTemplate}";
            output_path = generated.mako;
            post_hook = "makoctl reload || true";
          };
          rofi = {
            input_path = "${rofiTemplate}";
            output_path = generated.rofi;
          };
          gtk3 = {
            input_path = "${gtkTemplate}";
            output_path = generated.gtk3;
          };
          gtk4 = {
            input_path = "${gtkTemplate}";
            output_path = generated.gtk4;
            post_hook = "${gtkNudge}";
          };
        };
      };

      # -- The rotation itself -----------------------------------------------
      #
      # Set the wallpaper, then re-derive the scheme from that same image.
      # Every binary is an absolute store path: a systemd user unit inherits no
      # PATH worth relying on. hyprctl/makoctl are the exception -- they are
      # invoked from matugen's post_hooks, which run under a shell, so they are
      # put on PATH explicitly below.
      rotate = pkgs.writeShellScript "hyprland-wallpaper-rotate" ''
        set -u
        export PATH=${
          lib.makeBinPath [
            pkgs.hyprland
            pkgs.mako
            pkgs.glib
            pkgs.coreutils
          ]
        }:"''${PATH:-}"

        dir=${lib.escapeShellArg (toString wallpaperDir)}
        [ -d "$dir" ] || { echo "wallpaper dir $dir does not exist" >&2; exit 0; }

        # -print0/-z throughout: wallpaper filenames here contain spaces.
        # `shuf -n1` over the whole list rather than picking an index, so the
        # set can change under us without an off-by-one.
        image="$(${pkgs.findutils}/bin/find -L "$dir" -type f \
            \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
               -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.bmp' \) \
            -print0 \
          | ${pkgs.coreutils}/bin/shuf -z -n1 \
          | ${pkgs.coreutils}/bin/tr -d '\0')"

        if [ -z "$image" ]; then
          echo "no images under $dir" >&2
          exit 0
        fi

        # swww was renamed to awww upstream, and nixpkgs keeps `swww` only as
        # a deprecation alias, so the real name is used throughout. The daemon
        # is a separate unit; if it is not up yet this call fails and the next
        # tick retries, so it is not fatal.
        ${pkgs.awww}/bin/awww img "$image" \
          --resize crop \
          --transition-type fade \
          --transition-duration 1.5 \
          --transition-fps 60 || true

        # --source-color-index 0 is what makes this non-interactive: matugen 4
        # otherwise offers a list of candidate source colours and blocks on an
        # arrow-key pick, which in a unit shows up as "IO error: not a terminal".
        # </dev/null belt-and-braces for the same reason.
        ${pkgs.matugen}/bin/matugen \
          --quiet \
          --source-color-index 0 \
          --type ${lib.escapeShellArg colorScheme} \
          --mode ${lib.escapeShellArg colorMode} \
          image "$image" < /dev/null

        # Leave a breadcrumb so `awww restore` and anything else that wants to
        # know the current wallpaper can find it.
        ${pkgs.coreutils}/bin/printf '%s\n' "$image" > "''${XDG_CACHE_HOME:-$HOME/.cache}/current-wallpaper"
      '';

      themingEnabled = wallpaperDir != null;
    in
    {
      config = lib.mkIf enabled (
        lib.mkMerge [
          {
            # ---------------------------------------------------------------
            # Compositor
            # ---------------------------------------------------------------
            wayland.windowManager.hyprland = {
              enable = true;
              # The NixOS module installs Hyprland and the portal; HM only
              # writes the config. This is upstream's documented pairing.
              package = null;
              portalPackage = null;
              systemd.enable = true;
              xwayland.enable = true;

              # hyprlang, not the newer lua config type. Two reasons: every
              # piece of Hyprland documentation is hyprlang, and matugen's
              # generated colour file is hyprlang that gets `source`d -- the
              # lua backend would need it wrapped. `settings` below is format
              # agnostic, so this is one line to change later.
              configType = "hyprlang";

              settings = {
                # Colours live in a file matugen rewrites on every wallpaper
                # change; `source` is absolute because this config itself is a
                # store path, so a relative path would resolve into /nix/store.
                # The file is seeded at activation, so it always exists.
                source = [ generated.hypr ];

                monitor = ",preferred,auto,auto";

                # Cursor: the Bibata theme the old Hyprland config used.
                env = [
                  "XCURSOR_THEME,Bibata-Modern-Amber"
                  "XCURSOR_SIZE,24"
                  "HYPRCURSOR_THEME,Bibata-Modern-Amber"
                  "HYPRCURSOR_SIZE,24"
                  "QT_QPA_PLATFORM,wayland;xcb"
                  "MOZ_ENABLE_WAYLAND,1"
                ];

                general = {
                  gaps_in = 5;
                  gaps_out = 12;
                  border_size = 2;
                  layout = "dwindle";
                  resize_on_border = true;
                  # col.active_border / col.inactive_border deliberately absent:
                  # they come from the sourced colours file.
                };

                decoration = {
                  rounding = 10;
                  blur = {
                    enabled = true;
                    size = 5;
                    passes = 2;
                    new_optimizations = true;
                  };
                };

                animations = {
                  enabled = true;
                  bezier = [ "wind, 0.05, 0.9, 0.1, 1.05" ];
                  animation = [
                    "windows, 1, 5, wind"
                    "windowsOut, 1, 5, default, popin 80%"
                    "border, 1, 10, default"
                    "fade, 1, 5, default"
                    "workspaces, 1, 5, default"
                  ];
                };

                dwindle = {
                  pseudotile = true;
                  preserve_split = true;
                };

                input = {
                  # Swiss German, no dead keys -- carried over from the old
                  # Hyprland config in git history. Plasma gets this from its
                  # own keyboard settings, which is why there is no equivalent
                  # line in the KDE modules.
                  kb_layout = "ch";
                  kb_variant = "de_nodeadkeys";
                  follow_mouse = 1;
                  touchpad = {
                    natural_scroll = false;
                    disable_while_typing = false;
                  };
                };

                misc = {
                  disable_hyprland_logo = true;
                  disable_splash_rendering = true;
                  vrr = 1;
                  # Nothing here should paint a wallpaper -- swww owns it.
                  force_default_wallpaper = 0;
                };

                # -------------------------------------------------------------
                # Keybindings -- the KDE set, verbatim where KDE has an
                # equivalent action. See modules/kde.nix for the
                # reasoning behind each choice; only the differences are noted
                # here.
                # -------------------------------------------------------------
                bind = [
                  # alt-h/j/k/l = focus left/down/up/right
                  "${mod}, H, movefocus, l"
                  "${mod}, J, movefocus, d"
                  "${mod}, K, movefocus, u"
                  "${mod}, L, movefocus, r"

                  # alt-shift-h/j/k/l = move the window. The KDE half had to
                  # spell this as quick-tile, because KWin has no tiling-WM
                  # "move node". Hyprland does, so this is `movewindow` --
                  # which is what the AeroSpace original actually does.
                  "${mod} SHIFT, H, movewindow, l"
                  "${mod} SHIFT, J, movewindow, d"
                  "${mod} SHIFT, K, movewindow, u"
                  "${mod} SHIFT, L, movewindow, r"

                  # alt-f = fullscreen
                  "${mod}, F, fullscreen, 0"

                  # Meta+Q = close window. Deliberately not on `mod`, exactly
                  # as in the KDE half: Alt+Q is a workspace key below.
                  "SUPER, Q, killactive,"

                  # Launchers: alt-b/v/m, same three apps as KDE and AeroSpace.
                  "${mod}, B, exec, ${zen}"
                  "${mod}, V, exec, ${kitty}"
                  "${mod}, M, exec, ${spotify}"

                  # --- Below here: things Plasma provides for free and a bare
                  # --- compositor does not, so they have no counterpart in
                  # --- modules/kde.nix.

                  # Launcher. Alt+Space is KRunner's key on the KDE side (the
                  # KDE module calls out leaving it alone), so the same finger
                  # gets the same kind of thing here.
                  "${mod}, SPACE, exec, ${pkgs.rofi}/bin/rofi -show drun"
                  # Float toggle -- AeroSpace's alt-space, which KDE could not
                  # have because KRunner owns that key. Super+Space here.
                  "SUPER, SPACE, togglefloating,"
                  "SUPER, E, exec, ${pkgs.nautilus}/bin/nautilus"
                  "SUPER, L, exec, ${pkgs.hyprlock}/bin/hyprlock"
                  "SUPER SHIFT, E, exit,"
                  # Region screenshot to the clipboard, then the editor --
                  # Spectacle's job on the Plasma side.
                  ", Print, exec, ${pkgs.grimblast}/bin/grimblast --freeze copysave area"
                  "SUPER, C, exec, ${pkgs.hyprpicker}/bin/hyprpicker -a"
                  "SUPER, V, exec, ${pkgs.cliphist}/bin/cliphist list | ${pkgs.rofi}/bin/rofi -dmenu | ${pkgs.cliphist}/bin/cliphist decode | ${pkgs.wl-clipboard}/bin/wl-copy"
                  # Force a wallpaper + colour scheme change now, instead of
                  # waiting out the timer.
                  "SUPER, W, exec, ${pkgs.systemd}/bin/systemctl --user start hyprland-wallpaper.service"
                ]
                ++ workspaceBinds;

                # Media and brightness keys. `bindel` repeats while held and
                # works on the lock screen.
                bindel = [
                  ", XF86AudioRaiseVolume, exec, ${pkgs.wireplumber}/bin/wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%+"
                  ", XF86AudioLowerVolume, exec, ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
                  ", XF86AudioMute, exec, ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
                  ", XF86AudioMicMute, exec, ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
                  ", XF86MonBrightnessUp, exec, ${pkgs.brightnessctl}/bin/brightnessctl set 5%+"
                  ", XF86MonBrightnessDown, exec, ${pkgs.brightnessctl}/bin/brightnessctl set 5%-"
                ];

                bindl = [
                  ", XF86AudioPlay, exec, ${pkgs.playerctl}/bin/playerctl play-pause"
                  ", XF86AudioNext, exec, ${pkgs.playerctl}/bin/playerctl next"
                  ", XF86AudioPrev, exec, ${pkgs.playerctl}/bin/playerctl previous"
                ];

                # Drag to move/resize, as on the KDE side.
                bindm = [
                  "SUPER, mouse:272, movewindow"
                  "SUPER, mouse:273, resizewindow"
                ];

                windowrule = [
                  "suppressevent maximize, class:.*"
                  "float, title:^(Authentication Required)$"
                  "stayfocused, title:^(Authentication Required)$"
                ];

                exec-once = [
                  # Clipboard history, feeding the Super+V picker above.
                  "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.cliphist}/bin/cliphist store"
                  "${pkgs.wl-clipboard}/bin/wl-paste --type image --watch ${pkgs.cliphist}/bin/cliphist store"
                  # Polkit agent -- see the NixOS half.
                  "${pkgs.hyprpolkitagent}/bin/hyprpolkitagent"
                ];
              };
            };

            # ---------------------------------------------------------------
            # Bar
            # ---------------------------------------------------------------
            programs.waybar = {
              enable = true;
              systemd = {
                enable = true;
                # Only ever start under Hyprland. The default here is
                # graphical-session.target, which Plasma reaches too -- that
                # would put a Waybar on top of the Plasma panel.
                targets = [ "hyprland-session.target" ];
              };

              settings.main = {
                layer = "top";
                position = "top";
                height = 34;
                spacing = 4;

                modules-left = [
                  "hyprland/workspaces"
                  "hyprland/submap"
                ];
                modules-center = [ "hyprland/window" ];
                modules-right = [
                  "tray"
                  "idle_inhibitor"
                  "pulseaudio"
                  "backlight"
                  "network"
                  "cpu"
                  "memory"
                  "battery"
                  "clock"
                ];

                # This is the nice bit of parity: the pills are labelled with
                # the same letters the Alt bindings use, so the mapping from
                # Alt+D to "the 6th workspace" is on screen rather than
                # memorised. Keys are workspace ids as strings.
                "hyprland/workspaces" = {
                  format = "{icon}";
                  on-click = "activate";
                  format-icons = lib.listToAttrs (
                    lib.imap1 (i: key: lib.nameValuePair (toString i) key) workspaceKeys
                  );
                  persistent-workspaces = lib.listToAttrs (
                    lib.imap1 (i: _: lib.nameValuePair (toString i) [ ]) workspaceKeys
                  );
                };

                "hyprland/window" = {
                  format = "{title}";
                  max-length = 70;
                  separate-outputs = true;
                };

                clock = {
                  format = "{:%H:%M}";
                  format-alt = "{:%a %d %b  %H:%M}";
                  tooltip-format = "<tt><small>{calendar}</small></tt>";
                };

                cpu = {
                  format = "󰻠 {usage}%";
                  interval = 5;
                };

                memory = {
                  format = "󰍛 {percentage}%";
                  interval = 5;
                };

                battery = {
                  states = {
                    warning = 30;
                    critical = 15;
                  };
                  format = "{icon} {capacity}%";
                  format-charging = "󰂄 {capacity}%";
                  format-plugged = "󰚥 {capacity}%";
                  format-icons = [
                    "󰁺"
                    "󰁽"
                    "󰁿"
                    "󰂁"
                    "󰁹"
                  ];
                };

                backlight = {
                  format = "󰃠 {percent}%";
                  on-scroll-up = "${pkgs.brightnessctl}/bin/brightnessctl set 5%+";
                  on-scroll-down = "${pkgs.brightnessctl}/bin/brightnessctl set 5%-";
                };

                network = {
                  format-wifi = "󰖩 {essid}";
                  format-ethernet = "󰈀 {ipaddr}";
                  format-disconnected = "󰖪";
                  tooltip-format = "{ifname}  {ipaddr}/{cidr}";
                };

                pulseaudio = {
                  format = "{icon} {volume}%";
                  format-muted = "󰝟";
                  format-icons.default = [
                    "󰕿"
                    "󰖀"
                    "󰕾"
                  ];
                  on-click = "${pkgs.pavucontrol}/bin/pavucontrol";
                };

                idle_inhibitor = {
                  format = "{icon}";
                  format-icons = {
                    activated = "󰅶";
                    deactivated = "󰛊";
                  };
                };

                tray.spacing = 8;

                # THE line that makes wallpaper-driven colours work without a
                # reload hack: Waybar watches style.css and everything it
                # imports, and restyles itself when one changes. matugen
                # rewrites the imported colors.css; Waybar does the rest.
                reload_style_on_change = true;
              };

              # Named colours only -- every literal comes from the imported
              # file. The import is absolute and file://-schemed because this
              # stylesheet is a /nix/store path, so a bare relative import
              # would look for colors.css next to it in the store.
              style = ''
                @import url("file://${generated.waybar}");

                * {
                  font-family: "JetBrainsMono Nerd Font", "Font Awesome 6 Free", sans-serif;
                  font-size: 13px;
                  border: none;
                  border-radius: 0;
                  min-height: 0;
                }

                window#waybar {
                  background: transparent;
                  color: @foreground;
                }

                .modules-left,
                .modules-center,
                .modules-right {
                  background-color: @background;
                  border: 1px solid @outline;
                  border-radius: 10px;
                  margin: 4px 0;
                  padding: 0 6px;
                }

                #workspaces button {
                  color: @foreground;
                  padding: 0 8px;
                  margin: 3px 2px;
                  border-radius: 7px;
                  background-color: transparent;
                  transition: background-color 150ms ease, color 150ms ease;
                }

                #workspaces button.active {
                  background-color: @primary;
                  color: @on_primary;
                }

                #workspaces button.urgent {
                  background-color: @error;
                  color: @on_error;
                }

                #workspaces button:hover {
                  background-color: @surface_high;
                  color: @foreground;
                }

                #window,
                #clock,
                #cpu,
                #memory,
                #battery,
                #backlight,
                #network,
                #pulseaudio,
                #idle_inhibitor,
                #tray,
                #submap {
                  padding: 0 10px;
                  color: @foreground;
                }

                #clock {
                  color: @primary;
                  font-weight: bold;
                }

                #battery.warning {
                  color: @tertiary;
                }

                #battery.critical {
                  color: @error;
                }

                #network.disconnected,
                #pulseaudio.muted {
                  color: @outline;
                }

                tooltip {
                  background-color: @surface;
                  color: @foreground;
                  border: 1px solid @outline;
                  border-radius: 8px;
                }
              '';
            };

            # ---------------------------------------------------------------
            # Notifications, launcher, lock screen, idle
            # ---------------------------------------------------------------
            services.mako = {
              enable = true;
              settings = {
                # mako's own include directive; matugen owns the target and
                # `makoctl reload` re-reads the lot.
                include = generated.mako;
                border-radius = 10;
                border-size = 2;
                default-timeout = 6000;
                font = "Inter 11";
                margin = "12";
                padding = "12";
                width = 380;
              };
            };

            programs.rofi = {
              enable = true;
              package = pkgs.rofi;
              font = "Inter 12";
              extraConfig = {
                modi = "drun,run,window";
                show-icons = true;
                drun-display-format = "{name}";
              };
              # A theme *name*, not a path: HM turns this into `@theme
              # "matugen"` in config.rasi, which rofi resolves through its
              # normal theme search path -- and that includes
              # $XDG_DATA_HOME/rofi/themes, where the file below lands. Passing
              # a string also stops HM from trying to generate a theme file of
              # its own, so there is exactly one writer.
              theme = "matugen";
            };

            programs.hyprlock = {
              enable = true;
              settings = {
                source = [ generated.hyprlock ];
                general = {
                  hide_cursor = true;
                };
                background = [
                  {
                    # The live wallpaper, so the lock screen matches the
                    # desktop it locked.
                    path = "screenshot";
                    blur_passes = 3;
                    blur_size = 8;
                  }
                ];
                input-field = [
                  {
                    size = "300, 50";
                    outline_thickness = 2;
                    dots_center = true;
                    outer_color = "$lockAccent";
                    inner_color = "$lockInner";
                    font_color = "$lockForeground";
                    fail_color = "$lockError";
                    placeholder_text = "";
                    position = "0, -40";
                    halign = "center";
                    valign = "center";
                  }
                ];
                label = [
                  {
                    text = "$TIME";
                    font_size = 64;
                    font_family = "Inter";
                    color = "$lockForeground";
                    position = "0, 120";
                    halign = "center";
                    valign = "center";
                  }
                ];
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
                  {
                    timeout = 300;
                    on-timeout = "${pkgs.brightnessctl}/bin/brightnessctl -s set 10%";
                    on-resume = "${pkgs.brightnessctl}/bin/brightnessctl -r";
                  }
                  {
                    timeout = 600;
                    on-timeout = "${pkgs.systemd}/bin/loginctl lock-session";
                  }
                  {
                    timeout = 900;
                    on-timeout = "${pkgs.hyprland}/bin/hyprctl dispatch dpms off";
                    on-resume = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
                  }
                ];
              };
            };

            home.packages = with pkgs; [
              # Tools the bindings above reach for, plus the ones you want in
              # $PATH when you are poking at a Wayland session by hand.
              rofi
              grimblast
              slurp
              swappy
              hyprpicker
              cliphist
              wl-clipboard
              brightnessctl
              pavucontrol
              playerctl
              awww
              matugen
              nwg-look
              wlogout
              bibata-cursors
              hyprpolkitagent
            ];

            # Cursor theme, matching the env vars set in the Hyprland config.
            home.pointerCursor = lib.mkDefault {
              package = pkgs.bibata-cursors;
              name = "Bibata-Modern-Amber";
              size = 24;
              gtk.enable = true;
              x11.enable = true;
            };
          }

          # -------------------------------------------------------------------
          # Wallpaper rotation + wallpaper-derived colours. Split out so that
          # setting noughty.hyprland.wallpaperDir = null leaves a perfectly
          # usable static-colour session.
          # -------------------------------------------------------------------
          (lib.mkIf themingEnabled {
            xdg.configFile."matugen/config.toml".source =
              (pkgs.formats.toml { }).generate "matugen-config.toml" matugenConfig;

            # The "matugen" theme named above. Named colours only -- every
            # literal comes from the file matugen rewrites, imported by
            # absolute path because this theme is a store symlink and a
            # relative import would resolve next to it in /nix/store.
            # $XDG_DATA_HOME/rofi/themes is one of rofi's own theme
            # directories, which is how `@theme "matugen"` finds it.
            xdg.dataFile."rofi/themes/matugen.rasi".text = ''
              @import "${generated.rofi}"

              window {
                  width: 640px;
                  border: 2px;
                  border-color: @selected;
                  border-radius: 12px;
                  background-color: @background;
              }
              inputbar {
                  padding: 10px;
                  background-color: @background-alt;
                  text-color: @foreground;
              }
              listview { lines: 10; background-color: @background; }
              element { padding: 8px; border-radius: 8px; background-color: transparent; text-color: @foreground; }
              element selected { background-color: @selected; text-color: @on-selected; }
              element-icon { size: 24px; }
            '';

            # GTK: HM keeps ownership of gtk.css (it writes that file itself
            # for GTK4 whenever a theme is set), and these imports point it at
            # the colours matugen owns. `lines` merges, so this appends to
            # anything another module has put in extraCss.
            gtk.gtk3.extraCss = ''
              @import url("file://${generated.gtk3}");
            '';
            gtk.gtk4.extraCss = ''
              @import url("file://${generated.gtk4}");
            '';

            # The wallpaper daemon. Bound to hyprland-session.target, so it
            # never comes up under Plasma.
            systemd.user.services.awww-daemon = {
              Unit = {
                Description = "awww (swww) wallpaper daemon";
                PartOf = [ "hyprland-session.target" ];
                After = [ "hyprland-session.target" ];
              };
              Service = {
                # Not oneshot: this is the daemon that holds the layer-shell
                # surface. `--no-cache` because the wallpaper is chosen fresh
                # on every rotation and a restored cached one would briefly
                # contradict the colours on screen.
                ExecStart = "${pkgs.awww}/bin/awww-daemon --no-cache";
                Restart = "on-failure";
                RestartSec = 2;
              };
              Install.WantedBy = [ "hyprland-session.target" ];
            };

            systemd.user.services.hyprland-wallpaper = {
              Unit = {
                Description = "Pick a wallpaper and re-derive the colour scheme from it";
                PartOf = [ "hyprland-session.target" ];
                After = [ "awww-daemon.service" ];
                Requires = [ "awww-daemon.service" ];
              };
              Service = {
                Type = "oneshot";
                ExecStart = "${rotate}";
              };
            };

            systemd.user.timers.hyprland-wallpaper = {
              Unit.Description = "Rotate the wallpaper (and the colour scheme with it)";
              Timer = {
                # A couple of seconds after the session comes up, then every
                # interval. AccuracySec keeps it from being coalesced into a
                # ragged schedule; Persistent is deliberately absent, since a
                # missed rotation while logged out is not worth catching up.
                OnActiveSec = 3;
                OnUnitActiveSec = wallpaperInterval;
                AccuracySec = "5s";
              };
              Install.WantedBy = [ "hyprland-session.target" ];
            };

            # Seed every generated file, so the very first Hyprland login --
            # before the timer has ever fired -- finds them present. Without
            # this, Hyprland reports a config error for the missing `source`,
            # Waybar comes up unstyled and rofi refuses its theme.
            #
            # Only ever creates what is missing: a real rotation's output must
            # never be clobbered by an activation. Uses matugen itself rather
            # than a checked-in palette, so the seed is a genuine scheme --
            # and falls back to writing empty files if no wallpaper is
            # readable yet, which is enough for every consumer to parse.
            home.activation.hyprlandColors = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
              if [ -z "''${DRY_RUN:-}" ]; then
                seeded=0
                for f in ${lib.escapeShellArgs (lib.attrValues generated)}; do
                  if [ ! -e "$f" ]; then
                    seeded=1
                  fi
                done

                if [ "$seeded" = 1 ]; then
                  verboseEcho "Seeding Hyprland colour files from a wallpaper"
                  for f in ${lib.escapeShellArgs (lib.attrValues generated)}; do
                    $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$f")"
                  done

                  seed="$(${pkgs.findutils}/bin/find -L ${lib.escapeShellArg (toString wallpaperDir)} \
                      -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
                                 -o -iname '*.webp' \) -print0 2>/dev/null \
                    | ${pkgs.coreutils}/bin/head -z -n1 \
                    | ${pkgs.coreutils}/bin/tr -d '\0')"

                  if [ -n "$seed" ]; then
                    # post_hooks would try to reload a compositor that is not
                    # running during activation, so they are tolerated failing;
                    # matugen itself still writes every template.
                    ${pkgs.matugen}/bin/matugen --quiet --source-color-index 0 \
                      --type ${lib.escapeShellArg colorScheme} \
                      --mode ${lib.escapeShellArg colorMode} \
                      image "$seed" < /dev/null || true
                  fi

                  # Whatever matugen did or did not manage, guarantee the files
                  # exist -- an absent one is a startup error for its consumer,
                  # an empty one is not.
                  for f in ${lib.escapeShellArgs (lib.attrValues generated)}; do
                    [ -e "$f" ] || ${pkgs.coreutils}/bin/touch "$f"
                  done
                fi
              fi
            '';
          })
        ]
      );
    };
}
