# The compositor itself: outputs, environment, look, input, window and layer
# rules, and what the session starts. The keybindings are the one part that
# lives elsewhere -- _keybinds.nix -- because they are the single largest
# thing in here and have nothing to say about the rest of it.
#
# `settings` is therefore assembled in three pieces, and the order of the
# `//`s is load-bearing in one direction only: `layoutSettings` must come last,
# because it is the hy3-vs-dwindle switch and is allowed to have the final word
# on anything the base config guessed at. `keybinds` shares no key with either.
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
    workspaceScreens
    workspacesConf
    ;
in
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

    # nwg-displays' output, and the one place in this file where
    # *where* a `source` lands is the entire point.
    #
    # `settings.source` below would not do. Home Manager hands
    # `source` to toHyprconf's importantPrefixes, which hoists those
    # lines to the very top of the generated file -- correct for the
    # colours, fatal here: the generic `monitor=,preferred,auto,...`
    # rule further down would then be read *after* nwg-displays'
    # per-output lines. `extraConfig` is concatenated last (verified
    # in HM's own hyprland.nix, where the file's text is systemd
    # activation + plugins + settings + submaps + extraConfig), so
    # anything the GUI writes wins over the fallback, which is what
    # keeps that fallback a sane default rather than an override.
    #
    # workspaces.conf is sourced too, not just monitors.conf: the
    # same dialog assigns workspaces to outputs, and leaving that
    # half unsourced would make a working-looking part of the GUI
    # quietly do nothing. Nothing else in this module emits
    # `workspace=` rules, so it has the field to itself.
    #
    # Both are seeded empty at activation -- see
    # home.activation.hyprlandDisplays -- because Hyprland treats a
    # `source` of a missing file as a config error, and nwg-displays
    # only creates them the first time it is actually run.
    extraConfig = ''
      source = ${monitorsConf}
      source = ${workspacesConf}
    '';

    settings = {
      # Colours live in a file matugen rewrites on every wallpaper
      # change; `source` is absolute because this config itself is a
      # store path, so a relative path would resolve into /nix/store.
      # The file is seeded at activation, so it always exists.
      # Second entry is the groupbar tabbed/stacked mode -- user
      # state the toggle keybind writes, sourced for the same reason
      # the colours are: `hyprctl reload` re-reads sourced files and
      # discards anything set with `hyprctl keyword`. Both are seeded
      # at activation, so neither is ever a missing-source error.
      source = [
        generated.hypr
      ]
      # Native-groupbar state only. hy3 draws its own tabs and has no
      # stacked mode, so under hy3 this file has nothing to say and
      # the keybind that writes it is not bound either.
      ++ lib.optional (!hy3) groupbarMode;

      # ",preferred,auto,<scale>" -- every output, its preferred mode,
      # auto-placed, at noughty.hyprland.scale (1 = 100%).
      monitor = ",preferred,auto,${scale}";

      # Which screen each workspace opens on, from
      # noughty.hyprland.workspaceScreens -- `{ "eDP-1" = [ 1 2 3 ]; }`
      # becomes `workspace = 1, monitor:eDP-1` and so on. Empty on every
      # host that does not set it, which emits nothing at all.
      #
      # This is stock Hyprland doing the work, including the part that
      # looks like it would need a helper: an unplugged monitor is not an
      # error, its workspaces go to a monitor that exists, and they come
      # back when it does. The option's own comment in _nixos.nix has the
      # rest, and the one limit worth repeating here is that a rule names
      # a monitor -- there is no "the second screen from the left".
      #
      # nwg-displays' workspaces.conf can set the same rules from the GUI
      # and is sourced from `extraConfig` above, i.e. *after* this. That
      # ordering is deliberate and is the same bargain the `monitor=`
      # fallback strikes: what is declared here is the default, and the
      # dialog is allowed to overrule it for as long as its file says so.
      workspace = lib.concatLists (
        lib.mapAttrsToList (
          screen: workspaces: map (ws: "${toString ws}, monitor:${screen}") workspaces
        ) workspaceScreens
      );

      # The cursor half of `env` names the theme this module installs
      # itself (`home.pointerCursor` in _session.nix). It is spelled
      # out here rather than left to the environment because session
      # variables reach Hyprland only via the login shell greetd
      # starts it from, and this makes the pointer independent of that
      # path. It used to be conditional: `home.pointerCursor` is
      # *user-wide* state, so on a KDE host modules/kde.nix owned it
      # (AeroThemePlasma's "aero-drop") and naming a second theme here
      # would have named one not actually installed. No KDE, no
      # condition. Still no HYPRCURSOR_* -- bibata ships XCursor only,
      # and pointing hyprcursor at a theme it cannot find is a warning
      # and a fallback, not an upgrade.
      env = [
        "QT_QPA_PLATFORM,wayland;xcb"
        "MOZ_ENABLE_WAYLAND,1"
        "XCURSOR_THEME,${cursorName}"
        "XCURSOR_SIZE,${toString cursorSize}"
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
        # noughty.hyprland.layout. Naming a layout the compositor has not
        # registered yet is NOT a config error (verified with
        # --verify-config), which is what makes hy3's deferred plugin
        # load at `exec-once` survivable.
        layout = layout;
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

      # `dwindle` / `group` / `binds` (for the native layout) and
      # `plugin.hy3` (for hy3) are merged in from `layoutSettings` at
      # the end of this block. Exactly one of the two sets is ever
      # written -- this module does not carry dead config for the
      # layout that is not in use.

      input = {
        # Swiss German, no dead keys -- carried over from the old
        # Hyprland config in git history. Plasma took this from its
        # own keyboard settings, which is why the KDE modules never
        # had an equivalent line to inherit.
        kb_layout = "ch";
        kb_variant = "de_nodeadkeys";
        follow_mouse = 1;
        touchpad = {
          natural_scroll = false;
          disable_while_typing = false;
          # macOS trackpad semantics: a physical click with two
          # fingers down is a right click, three a middle click.
          # libinput calls this the "clickfinger" click method; its
          # default is "button areas", where right-click lives in
          # the bottom-right corner of the pad and two fingers just
          # click left. Tapping already behaved the Mac way --
          # tap-to-click is on and libinput's tap button map is
          # 1/2/3 fingers = left/right/middle -- so this only closes
          # the gap for the pad's physical button.
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
        # satty, the annotation editor the screenshot binds hand their
        # capture to (see `sattyEdit` in the scope module). Tiled, it
        # gets slotted into whatever the workspace already has open and
        # the canvas ends up sharing a column with the window that was
        # just captured; floating, it comes up over the top, which is
        # how it actually behaves -- one capture, annotate, Enter or
        # Escape, gone. The class is the package's own StartupWMClass
        # (share/applications/satty.desktop), not a guess.
        "match:class ^com\\.gabm\\.satty$, float on"
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
      ]
      # hy3 is a compositor plugin, and in hyprlang mode a plugin can
      # only be loaded from `exec-once` -- i.e. *after* the config has
      # been parsed. That ordering is the one real hazard in the whole
      # layout switch, so it was measured rather than assumed, with
      # `Hyprland --verify-config` (the workflow the windowrule note
      # further down already prescribes):
      #
      #   * `general:layout = hy3` naming a layout that is not
      #     registered yet is NOT an error. Hyprland accepts it and
      #     picks the layout up when the plugin registers it.
      #   * the whole `plugin { hy3 { ... } }` block is NOT an error
      #     either -- `plugin:` is a free-form bucket, so unknown
      #     subkeys are tolerated and applied once the plugin lands.
      #   * `bind = ..., hy3:movefocus, l` IS a hard error:
      #     "Invalid dispatcher, requested "hy3:movefocus" does not
      #     exist". Dispatchers resolve at parse time, and a bind
      #     naming an unknown one is *dropped*, not deferred.
      #
      # So without the `&& hyprctl reload` below the session would
      # come up with every hy3 bind missing and a config-error banner,
      # and would only heal at the next wallpaper rotation -- whose
      # post_hook happens to run `hyprctl reload`, up to
      # noughty.hyprland.wallpaperInterval seconds later. Chaining the
      # reload onto the load makes that immediate and deterministic.
      #
      # One command rather than two exec-once entries on purpose:
      # separate entries are ordered by *spawn* only, so a standalone
      # reload could re-parse before the load had finished registering
      # the dispatchers. `config-only` keeps it from re-running
      # monitor detection, which is what Home Manager's own onChange
      # reload uses too.
      #
      # This is also why `wayland.windowManager.hyprland.plugins` is
      # not used: it emits the bare `hyprctl plugin load` line with
      # nothing to sequence a reload after it.
      ++ lib.optional hy3 "${hyprctl} plugin load ${hy3Plugin} && ${hyprctl} reload config-only";
    }
    // keybinds
    // layoutSettings;
  };
}
