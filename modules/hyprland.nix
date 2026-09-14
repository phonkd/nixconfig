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
#     as it changes, and pushed into the shell, the compositor, the launcher,
#     the lock screen and GTK.
#
# The shell is Caelestia (programs.caelestia below), adopted in place of a
# hand-written Quickshell bar -- see plans/caelestia-shell.md. It is a whole
# desktop rather than a bar, so it also owns notifications now; mako is off,
# and the note at services.mako explains why that is a choice rather than an
# oversight.
#
# Why every consumer repaints itself without a reload hack
# --------------------------------------------------------
# The usual way to repaint a shell from a wallpaper is to signal it, or kill
# and respawn it, after rewriting its colours. None of that happens here.
# Caelestia reads its scheme through a FileView that watches the file and
# rebinds, so QML property bindings do the repainting and there is nothing to
# restart -- which is exactly why matugen can keep owning colour generation
# instead of handing it to `caelestia scheme set`. See `caelestiaTemplate`.
#
# Hyprland has a documented reload command (`hyprctl reload`); rofi and
# hyprlock read their config at launch. Every consumer is repainted through a
# first-class feature of that consumer.
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
# GTK is where that would otherwise bite: HM generates gtk-{3,4}.0/gtk.css
# itself as soon as `gtk.gtk3.extraCss` / `gtk.gtk4.theme` are set, so those are
# paths it may claim. (As things stand `gtk.gtk4.theme` is null on these hosts
# -- `gtk.theme` in modules/desktop.nix is a different option -- so today HM
# would not fight us for it. Routing the colours through
# `gtk.gtk{3,4}.extraCss` anyway means the file stays HM's and only the colours
# are ours, which stops being luck the moment someone sets a GTK4 theme.)
#
# The second GTK problem is scope, and it is not hypothetical: gtk.css is
# *user-wide*, while everything else here is per-session. These hosts also run
# Plasma, with a deliberate Windows 7 GTK theme from modules/kde.nix. See
# `clearGtkColors` below for how the wallpaper colours are kept out of it.
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

        scale = lib.mkOption {
          type = lib.types.str;
          # 1 = 100%. Deliberately not "auto": Hyprland's auto-scaling picks a
          # fractional factor from the panel's DPI (1.25 or 1.5 on these
          # laptops), and fractional scaling on Wayland costs sharpness in every
          # XWayland app. A string rather than a float so "auto" and "1.25" are
          # both expressible without a type change.
          default = "1";
          description = ''
            Output scale factor for every monitor, as Hyprland's `monitor=`
            fourth field. "1" is 100%; "auto" hands the choice back to Hyprland.
          '';
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
        # which is a Windows 7 look and not what this session wants. These are
        # the ones the bar/rofi/kitty configs in this module actually name:
        #   * JetBrainsMono Nerd Font -- the bar's glyphs (the battery icons in
        #     shell.qml) are Nerd Font private-use codepoints, so without a
        #     patched font the bar is a row of tofu boxes.
        #   * Font Awesome -- the other glyph set these configs draw from.
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
      scale = cfg.scale or "1";

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

      # JSON rather than a stylesheet, because the consumer is QML and QML has
      # JSON.parse. The bar reads this through a FileView and rebinds -- no
      # reload, no signal, nothing to restart. Keys match the fallback palette
      # in shell.qml one for one; see the merge there, which is what stops a
      # half-written or still-empty file from blanking the bar.
      # Caelestia's colour scheme, in Caelestia's own state file. This is what
      # keeps the wallpaper pipeline ours instead of handing colour duty to
      # `caelestia scheme set`: services/Colours.qml reads this path through a
      # FileView with watchChanges + onFileChanged, so a rotation repaints the
      # shell live, exactly like every other consumer here.
      #
      # Two details are load-bearing and both come from reading that loader:
      #
      #   * values are `hex_stripped`. The loader does `#${colour}` itself, so
      #     a leading '#' here yields '##rrggbb' and silently no colour.
      #   * keys are Material 3 roles in camelCase, which is NOT what matugen
      #     calls them -- matugen is snake_case (`on_primary`,
      #     `surface_container_high`). Hence the mapping below rather than a
      #     straight dump. Keys the loader does not know are ignored, and roles
      #     omitted here keep Caelestia's built-in defaults, so a partial map
      #     degrades quietly rather than breaking the shell.
      #
      # Custom named schemes are not an officially supported upstream feature,
      # so this file is undocumented surface -- if a release renames it, the
      # fallback is letting caelestia-cli own colours.
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
        # Under stateHome, not configHome, because that is where Caelestia
        # looks: utils/Paths.qml resolves `state` to
        # $XDG_STATE_HOME/caelestia. It is also the right category -- this file
        # is generated output that changes on every wallpaper rotation, not
        # configuration.
        caelestia = "${config.xdg.stateHome}/caelestia/scheme.json";
        hypr = "${cfgHome}/hypr/colors.conf";
        hyprlock = "${cfgHome}/hypr/hyprlock-colors.conf";
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

      # GTK config is *user-wide*, not per-session, and these hosts also run
      # Plasma -- where modules/kde.nix deliberately installs a Windows 7 GTK
      # theme to match AeroThemePlasma. Left alone, the gtk.css imports below
      # would repaint that session's GTK apps in wallpaper colours too, which
      # is a visible regression nobody asked for.
      #
      # So the two GTK colour files are treated as session state: emptied when
      # the Hyprland session stops, refilled by the first wallpaper rotation
      # when it starts (within seconds -- the timer's OnActiveSec is 3). An
      # empty file is still a valid @import target, so Plasma just gets the
      # theme's own colours, exactly as before this module existed.
      #
      # The one hole is an unclean exit (a crash, or pulling the power), which
      # leaves the files populated for the next Plasma login. Recover by
      # emptying them by hand, or by starting and cleanly leaving Hyprland
      # once. Not worth more machinery than that.
      clearGtkColors = pkgs.writeShellScript "hyprland-clear-gtk-colors" ''
        set -u
        for f in ${lib.escapeShellArgs [ generated.gtk3 generated.gtk4 ]}; do
          : > "$f" 2>/dev/null || true
        done
        ${gtkNudge}
      '';

      matugenConfig = {
        config = { };
        templates = {
          caelestia = {
            input_path = "${caelestiaTemplate}";
            output_path = generated.caelestia;
            # No post_hook: the shell's own FileView watches this file.
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
      # PATH worth relying on. hyprctl is the exception -- it is invoked from
      # matugen's post_hook, which runs under a shell, so it is put on PATH
      # explicitly below. (mako used to be here for `makoctl reload`; Caelestia
      # owns notifications now and watches its own scheme file, so neither the
      # binary nor the hook is needed.)
      rotate = pkgs.writeShellScript "hyprland-wallpaper-rotate" ''
        set -u
        export PATH=${
          lib.makeBinPath [
            pkgs.hyprland
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
      # Unconditional, like every other import here: the module only declares
      # options, and all of its config hangs off `programs.caelestia.enable`
      # below, which is itself inside `lib.mkIf enabled`. A host without the
      # hyprland tag therefore gets the options and none of the shell.
      imports = [ inputs.caelestia.homeManagerModules.default ];

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

                # ",preferred,auto,<scale>" -- every output, its preferred mode,
                # auto-placed, at noughty.hyprland.scale (1 = 100%).
                monitor = ",preferred,auto,${scale}";

                # Deliberately no XCURSOR_*/HYPRCURSOR_* here. `home.pointerCursor`
                # is a *user-wide* setting, not a per-session one, and on these
                # hosts modules/kde.nix already owns it (AeroThemePlasma's
                # "aero-drop"). Home Manager's cursor module exports
                # XCURSOR_THEME/SIZE and HYPRCURSOR_THEME/SIZE as session
                # variables from whatever that is, so Hyprland inherits the same
                # cursor Plasma uses. Hardcoding a second theme here would name
                # one that is not the one actually installed for the user.
                env = [
                  "QT_QPA_PLATFORM,wayland;xcb"
                  "MOZ_ENABLE_WAYLAND,1"
                ];

                general = {
                  # Deliberately heavier than Hyprland's defaults. There are no
                  # titlebars here, so the active border -- coloured from the
                  # sourced matugen file -- is the only thing marking focus, and
                  # at 2px that accent is too thin to pick out at a glance. The
                  # gaps go up with it: a thicker frame on every window makes
                  # the old 5/12 spacing look cramped.
                  gaps_in = 8;
                  gaps_out = 16;
                  border_size = 3;
                  layout = "dwindle";
                  resize_on_border = true;
                  # col.active_border / col.inactive_border deliberately absent:
                  # they come from the sourced colours file.
                };

                decoration = {
                  # Stays comfortably above general:border_size so the corner
                  # arc still reads through the thicker border instead of being
                  # squared off by it.
                  rounding = 12;
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
                  # No `pseudotile` here: Hyprland 0.55 dropped it as a config
                  # option, and setting it is a hard error -- "config option
                  # <dwindle:pseudotile> does not exist". It is absent from the
                  # option list the compositor ships in
                  # share/hypr/stubs/hl.meta.lua, which is the authoritative
                  # list for this build. Pseudotiling itself is still there as
                  # the `pseudo` dispatcher, if you want it on a key.
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

                  # Launcher on Super+D -- the key the pre-GNOME Hyprland config
                  # in this repo's history used ($mainMod, D, exec, $menu), so
                  # it is the muscle memory that predates the KDE session.
                  # Deliberately NOT Alt+Space: that is KRunner's key on the
                  # Plasma side, and Alt is already the workspace modifier here.
                  "SUPER, D, exec, ${pkgs.rofi}/bin/rofi -show drun"
                  # Float toggle -- AeroSpace's alt-space, which KDE could not
                  # have because KRunner owns that key. Super+Space here.
                  "SUPER, SPACE, togglefloating,"
                  "SUPER, E, exec, ${pkgs.nautilus}/bin/nautilus"
                  "SUPER, L, exec, ${pkgs.hyprlock}/bin/hyprlock"
                  "SUPER SHIFT, E, exit,"
                  # Screenshots -- Spectacle's job on the Plasma side. Three
                  # targets on Super+Shift+1/2/3, screen -> window -> region,
                  # narrowing as the number goes up. `copysave` puts the PNG on
                  # the clipboard AND in $XDG_SCREENSHOTS_DIR (~/Pictures here),
                  # and `--freeze` holds the screen still while you select, so
                  # menus and hover states can be captured.
                  #
                  # If these turn out dead, it is the layout: `1`/`2`/`3` are
                  # keysyms, and on this ch/de_nodeadkeys keyboard Shift+1 emits
                  # `plus`. Hyprland normally still matches the base-level
                  # keysym for a SHIFT bind, but the layout-independent spelling
                  # is `code:10` / `code:11` / `code:12` if it does not.
                  #
                  # Super+Shift+1: the monitor the mouse is on.
                  "SUPER SHIFT, 1, exec, ${pkgs.grimblast}/bin/grimblast --freeze copysave output"
                  # Super+Shift+2: pick a window. grimblast dropped its `window`
                  # target ("now included in 'area'"), so this is `area` with
                  # slurp restricted to the window rectangles grimblast already
                  # feeds it -- `slurp -r` is "restrict selection to predefined
                  # boxes". SLURP_ARGS is grimblast's own documented hook for
                  # this, not a wrapper around it. The practical difference from
                  # plain `area` is that you cannot free-drag: every selection
                  # snaps to exactly one window.
                  "SUPER SHIFT, 2, exec, SLURP_ARGS=-r ${pkgs.grimblast}/bin/grimblast --freeze copysave area"
                  # Super+Shift+3: free region (single-clicking a window still
                  # grabs that window, which is grimblast's own behaviour).
                  "SUPER SHIFT, 3, exec, ${pkgs.grimblast}/bin/grimblast --freeze copysave area"
                  # PrtSc kept as a synonym for the region grab, for the times
                  # the obvious key is the one you reach for.
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
                ];

                # Drag to move/resize, as on the KDE side.
                bindm = [
                  "SUPER, mouse:272, movewindow"
                  "SUPER, mouse:273, resizewindow"
                ];

                # Hyprland 0.55 rule grammar: `match:<field> <value>` selectors
                # first, then `<property> <value>`. This replaced the older
                # `windowrulev2 = <property>, <field>:<value>` form -- note the
                # properties are snake_case now too (`suppress_event`, not
                # `suppressevent`; `stay_focused`, not `stayfocused`), and the
                # old spellings are a hard config error, not a deprecation
                # warning: they failed with "invalid field type suppressevent"
                # and "invalid field stayfocused: missing a value".
                #
                # Verified, not inferred. `Hyprland --verify-config -c <file>`
                # parses a config and prints the errors without starting a
                # compositor, which is the cheapest way to check this file after
                # a Hyprland bump:
                #
                #   Hyprland --verify-config -c ~/.config/hypr/hyprland.conf
                #
                # These three rules (and everything else here, including the
                # colours file `source`d above) return "config ok" on 0.55.4.
                # The grammar also matches the lua form in the compositor's own
                # shipped share/hypr/hyprland.lua, where the first of these is
                # `match = { class = ".*" }` with `suppress_event = "maximize"`,
                # and a later example sets `float = true` as a property.
                windowrule = [
                  "match:class .*, suppress_event maximize"
                  # polkit prompts (hyprpolkitagent): float them and keep focus,
                  # or the password field loses the keyboard to whatever is
                  # underneath.
                  "match:title (Authentication Required), float on"
                  "match:title (Authentication Required), stay_focused on"
                ];

                # What turns Caelestia's transparency into glass rather than a
                # washed-out slab -- appearance.transparency below sets the
                # alpha, and this is what puts something behind it. The shell
                # names its surfaces `caelestia-bar`, `caelestia-launcher`,
                # `caelestia-sidebar`, `caelestia-border` and so on, hence the
                # prefix match rather than one rule per component.
                #
                # `ignore_alpha` is the half that matters for burn-in: it tells
                # Hyprland not to blur pixels below that alpha, and the bar's
                # surface is fully transparent whenever it is hidden. Without
                # it a blurred strip would sit at the top of the screen all
                # day, which is the exact always-on artefact hiding the bar
                # exists to avoid.
                #
                # Grammar is Hyprland 0.55's, same rewrite the windowrules
                # above went through and the same hard-error-not-a-warning
                # behaviour: the older `blur, <namespace>` and
                # `ignorealpha 0.3, <namespace>` spellings fail with "invalid
                # field blur: missing a value" and "invalid field type
                # ignorealpha". Selector first, snake_case property second,
                # namespace matched as a regex. Field names come from the
                # compositor's own shipped share/hypr/stubs/hl.meta.lua
                # (HL.LayerRuleSpec).
                layerrule = [
                  "match:namespace ^caelestia-.*, blur on"
                  "match:namespace ^caelestia-.*, ignore_alpha 0.3"
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
            # Bar / shell
            # ---------------------------------------------------------------
            # Caelestia, in place of the hand-written Quickshell bar this used
            # to carry (commit 1201b63, if it ever needs to come back).
            #
            # It is a whole desktop rather than a bar, so most of what follows
            # is handing its extra halves back to the things this module
            # already runs. plans/caelestia-shell.md records what it insists on
            # owning, what it gives up, and the one thing it will not give up
            # (notifications -- see services.mako below).
            programs.caelestia = {
              enable = true;

              systemd = {
                enable = true;
                # Only ever start under Hyprland. The module's default is
                # config.wayland.systemd.target, i.e. graphical-session.target,
                # which the Plasma session reaches too -- that would drop this
                # shell on top of the Plasma panel.
                target = "hyprland-session.target";
              };

              settings = {
                bar = {
                  # The reason adopting this is worth anything at all: upstream
                  # already implements the hide-until-approached behaviour the
                  # hand-written bar existed to provide. `persistent` defaults
                  # to TRUE, so this is the line that keeps an OLED panel dark.
                  persistent = false;
                  showOnHover = true;
                };

                appearance.transparency = {
                  # Off by default upstream, which is precisely the complaint
                  # that started this ("not really good looking, not
                  # transparent"). Blur comes from the layerrules on the
                  # caelestia-* namespaces in the compositor section above.
                  enabled = true;
                  base = 0.6;
                  layers = 0.2;
                };

                # Caelestia draws its own wallpaper otherwise --
                # background.wallpaperEnabled defaults true -- which would sit
                # on top of the one swww is rotating. False drops its
                # background layer to WlrLayer.Bottom with a transparent
                # colour, so the wallpaper this module already manages shows
                # through untouched.
                background.wallpaperEnabled = false;

                general.idle = {
                  # hypridle owns idle here and hyprlock owns locking. Left
                  # alone Caelestia brings a SECOND idle stack -- its defaults
                  # are lock at 180s, dpms off at 300s, suspend-then-hibernate
                  # at 600s -- and the two would race to blank the screen. An
                  # empty timeout list is how you tell it to stay out of that.
                  timeouts = [ ];
                  lockBeforeSleep = false;
                };
              };
            };

            # ---------------------------------------------------------------
            # Notifications, launcher, lock screen, idle
            # ---------------------------------------------------------------
            # mako is OFF, and this is the one thing adopting Caelestia
            # genuinely costs.
            #
            # Caelestia force-loads its notification service on shell init --
            # modules/ServiceLoader.qml names `Notifs;` unconditionally, unlike
            # `VPN` right below it, which is gated on a config key -- and
            # services/Notifs.qml stands up a NotificationServer. So it claims
            # org.freedesktop.Notifications, and there is no setting that stops
            # it. Two daemons cannot both hold that bus name.
            #
            # Leaving both enabled would not error, which is exactly why it is
            # the wrong answer: whichever unit registers first silently wins
            # and the other's notifications vanish. A start-order race that
            # works until it doesn't is worse than a deliberate choice, so this
            # is the deliberate choice -- Caelestia draws notifications now.
            #
            # The matugen `mako` template and its `makoctl reload` post-hook
            # went with it. `git revert` of this commit brings back mako, the
            # template and the hand-written bar together.
            services.mako.enable = false;

            programs.rofi = {
              enable = true;
              package = pkgs.rofi;
              # Kept in step with the `font` in the matugen theme below, which
              # is what actually renders. 13 rather than 12 because the panel
              # runs at scale 1 (noughty.hyprland.scale) on ~162 DPI, so every
              # px is literal.
              font = "Inter 13";
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
              hyprpolkitagent
            ];

            # No `home.pointerCursor` here on purpose -- see the note next to
            # the (cursor-free) `env` list above. It is user-wide state that
            # modules/kde.nix already sets, and a second definition here would
            # either fight it or be silently ignored.
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

              /* Every widget rofi draws is styled explicitly. The first cut of
                 this theme set only window/inputbar/listview/element and looked
                 bad for three specific reasons, all of which are defaults you
                 have to opt out of rather than things you add:
                   - `element` was styled but `element-text`/`element-icon` were
                     not, so the text kept its own opaque background and sat
                     top-aligned next to the icon instead of centred on it;
                   - `element selected` is loose syntax. rofi's states are
                     two-part (<row state>.<mode>), and without the normal/
                     active/urgent variants the selection colour only applied
                     to some rows;
                   - no `mainbox`, `prompt` or `entry` rules, so the search line
                     ran into the edge of the window at rofi's default padding.
              */
              * {
                  font:             "Inter 13";
                  background-color: transparent;
                  text-color:       @foreground;
              }

              window {
                  width:            32%;
                  border:           2px;
                  border-color:     @selected;
                  border-radius:    16px;
                  background-color: @background;
                  padding:          0;
              }

              mainbox {
                  padding:  16px;
                  spacing:  14px;
                  children: [ inputbar, listview ];
              }

              inputbar {
                  background-color: @background-alt;
                  border-radius:    12px;
                  padding:          12px 14px;
                  spacing:          10px;
                  children:         [ prompt, entry ];
              }

              /* Same reasoning as the element states: rofi's default theme
                 gives prompt/entry a text-color from its own light palette, so
                 both are set explicitly rather than left to inherit. */
              prompt {
                  background-color: transparent;
                  text-color:       @selected;
                  vertical-align:   0.5;
              }

              entry {
                  background-color:  transparent;
                  text-color:        @foreground;
                  placeholder:       "Search";
                  placeholder-color: @outline;
                  vertical-align:    0.5;
              }

              listview {
                  lines:        7;
                  columns:      1;
                  spacing:      4px;
                  scrollbar:    true;
                  fixed-height: false;
              }

              scrollbar {
                  handle-color:  @selected;
                  handle-width:  4px;
                  border-radius: 4px;
              }

              element {
                  padding:       10px 12px;
                  spacing:       12px;
                  border-radius: 10px;
                  children:      [ element-icon, element-text ];
              }

              /* <row state>.<mode>. "normal" here is the mode, not the state.
                 background-color is spelled out on EVERY state, which is the
                 actual fix for rows rendering as white blocks: rofi's built-in
                 theme carries `element normal.normal { background-color:
                 var(normal-background) }`, and that palette is Solarized
                 *light* (background is rgba(253,246,227)). A plain
                 `element { background-color: transparent }` does not beat it —
                 a state rule is more specific — and `element selected` is not
                 even valid state syntax, so the old theme only ever recoloured
                 the border. Setting each state explicitly leaves nothing to
                 fall back to. */
              element normal.normal    { background-color: transparent; text-color: @foreground; }
              element alternate.normal { background-color: transparent; text-color: @foreground; }
              element normal.active    { background-color: transparent; text-color: @active; }
              element normal.urgent    { background-color: transparent; text-color: @urgent; }
              element alternate.active { background-color: transparent; text-color: @active; }
              element alternate.urgent { background-color: transparent; text-color: @urgent; }
              element selected.normal  { background-color: @selected; text-color: @on-selected; }
              element selected.active  { background-color: @active;   text-color: @background; }
              element selected.urgent  { background-color: @urgent;   text-color: @background; }

              element-icon {
                  size:           28px;
                  text-color:     inherit;
                  vertical-align: 0.5;
              }

              element-text {
                  text-color:     inherit;
                  vertical-align: 0.5;
              }

              message {
                  padding:          10px;
                  border-radius:    10px;
                  background-color: @background-alt;
              }

              textbox { text-color: @foreground; }
            '';

            # GTK: HM keeps ownership of gtk.css (it writes that file itself
            # for GTK4 whenever a theme is set), and these imports point it at
            # the colours matugen owns. `lines` merges, so this appends to
            # anything another module has put in extraCss.
            #
            # The import is unconditional because gtk.css is user-wide, but the
            # *target* is session-scoped -- see clearGtkColors above. Under
            # Plasma the imported file is empty and this is a no-op.
            gtk.gtk3.extraCss = ''
              @import url("file://${generated.gtk3}");
            '';
            gtk.gtk4.extraCss = ''
              @import url("file://${generated.gtk4}");
            '';

            # Empties the GTK colour files when the Hyprland session ends, so
            # Plasma keeps its own GTK theme. Nothing to do on start: the
            # wallpaper timer refills them moments later. RemainAfterExit is
            # what makes ExecStop run at session teardown rather than
            # immediately after ExecStart returns.
            systemd.user.services.hyprland-gtk-colors = {
              Unit = {
                Description = "Scope the wallpaper-derived GTK colours to the Hyprland session";
                PartOf = [ "hyprland-session.target" ];
              };
              Service = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${pkgs.coreutils}/bin/true";
                ExecStop = "${clearGtkColors}";
              };
              Install.WantedBy = [ "hyprland-session.target" ];
            };

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
            # this, Hyprland reports a config error for the missing `source`
            # and rofi refuses its theme. (The bar is the one consumer that
            # copes on its own -- see the fallback palette in shell.qml.)
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

                  # ...except the GTK pair, which must start out EMPTY. gtk.css
                  # is user-wide, so a seeded-with-colours file would recolour
                  # the Plasma session's GTK apps from the next login onwards,
                  # before Hyprland had ever been used. They are filled in by
                  # the first wallpaper rotation inside a Hyprland session and
                  # emptied again when it ends (see clearGtkColors).
                  ${pkgs.coreutils}/bin/truncate -s 0 \
                    ${lib.escapeShellArgs [ generated.gtk3 generated.gtk4 ]} || true
                fi
              fi
            '';
          })
        ]
      );
    };
}
