# Shared colour machinery: matugen templates, GTK helpers, and rotation.
# matugen config they are named from, and the wallpaper rotation script itself.
#
# Nothing outside _theming.nix reads this file, so if the two ever want to be
# one again, concatenating them is the whole merge.
#
# See modules/hyprland.nix for why matugen owns a separate `colors.*` file per
# consumer instead of writing the Home-Manager-owned config files directly.
{
  config,
  lib,
  pkgs,
  scope,
}:
let
  inherit (scope)
    colorMode
    colorScheme
    generated
    hy3
    hyprlandEnabled
    wallpaperDir
    ;
in
rec {
  # -- matugen templates -------------------------------------------------
  #
  # Each renders one `colors.*` file, named from ~/.config/matugen/config.toml
  # by absolute path -- running `matugen image some.jpg` by hand does exactly
  # what the timer does. `hex_stripped` is the value without the leading '#',
  # which is what Hyprland's rgb()/rgba() literals want.

  # JSON, since the consumer is QML (JSON.parse); the bar reads this through
  # a FileView and rebinds, no reload needed. Caelestia's own state file,
  # rather than handing colour duty to `caelestia scheme set`, since
  # services/Colours.qml reads this path through a FileView with
  # watchChanges + onFileChanged.
  #
  # Two things are load-bearing, both from reading that loader:
  #   * values are `hex_stripped` -- the loader does `#${colour}` itself, so
  #     a leading '#' here yields '##rrggbb' and silently no colour.
  #   * keys are Material 3 roles in camelCase, NOT matugen's own
  #     snake_case, hence the mapping below. Keys the loader doesn't know
  #     are ignored, and roles omitted here keep Caelestia's defaults.
  #
  # Custom named schemes are not an officially supported upstream feature --
  # if a release renames this, the fallback is letting caelestia-cli own colours.
  caelestiaTemplate = pkgs.writeText "matugen-caelestia.json" ''
    {
      "name": "matugen",
      "flavour": "default",
      "mode": "${colorMode}",
      "colours": {
        "background":              "{{colors.background.default.hex_stripped}}",
        "onBackground":            "{{colors.on_background.default.hex_stripped}}",
        "surface":                 "{{colors.surface.default.hex_stripped}}",
        "onSurface":               "{{colors.on_surface.default.hex_stripped}}",
        "surfaceVariant":          "{{colors.surface_variant.default.hex_stripped}}",
        "onSurfaceVariant":        "{{colors.on_surface_variant.default.hex_stripped}}",
        "surfaceContainerLowest":  "{{colors.surface_container_lowest.default.hex_stripped}}",
        "surfaceContainerLow":     "{{colors.surface_container_low.default.hex_stripped}}",
        "surfaceContainer":        "{{colors.surface_container.default.hex_stripped}}",
        "surfaceContainerHigh":    "{{colors.surface_container_high.default.hex_stripped}}",
        "surfaceContainerHighest": "{{colors.surface_container_highest.default.hex_stripped}}",
        "surfaceBright":           "{{colors.surface_bright.default.hex_stripped}}",
        "surfaceDim":              "{{colors.surface_dim.default.hex_stripped}}",
        "surfaceTint":             "{{colors.surface_tint.default.hex_stripped}}",
        "inverseSurface":          "{{colors.inverse_surface.default.hex_stripped}}",
        "inverseOnSurface":        "{{colors.inverse_on_surface.default.hex_stripped}}",
        "primary":                 "{{colors.primary.default.hex_stripped}}",
        "onPrimary":               "{{colors.on_primary.default.hex_stripped}}",
        "primaryContainer":        "{{colors.primary_container.default.hex_stripped}}",
        "onPrimaryContainer":      "{{colors.on_primary_container.default.hex_stripped}}",
        "inversePrimary":          "{{colors.inverse_primary.default.hex_stripped}}",
        "secondary":               "{{colors.secondary.default.hex_stripped}}",
        "onSecondary":             "{{colors.on_secondary.default.hex_stripped}}",
        "secondaryContainer":      "{{colors.secondary_container.default.hex_stripped}}",
        "onSecondaryContainer":    "{{colors.on_secondary_container.default.hex_stripped}}",
        "tertiary":                "{{colors.tertiary.default.hex_stripped}}",
        "onTertiary":              "{{colors.on_tertiary.default.hex_stripped}}",
        "tertiaryContainer":       "{{colors.tertiary_container.default.hex_stripped}}",
        "onTertiaryContainer":     "{{colors.on_tertiary_container.default.hex_stripped}}",
        "error":                   "{{colors.error.default.hex_stripped}}",
        "onError":                 "{{colors.on_error.default.hex_stripped}}",
        "errorContainer":          "{{colors.error_container.default.hex_stripped}}",
        "onErrorContainer":        "{{colors.on_error_container.default.hex_stripped}}",
        "outline":                 "{{colors.outline.default.hex_stripped}}",
        "outlineVariant":          "{{colors.outline_variant.default.hex_stripped}}",
        "shadow":                  "{{colors.shadow.default.hex_stripped}}",
        "scrim":                   "{{colors.scrim.default.hex_stripped}}"
      }
    }
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

    # Tabbed / stacked groups. Split the same way `general` is: the
    # behavioural half lives in hyprland.conf and only the palette is
    # re-derived here, so a group's tab bar follows the wallpaper like
    # every other surface.
    #
    # The group border repeats general's gradient on purpose -- a grouped
    # window is still the focused window, and giving it a second accent
    # would read as a different kind of focus rather than the same one.
    group {
        col.border_active = $primary $tertiary 45deg
        col.border_inactive = rgba({{colors.outline_variant.default.hex_stripped}}66)

        groupbar {
            col.active = $primary
            col.inactive = rgba({{colors.surface_container.default.hex_stripped}}cc)
            text_color = $on_primary
            text_color_inactive = $on_surface
        }
    }

    ${lib.optionalString hy3 (''
      # hy3's tab bar. Same split as `group` directly above --
      # behaviour in hyprland.conf, palette here -- and the roles are
      # deliberately the same ones, so a hy3 tab and a native groupbar tab
      # are the same surface in the same scheme.
      #
      # Only emitted when the layout is actually hy3, for the same reason
      # the `dwindle` and `group` blocks in hyprland.conf are gated: a
      # dwindle host never loads hy3, so these would be dead keys in a
      # generated file. Hyprland tolerates them either way -- `plugin:` is
      # a free-form bucket, verified with --verify-config -- so this is
      # tidiness rather than a correctness fix.
      plugin {
          hy3 {
              # A nested `colors` section, not Hyprland's `col.` prefix --
              # hy3's keys are plugin:hy3:tabs:colors:*, taken from the
              # plugin binary's own option strings rather than its README.
              tabs {
                  colors {
                      active = $primary
                      active_border = $tertiary
                      active_text = $on_primary
                      # The tab holding keyboard focus inside a group that is
                      # not itself focused: dimmer than active, brighter than
                      # inactive.
                      focused = rgb({{colors.secondary.default.hex_stripped}})
                      focused_border = $tertiary
                      focused_text = $on_primary
                      inactive = rgba({{colors.surface_container.default.hex_stripped}}cc)
                      inactive_border = rgba({{colors.outline_variant.default.hex_stripped}}66)
                      inactive_text = $on_surface
                      urgent = rgb({{colors.error.default.hex_stripped}})
                      urgent_border = rgb({{colors.error.default.hex_stripped}})
                      urgent_text = rgb({{colors.on_error.default.hex_stripped}})
                  }
              }
          }
      }
    '')}

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

  # GTK. Only @define-color lines: the actual gtk.css stays HM's, and these
  # override the named colours the theme's own stylesheet already refers to.
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

    /* The names above cover the window, but libadwaita builds most of an
       app out of these -- boxed lists, preference pages, sidebars,
       dialogs. EasyEffects is almost entirely AdwPreferencesPage, so
       leaving them at the stylesheet's own values is what made it read as
       a different theme from everything around it. */
    @define-color card_bg_color {{colors.surface_container.default.hex}};
    @define-color card_fg_color {{colors.on_surface.default.hex}};
    @define-color dialog_bg_color {{colors.surface_container_high.default.hex}};
    @define-color dialog_fg_color {{colors.on_surface.default.hex}};
    @define-color sidebar_bg_color {{colors.surface_container_low.default.hex}};
    @define-color sidebar_fg_color {{colors.on_surface.default.hex}};
    @define-color sidebar_backdrop_color {{colors.surface.default.hex}};
    @define-color secondary_sidebar_bg_color {{colors.surface_container_low.default.hex}};
    @define-color secondary_sidebar_fg_color {{colors.on_surface.default.hex}};
    @define-color headerbar_backdrop_color {{colors.surface.default.hex}};
    @define-color thumbnail_bg_color {{colors.surface_container.default.hex}};
    @define-color thumbnail_fg_color {{colors.on_surface.default.hex}};
    @define-color success_color {{colors.tertiary.default.hex}};
    @define-color success_bg_color {{colors.tertiary.default.hex}};
    @define-color success_fg_color {{colors.on_tertiary.default.hex}};
    @define-color warning_bg_color {{colors.tertiary.default.hex}};
    @define-color warning_fg_color {{colors.on_tertiary.default.hex}};
    @define-color error_bg_color {{colors.error.default.hex}};
    @define-color error_fg_color {{colors.on_error.default.hex}};
  '';

  # GTK3 apps re-read their CSS when XSETTINGS changes, which is what this
  # toggle provokes -- GTK has no documented "reload your css" command.
  # GTK4/libadwaita apps ignore it and keep their colours until restarted.
  gtkNudge = pkgs.writeShellScript "gui-gtk-nudge" ''
    set -u
    gs=${pkgs.glib}/bin/gsettings
    key="org.gnome.desktop.interface gtk-theme"
    current="$($gs get $key 2>/dev/null | tr -d "'")" || exit 0
    [ -n "$current" ] || exit 0
    $gs set $key "''${current}-matugen-nudge" 2>/dev/null || exit 0
    $gs set $key "$current" 2>/dev/null || true
  '';

  # GTK config is *user-wide*, not per-session, so the two colour files are
  # treated as session state: emptied when the Hyprland session stops,
  # refilled by the first wallpaper rotation when it starts (within seconds --
  # OnActiveSec is 3). An empty file is still a valid @import target, so
  # what's left is whatever theme modules/desktop.nix declared. An unclean
  # exit (crash, power pull) leaves the files populated; recover by emptying
  # them by hand, or starting and cleanly leaving Hyprland once.
  clearGtkColors = pkgs.writeShellScript "gui-clear-gtk-colors" ''
    set -u
    for f in ${lib.escapeShellArgs [ generated.gtk3 generated.gtk4 ]}; do
      : > "$f" 2>/dev/null || true
    done
    ${gtkNudge}
  '';

  # Same session-state problem one level up, and the one that actually
  # decides whether a GTK4 app is light or dark: libadwaita ignores
  # `gtk-application-prefer-dark-theme` entirely and follows the XDG portal's
  # `org.freedesktop.appearance color-scheme`, answered from this dconf key --
  # so the @define-color lines above only ever recolour the stylesheet
  # libadwaita already picked. Get this wrong and EasyEffects draws white
  # cards on a wallpaper-dark window. Set to match `colorMode` for as long as
  # the Hyprland session runs, put back to whatever Home Manager declared
  # when it stops.
  declaredColorScheme =
    (config.dconf.settings."org/gnome/desktop/interface" or { }).color-scheme
      or "prefer-dark";
  setColorScheme =
    value:
    pkgs.writeShellScript "gui-color-scheme-${value}" ''
      set -u
      ${pkgs.dconf}/bin/dconf write /org/gnome/desktop/interface/color-scheme \
        ${lib.escapeShellArg "'${value}'"} 2>/dev/null || true
    '';

  matugenConfig = {
    config = { };
    templates = {
      caelestia = {
        input_path = "${caelestiaTemplate}";
        output_path = generated.caelestia;
        # No post_hook: the shell's own FileView watches this file.
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
    }
    // lib.optionalAttrs hyprlandEnabled {
      hyprland = {
        input_path = "${hyprTemplate}";
        output_path = generated.hypr;
        post_hook = "hyprctl reload || true";
      };
      hyprlock = {
        input_path = "${hyprlockTemplate}";
        output_path = generated.hyprlock;
      };
    };
  };

  # Set the wallpaper, then re-derive the scheme from that same image. Every
  # binary is an absolute store path: a systemd user unit inherits no PATH
  # worth relying on. hyprctl is the exception -- invoked from matugen's
  # post_hook, which runs under a shell, so it's put on PATH explicitly below.
  rotate = pkgs.writeShellScript "gui-wallpaper-rotate" ''
    set -u
    export PATH=${lib.makeBinPath ([ pkgs.glib pkgs.coreutils ] ++ lib.optional hyprlandEnabled pkgs.hyprland)}:"''${PATH:-}"

    dir=${lib.escapeShellArg (toString wallpaperDir)}
    [ -d "$dir" ] || { echo "wallpaper dir $dir does not exist" >&2; exit 0; }

    cache="''${XDG_CACHE_HOME:-$HOME/.cache}/current-wallpaper"
    previous=""
    [ -r "$cache" ] && previous="$(${pkgs.coreutils}/bin/cat "$cache")"

    # -print0/-z throughout: wallpaper filenames here contain spaces. The
    # previous wallpaper (the breadcrumb below) is excluded first, so
    # back-to-back rotations don't land on the same image twice in a row.
    list() {
      ${pkgs.findutils}/bin/find -L "$dir" -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
           -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.bmp' \) \
        -print0
    }
    image="$(list | ${pkgs.coreutils}/bin/grep -zv -Fx "$previous" \
      | ${pkgs.coreutils}/bin/shuf -z -n1 \
      | ${pkgs.coreutils}/bin/tr -d '\0')"

    # A single-image directory excludes its only candidate above; fall back
    # to the unfiltered listing rather than silently no-op'ing.
    if [ -z "$image" ]; then
      image="$(list | ${pkgs.coreutils}/bin/shuf -z -n1 | ${pkgs.coreutils}/bin/tr -d '\0')"
    fi

    if [ -z "$image" ]; then
      echo "no images under $dir" >&2
      exit 0
    fi

    # A different transition each rotation, picked here rather than left to
    # awww's own `--transition-type random` (which wouldn't randomise the
    # angle too). Circle wipes are deliberately absent -- they read as a
    # spotlight sweep rather than a wallpaper change.
    transitions=(fade left right top bottom wipe wave)
    transition="''${transitions[RANDOM % ''${#transitions[@]}]}"
    angle=$((RANDOM % 360))

    # If awww-daemon isn't up yet this call fails and the next tick retries,
    # so it's not fatal. Easing/step left at awww's defaults on purpose.
    ${pkgs.awww}/bin/awww img "$image" \
      --resize crop \
      --transition-type "$transition" \
      --transition-angle "$angle" \
      --transition-duration 1 \
      --transition-fps 60 || true

    # --source-color-index 0 makes this non-interactive: matugen 4 otherwise
    # blocks on an arrow-key pick, which in a unit is "IO error: not a terminal".
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

}
