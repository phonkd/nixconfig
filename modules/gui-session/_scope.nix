# Shared `let` (as a `rec` attrset) for the Linux GUI session, minus the
# colour machinery in _matugen.nix. _home.nix imports it once and hands the
# result to every section as `scope`; each section `inherit`s only the names
# it uses.
#
# _matugen.nix never reads this file, kept one-way on purpose: `generated`,
# `groupbarMode` and `toggleGroupbarMode` live here rather than there, even
# though they look like colour machinery, to avoid a fixpoint between the
# two files.
{
  config,
  lib,
  pkgs,
  self,
  inputs,
  osConfig,
}:
rec {
  hostTags = osConfig.noughty.host.tags or [ ];
  enabled = osConfig == null || osConfig.noughty.host.is.nixosDesktop;
  hyprlandEnabled = osConfig == null || builtins.elem "hyprland" hostTags;

  cursorName = "Bibata-Modern-Classic";
  cursorSize = 24;

  wallpaperDir = "/home/phonkd/Downloads/Walls";
  wallpaperInterval = 300;
  colorMode = "dark";
  colorScheme = "scheme-tonal-spot";
  scale = "1";

  layout = "hy3";
  hy3 = layout == "hy3";

  # From nixpkgs, NOT hy3's own flake input: pkgs.hyprlandPlugins.hy3 is built
  # against pkgs.hyprland, while following hy3's README and adding a
  # `hyprland.follows` flake input would build it against this flake's
  # Hyprland master instead. Hyprland refuses to load a plugin built against
  # a different commit -- silently, so that path yields a plugin that never
  # loads.
  hy3Plugin = "${pkgs.hyprlandPlugins.hy3}/lib/libhy3.so";

  # Absolute: `exec-once` runs under the compositor, not a login shell, so
  # nothing guarantees the user profile is on PATH.
  hyprctl = "${pkgs.hyprland}/bin/hyprctl";

  # hy3 replaces the dispatchers that need to understand its tree; the stock
  # ones still exist under hy3 but act on Hyprland's own layout notion, so an
  # unswapped one misbehaves in ways that look like bugs.
  dispatch = name: if hy3 then "hy3:${name}" else name;

  # The one bind that does NOT follow `dispatch`: the dwindle side uses
  # `movewindoworgroup` (moves in/out of native tab groups too), and hy3 has
  # no `orgroup` variant since `hy3:movewindow` is already tree-aware.
  moveWindowDispatch = if hy3 then "hy3:movewindow" else "movewindoworgroup";

  # Layout-specific settings, merged into `settings` below. Deliberately a
  # plain `if`, not `lib.mkIf`: Home Manager's `settings` option is a value
  # type, not a submodule, so a nested mkIf would reach toHyprconf as a
  # literal `_type = "if"` attrset instead of being resolved.
  layoutSettings =
    if hy3 then
      {
        # Keys taken from the plugin binary's own option strings
        # (`strings libhy3.so | grep plugin:hy3`), not the README -- see the
        # `radius`/`rounding` note below.
        plugin.hy3 = {
          # Smaller than hy3's default of 10: it stacks on top of
          # general:gaps_in (8).
          group_inset = 6;

          tabs = {
            height = 20;
            padding = 6;
            # `radius`, not `rounding` -- hy3 does not follow Hyprland's own
            # `decoration:rounding` spelling.
            radius = 6;
            border_width = 2;
            render_text = true;
            text_font = "JetBrainsMono Nerd Font";
            text_height = 11;

            # `colors` deliberately absent, as in `general`/`group` below:
            # the palette is re-derived from the wallpaper via the sourced
            # matugen file, not emitted as $variables here -- an empty
            # colours file (no wallpaper readable yet) would otherwise be a
            # hard hyprlang error instead of hy3 falling back to its
            # defaults.
          };

          autotile = {
            # hy3 defaults this off (fully manual splits, strict i3). On,
            # with triggers meaning "only auto-split a node already big
            # enough to be worth splitting".
            enable = true;
            trigger_width = 800;
            trigger_height = 500;
          };
        };
      }
    else
      {
        dwindle = {
          # No `pseudotile`: Hyprland 0.55 dropped it as a config option
          # (hard error if set). Pseudotiling is still there as the
          # `pseudo` dispatcher.
          preserve_split = true;
        };

        # Tabbed / stacked groups -- AeroSpace's accordion. No plugin: hy3
        # would give the full i3 tree, but it's an ABI-coupled plugin
        # rebuilt every Hyprland bump, more than this needs.
        #
        # Colours deliberately absent here too -- re-derived from the
        # wallpaper via the sourced matugen file.
        group = {
          # Hyprland's default is ON; wrong for AeroSpace parity, since it
          # silently swallows every new window into the focused group.
          # Grouping should only happen when asked for.
          auto_group = false;

          groupbar = {
            enabled = true;
            # `stacked` deliberately NOT set here -- owned by the sourced
            # groupbarMode file so the toggle keybind can rewrite it;
            # setting it here too would win (hyprland.conf parses after its
            # own `source` lines) and pin the mode.
            height = 20;
            font_family = "JetBrainsMono Nerd Font";
            font_size = 11;
          };
        };

        binds = {
          # Makes alt-h/j/k/l cycle the group's own windows first before
          # leaving it -- off (the default), focus skips past the group's
          # other tabs entirely.
          movefocus_cycles_groupfirst = true;
        };
      };

  # Group / split bindings. alt-comma is AeroSpace's `layout accordion` under
  # both layouts; hy3 adds the rest of the i3 tree. Letters rather than
  # AeroSpace's literal punctuation (alt-slash) -- on this ch/de_nodeadkeys
  # keyboard `/` is Shift+7 (see the screenshot binds' code:-vs-keysym note).
  groupBinds =
    if hy3 then
      [
        # Fold the focused node into a tab group, and back out again.
        "${mod}, COMMA, hy3:changegroup, toggletab"
        # Reused for the other half of AeroSpace's pair since hy3 has no
        # stacked mode: flip the split axis (AeroSpace's alt-slash).
        "${mod} SHIFT, COMMA, hy3:changegroup, opposite"
        # i3's `split h` / `split v`.
        "${mod}, N, hy3:makegroup, h"
        "${mod} SHIFT, N, hy3:makegroup, v"
        # i3's `focus parent` / `focus child`.
        "${mod}, P, hy3:changefocus, raise"
        "${mod} SHIFT, P, hy3:changefocus, lower"
        # Cycle tabs within a group -- under dwindle this is
        # binds:movefocus_cycles_groupfirst on alt-h/l, but hy3 has no
        # equivalent option.
        "SUPER, Tab, hy3:focustab, r"
        "SUPER SHIFT, Tab, hy3:focustab, l"
        # Temporarily grow a node over its siblings, and back.
        "${mod}, X, hy3:expand, expand"
        "${mod} SHIFT, X, hy3:expand, base"
      ]
    else
      [
        # alt-comma = group / ungroup (AeroSpace's `layout accordion`);
        # alt-h/l walks the tabs (movefocus_cycles_groupfirst above).
        "${mod}, COMMA, togglegroup,"
        # alt-shift-comma = flip tabbed/stacked. An exec, not a dispatcher --
        # Hyprland has none for it -- see toggleGroupbarMode for why the
        # mode also has to be written to a file.
        "${mod} SHIFT, COMMA, exec, ${toggleGroupbarMode}"
      ];

  cfgHome = config.xdg.configHome;

  # Inherited from modules/kde.nix (itself AeroSpace's Option-key layout,
  # Option spelled Alt). `mod` is the window-management modifier, including
  # the workspace keys below.
  #
  # On Linux, Alt+<letter> also reaches Qt/GTK menu bars, and a compositor
  # bind wins over the focused app.
  mod = "ALT";

  # Three groups of letter keys: QWE = 1..3, ASD = 4..6, UIO = 7..9.
  # This leaves Alt+Shift+1/2/3 available for the screenshot bindings.
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
      "${mod} SHIFT, ${key}, ${dispatch "movetoworkspace"}, ${toString i}"
    ]) workspaceKeys
  );

  zen = "${inputs.zen-browser.packages.${pkgs.system}.default}/bin/zen";
  kitty = "${config.programs.kitty.package}/bin/kitty";

  # perSystem packages rather than inlined `writeShellScript`s, so both are
  # runnable by hand (`nix run .#hypr-sink-switcher`) without a session.
  sinkSwitcher = "${self.packages.${pkgs.system}.hypr-sink-switcher}/bin/hypr-sink-switcher";
  rbwMode = "${self.packages.${pkgs.system}.rofi-rbw-mode}/bin/rofi-rbw-mode";

  # Written by Monique (monitor layout + workspace assignments).
  monitorsConf = "${cfgHome}/hypr/monitors.conf";

  # Where each matugen template lands, under $XDG_CONFIG_HOME so the files
  # survive a reboot and a first login has something to read (see the
  # seeding activation script in _theming.nix).
  generated = {
    # Under stateHome, not configHome: Caelestia's utils/Paths.qml resolves
    # `state` to $XDG_STATE_HOME/caelestia.
    caelestia = "${config.xdg.stateHome}/caelestia/scheme.json";
    rofi = "${cfgHome}/rofi/colors.rasi";
    gtk3 = "${cfgHome}/gtk-3.0/colors.css";
    gtk4 = "${cfgHome}/gtk-4.0/colors.css";
  }
  // lib.optionalAttrs hyprlandEnabled {
    hypr = "${cfgHome}/hypr/colors.conf";
    hyprlock = "${cfgHome}/hypr/hyprlock-colors.conf";
  };

  # Deliberately not in `generated` above: that's matugen's output, rewritten
  # every rotation, while this is user state (groupbar orientation) that
  # only the toggle keybind writes.
  #
  # Has to be `source`d rather than set with plain `hyprctl keyword`: the
  # wallpaper timer's `hyprctl reload` (every wallpaperInterval seconds)
  # resets keyword overrides, so a keyword-only mode would revert itself
  # within minutes. Sourced, it survives -- reload re-reads it.
  groupbarMode = "${cfgHome}/hypr/groupbar-mode.conf";

  # Flip the groupbar between tabbed and stacked -- Hyprland has one knob for
  # both (`group:groupbar:stacked`), hence a toggle rather than two
  # dispatchers.
  #
  # State is read back from the file rather than `hyprctl getoption`, to
  # stay honest about what survives the next reload. Written *and* set live:
  # writing alone wouldn't show up until the next reload (up to
  # wallpaperInterval away), and setting alone wouldn't survive it.
  toggleGroupbarMode = pkgs.writeShellScript "hyprland-groupbar-mode" ''
    set -eu
    if ${pkgs.gnugrep}/bin/grep -qs 'stacked = 1' ${lib.escapeShellArg groupbarMode}; then
      next=0
    else
      next=1
    fi
    ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname ${lib.escapeShellArg groupbarMode})"
    ${pkgs.coreutils}/bin/printf 'group {\n    groupbar {\n        stacked = %s\n    }\n}\n' \
      "$next" > ${lib.escapeShellArg groupbarMode}
    ${pkgs.hyprland}/bin/hyprctl keyword group:groupbar:stacked "$next" >/dev/null
  '';
}
