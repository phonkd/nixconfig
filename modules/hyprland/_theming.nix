# Wallpaper rotation + wallpaper-derived colours, and the activation scripts
# that seed the files everything else `source`s.
#
# _home.nix wraps this whole file in `lib.mkIf scope.themingEnabled`, so
# setting noughty.hyprland.wallpaperDir = null leaves a perfectly usable
# static-colour session. That gate is the reason the seeding of monitors.conf,
# workspaces.conf and groupbar-mode.conf lives here too rather than beside the
# compositor: it always has, and moving it would change which hosts get it.
#
# The machinery this consumes -- templates, the matugen config, the rotation
# script, the GTK helpers -- is in _matugen.nix.
{
  config,
  lib,
  pkgs,
  scope,
  matugen,
}:
let
  inherit (matugen)
    clearGtkColors
    declaredColorScheme
    matugenConfig
    rotate
    setColorScheme
    ;

  inherit (scope)
    colorMode
    colorScheme
    generated
    groupbarMode
    hy3
    hy3Plugin
    hyprctl
    monitorsConf
    wallpaperDir
    wallpaperInterval
    workspacesConf
    ;
in
{
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
      Description = "Scope the GTK colour scheme and wallpaper colours to the Hyprland session";
      PartOf = [ "hyprland-session.target" ];
    };
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${setColorScheme "prefer-${colorMode}"}";
      ExecStop = [
        "${clearGtkColors}"
        "${setColorScheme declaredColorScheme}"
      ];
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

  # nwg-displays' two files, seeded empty for exactly the reason the
  # colour files below are seeded: `extraConfig` `source`s them, and
  # Hyprland calls a missing `source` a config error. nwg-displays
  # does create them itself, but only when it is first run, which on
  # a fresh host is strictly after the first login that has to parse
  # this config.
  #
  # Empty is the right seed rather than a copy of the fallback
  # `monitor=` rule: an empty file says "the GUI has not been used
  # here", which leaves `monitor=,preferred,auto,<scale>` in the
  # generated config as the thing actually in charge. As with the
  # colours, an existing file is never touched -- the GUI's output
  # is user state and an activation must not clobber it.
  home.activation.hyprlandDisplays = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -z "''${DRY_RUN:-}" ]; then
      for f in ${lib.escapeShellArgs [ monitorsConf workspacesConf ]}; do
        if [ ! -e "$f" ]; then
          verboseEcho "Seeding $f for nwg-displays"
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$f")"
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/touch "$f"
        fi
      done
    fi
  '';

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
      # The groupbar mode file is `source`d too, so it has the same
      # must-exist-or-it-is-a-config-error property as the colour
      # files -- but it is user state, not matugen output, so it is
      # seeded on its own terms: written once with Hyprland's own
      # default (tabbed), and never touched again. The toggle keybind
      # owns it from then on.
      if [ ! -e ${lib.escapeShellArg groupbarMode} ]; then
        verboseEcho "Seeding the Hyprland groupbar mode (tabbed)"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p \
          "$(${pkgs.coreutils}/bin/dirname ${lib.escapeShellArg groupbarMode})"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/printf \
          'group {\n    groupbar {\n        stacked = 0\n    }\n}\n' \
          > ${lib.escapeShellArg groupbarMode}
      fi

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

  # Load hy3 into an ALREADY-RUNNING session.
  #
  # `exec-once` covers a fresh login and nothing else -- it does not
  # re-run on `hyprctl reload`, by design. So rebuilding while logged
  # into Hyprland lands the new config in a session where the plugin
  # was never loaded: Home Manager's own onChange reload re-parses it,
  # `general:layout = hy3` is accepted (an unregistered layout is not
  # an error), and every `hy3:` bind is rejected with "Invalid
  # dispatcher" and dropped. The visible result is a config-error
  # banner plus dead alt-keys until the next logout/login, which is a
  # miserable way to find out.
  #
  # This closes that gap: load the plugin, then reload so the binds
  # register. Both are safe to repeat -- a second load is refused with
  # "Cannot load a plugin twice!" and exit 0, leaving the one
  # instance alone.
  #
  # Runs after `writeBoundary`, i.e. after linkGeneration has already
  # fired Home Manager's onChange reload, so the ordering is
  # load-then-reload and the binds land. The XDG_RUNTIME_DIR dance and
  # the instance loop are lifted from HM's own reloadConfig: an
  # activation has no session environment to inherit, and there may be
  # more than one compositor running.
  home.activation.hyprlandHy3Plugin = lib.mkIf hy3 (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ -z "''${DRY_RUN:-}" ]; then
        XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}"
        export XDG_RUNTIME_DIR
        if [ -d "/tmp/hypr" ] || [ -d "$XDG_RUNTIME_DIR/hypr" ]; then
          for i in $(${hyprctl} instances -j 2>/dev/null \
            | ${pkgs.jq}/bin/jq -r '.[].instance' 2>/dev/null); do
            verboseEcho "Loading hy3 into Hyprland instance $i"
            ${hyprctl} -i "$i" plugin load ${hy3Plugin} >/dev/null 2>&1 || true
            ${hyprctl} -i "$i" reload config-only >/dev/null 2>&1 || true
          done
        fi
      fi
    ''
  );
}
