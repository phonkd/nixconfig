# The compositor itself: outputs, environment, look, input, window and layer
# rules, and what the session starts. Keybindings live in _keybinds.nix.
#
# `settings` is assembled from three pieces; `layoutSettings` must come last
# (the `//`s are load-bearing in that direction) since it's the hy3-vs-dwindle
# switch and gets the final word over anything the base config guessed at.
# `keybinds` shares no key with either.
{
  config,
  lib,
  pkgs,
  scope,
}:
let
  keybinds = import ./_keybinds.nix { inherit config lib pkgs scope; };

  inherit (scope)
    cursorName
    cursorSize
    generated
    groupbarMode
    hy3
    hy3Plugin
    hyprctl
    layout
    layoutSettings
    monitorsConf
    scale
    workspacesConf
    ;
in
{
  wayland.windowManager.hyprland = {
    enable = true;
    # The NixOS module installs Hyprland and the portal; HM only writes the
    # config.
    package = null;
    portalPackage = null;
    systemd.enable = true;
    xwayland.enable = true;

    # hyprlang, not the newer lua type: every doc is hyprlang, and matugen's
    # generated colour file is hyprlang that gets `source`d.
    configType = "hyprlang";

    # nwg-displays' output. NOT `settings.source`: HM hoists `source` lines
    # to the top of the generated file via toHyprconf's importantPrefixes,
    # which would put the generic `monitor=,preferred,auto,...` rule further
    # down *after* nwg-displays' per-output lines. `extraConfig` is
    # concatenated last, so the GUI's output wins over the fallback.
    #
    # workspaces.conf is sourced too (the same dialog assigns workspaces to
    # outputs); nothing else here emits `workspace=` rules. Both are seeded
    # empty at activation (home.activation.hyprlandDisplays) since Hyprland
    # treats a `source` of a missing file as a config error, and nwg-displays
    # only creates them once actually run.
    extraConfig = ''
      source = ${monitorsConf}
      source = ${workspacesConf}
    '';

    settings = {
      # Colours: matugen rewrites this on every wallpaper change; `source`
      # is absolute since this config is itself a store path. Groupbar mode:
      # user state the toggle keybind writes, sourced for the same reason --
      # `hyprctl reload` discards anything set with `hyprctl keyword`. Both
      # seeded at activation, so never a missing-source error.
      source = [
        generated.hypr
      ]
      # Native-groupbar state only -- hy3 draws its own tabs and has no
      # stacked mode.
      ++ lib.optional (!hy3) groupbarMode;

      # ",preferred,auto,<scale>" -- every output, preferred mode,
      # auto-placed, at noughty.hyprland.scale (1 = 100%).
      monitor = ",preferred,auto,${scale}";

      # Spelled out rather than left to the environment: session variables
      # reach Hyprland only via the login shell greetd starts it from, and
      # this makes the pointer independent of that path. Still no
      # HYPRCURSOR_* -- bibata ships XCursor only, and pointing hyprcursor at
      # a theme it can't find is a warning and a fallback, not an upgrade.
      env = [
        "QT_QPA_PLATFORM,wayland;xcb"
        "MOZ_ENABLE_WAYLAND,1"
        "XCURSOR_THEME,${cursorName}"
        "XCURSOR_SIZE,${toString cursorSize}"
      ];

      general = {
        # Heavier than Hyprland's defaults: no titlebars here, so the active
        # border (coloured from the sourced matugen file) is the only focus
        # marker, and 2px is too thin to pick out at a glance.
        gaps_in = 8;
        gaps_out = 16;
        border_size = 3;
        # Naming a layout the compositor has not registered yet is NOT a
        # config error (verified with --verify-config), which is what makes
        # hy3's deferred plugin load at `exec-once` survivable.
        layout = layout;
        resize_on_border = true;
        # col.active_border / col.inactive_border deliberately absent: they
        # come from the sourced colours file.
      };

      decoration = {
        # Comfortably above general:border_size so the corner arc still
        # reads through the thicker border.
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

      # `dwindle` / `group` / `binds` (native layout) and `plugin.hy3` (hy3)
      # merge in from `layoutSettings` at the end of this block -- exactly
      # one of the two sets is ever written.

      input = {
        kb_layout = "ch";
        kb_variant = "de_nodeadkeys";
        follow_mouse = 1;
        touchpad = {
          natural_scroll = false;
          disable_while_typing = false;
          # macOS trackpad semantics: two-finger click = right click, three
          # = middle. libinput's default "button areas" instead puts
          # right-click in the pad's bottom-right corner.
          clickfinger_behavior = true;
        };
      };

      misc = {
        disable_hyprland_logo = true;
        disable_splash_rendering = true;
        vrr = 1;
        # Nothing here should paint a wallpaper -- swww owns it.
        force_default_wallpaper = 0;
      };

      # Hyprland 0.55 rule grammar: `match:<field> <value>` selectors first,
      # then `<property> <value>`, snake_case (`suppress_event`,
      # `stay_focused`) -- the old `windowrulev2 = <property>, <field>:<value>`
      # form with camelCase properties is now a hard config error, not a
      # deprecation warning. Verify after a Hyprland bump with
      # `Hyprland --verify-config -c <file>`.
      windowrule = [
        "match:class .*, suppress_event maximize"
        # polkit prompts (hyprpolkitagent): float and keep focus, or the
        # password field loses the keyboard to whatever is underneath.
        "match:title (Authentication Required), float on"
        "match:title (Authentication Required), stay_focused on"
        # satty (the screenshot binds' annotation editor, see `sattyEdit` in
        # _scope.nix): floating is how it's meant to be used -- one capture,
        # annotate, Enter or Escape, gone. Class is its StartupWMClass.
        "match:class ^com\\.gabm\\.satty$, float on"
      ];

      # Puts something behind Caelestia's transparency (appearance.transparency
      # sets the alpha) -- prefix match over the shell's `caelestia-*`
      # surfaces. `ignore_alpha` matters for burn-in: without it, a blurred
      # strip sits at the top of the screen even while the bar is hidden
      # (fully transparent). Same Hyprland 0.55 grammar as the windowrules
      # above, and the same hard-error-not-a-warning behaviour for the old
      # `blur, <namespace>` / `ignorealpha 0.3, <namespace>` spellings.
      layerrule = [
        "match:namespace ^caelestia-.*, blur on"
        "match:namespace ^caelestia-.*, ignore_alpha 0.3"
      ];

      exec-once = [
        # Clipboard history, feeding the Super+V picker above.
        "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.cliphist}/bin/cliphist store"
        "${pkgs.wl-clipboard}/bin/wl-paste --type image --watch ${pkgs.cliphist}/bin/cliphist store"
        "${pkgs.hyprpolkitagent}/bin/hyprpolkitagent"
      ]
      # hy3 is a compositor plugin, loadable in hyprlang mode only from
      # `exec-once` -- i.e. after the config has parsed. Verified with
      # `Hyprland --verify-config`: `general:layout = hy3` and the whole
      # `plugin { hy3 { ... } }` block are NOT errors before the plugin
      # registers, but `bind = ..., hy3:movefocus, l` IS a hard error --
      # dispatchers resolve at parse time and an unknown one is *dropped*,
      # not deferred. Without `&& hyprctl reload` the session would come up
      # with every hy3 bind missing until the next wallpaper rotation's
      # post_hook reload. One command, not two exec-once entries, since
      # separate entries are ordered by spawn only and a standalone reload
      # could race the load. `config-only` skips re-running monitor
      # detection (same as HM's own onChange reload). This is also why
      # `wayland.windowManager.hyprland.plugins` is not used: it emits the
      # bare load with nothing to sequence a reload after it.
      ++ lib.optional hy3 "${hyprctl} plugin load ${hy3Plugin} && ${hyprctl} reload config-only";
    }
    // keybinds
    // layoutSettings;
  };
}
