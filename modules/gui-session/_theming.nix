# Shared wallpaper rotation, derived colours, and activation scripts.
# that seed the files everything else `source`s.
#
# _home.nix wraps this whole file in `lib.mkIf scope.themingEnabled`, so
# setting noughty.gui.wallpaperDir = null leaves a perfectly usable
# static-colour session -- which is also why monitors.conf/workspaces.conf/
# groupbar-mode.conf seeding lives here rather than beside the compositor.
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
    hyprlandEnabled
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

  # The "matugen" theme named above: named colours only, imported by absolute
  # path since this theme is itself a store symlink.
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

  # GTK: HM keeps ownership of gtk.css, and these imports point it at the
  # colours matugen owns (`lines` merges, so this appends to any other
  # module's extraCss). Unconditional import, session-scoped target -- see
  # clearGtkColors below: outside a Hyprland session the imported file is
  # empty and this is a no-op.
  gtk.gtk3.extraCss = ''
    @import url("file://${generated.gtk3}");
  '';
  gtk.gtk4.extraCss = ''
    @import url("file://${generated.gtk4}");
  '';

  # Empties the GTK colour files when the graphical session ends, so the
  # declared GTK theme applies outside it. Nothing to do on start: the
  # wallpaper timer refills them moments later. RemainAfterExit is what
  # makes ExecStop run at session teardown rather than right after ExecStart.
  systemd.user.services.gui-gtk-colors = {
    Unit = {
      Description = "Scope GTK wallpaper colours to the graphical session";
      PartOf = [ "graphical-session.target" ];
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
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.awww-daemon = {
    Unit = {
      Description = "awww (swww) wallpaper daemon";
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      # `--no-cache`: a restored cached wallpaper would briefly contradict
      # the freshly-chosen colours on screen.
      ExecStart = "${pkgs.awww}/bin/awww-daemon --no-cache";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.gui-wallpaper = {
    Unit = {
      Description = "Pick a wallpaper and re-derive the colour scheme from it";
      PartOf = [ "graphical-session.target" ];
      After = [ "awww-daemon.service" ];
      Requires = [ "awww-daemon.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${rotate}";
    };
  };

  systemd.user.timers.gui-wallpaper = {
    Unit.Description = "Rotate the wallpaper (and the colour scheme with it)";
    Timer = {
      # Persistent deliberately absent: a missed rotation while logged out
      # isn't worth catching up.
      OnActiveSec = 3;
      OnUnitActiveSec = wallpaperInterval;
      AccuracySec = "5s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # Seed monitors.conf because Hyprland treats a missing `source` as a config
  # error. Keep workspaces.conf as local state for the migration below.
  home.activation.hyprlandDisplays = lib.mkIf hyprlandEnabled (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -z "''${DRY_RUN:-}" ]; then
      for f in ${lib.escapeShellArgs [ monitorsConf workspacesConf ]}; do
        if [ ! -e "$f" ]; then
          verboseEcho "Seeding $f for Hyprland"
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$f")"
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/touch "$f"
        fi
      done
    fi
  '');

  # Monique reads workspace rules from monitors.conf. Carry the old
  # nwg-displays rules over once, leaving workspaces.conf intact as a backup.
  home.activation.moniqueWorkspaceMigration = lib.mkIf hyprlandEnabled (
    lib.hm.dag.entryAfter [ "hyprlandDisplays" ] ''
      marker=${lib.escapeShellArg "${config.xdg.configHome}/monique/.nwg-workspaces-migrated"}
      if [ -z "''${DRY_RUN:-}" ] && [ ! -e "$marker" ]; then
        if [ -s ${lib.escapeShellArg workspacesConf} ] \
          && ! ${pkgs.gnugrep}/bin/grep -q '^workspace=' ${lib.escapeShellArg monitorsConf}; then
          ${pkgs.gnugrep}/bin/grep '^workspace=' ${lib.escapeShellArg workspacesConf} \
            >> ${lib.escapeShellArg monitorsConf} || true
        fi
        ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$marker")"
        ${pkgs.coreutils}/bin/touch "$marker"
      fi
    ''
  );

  # Seed every generated file, so the very first Hyprland login -- before
  # the timer has ever fired -- finds them present; otherwise Hyprland
  # errors on the missing `source` and rofi refuses its theme. Only ever
  # creates what is missing (a real rotation's output must never be
  # clobbered), and uses matugen itself for a genuine scheme, falling back
  # to empty files if no wallpaper is readable yet.
  home.activation.guiColors = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -z "''${DRY_RUN:-}" ]; then
      # The groupbar mode file is `source`d too but is user state, not
      # matugen output: seeded once with Hyprland's default (tabbed), then
      # owned by the toggle keybind.
      ${lib.optionalString hyprlandEnabled ''if [ ! -e ${lib.escapeShellArg groupbarMode} ]; then
        verboseEcho "Seeding the Hyprland groupbar mode (tabbed)"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p \
          "$(${pkgs.coreutils}/bin/dirname ${lib.escapeShellArg groupbarMode})"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/printf \
          'group {\n    groupbar {\n        stacked = 0\n    }\n}\n' \
          > ${lib.escapeShellArg groupbarMode}
      fi''}

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
          # post_hooks would try to reload a compositor not running during
          # activation, so they're tolerated failing; matugen itself still
          # writes every template.
          ${pkgs.matugen}/bin/matugen --quiet --source-color-index 0 \
            --type ${lib.escapeShellArg colorScheme} \
            --mode ${lib.escapeShellArg colorMode} \
            image "$seed" < /dev/null || true
        fi

        # Guarantee every file exists -- an absent one is a startup error
        # for its consumer, an empty one is not.
        for f in ${lib.escapeShellArgs (lib.attrValues generated)}; do
          [ -e "$f" ] || ${pkgs.coreutils}/bin/touch "$f"
        done

        # ...except the GTK pair, which must start out EMPTY: gtk.css is
        # user-wide, so a seeded-with-colours file would recolour GTK apps
        # before Hyprland had ever been used. Filled by the first wallpaper
        # rotation inside a session, emptied again when it ends (see
        # clearGtkColors in _matugen.nix).
        ${pkgs.coreutils}/bin/truncate -s 0 \
          ${lib.escapeShellArgs [ generated.gtk3 generated.gtk4 ]} || true
      fi
    fi
  '';

  # Load hy3 into an ALREADY-RUNNING session. `exec-once` covers a fresh
  # login only -- it does not re-run on `hyprctl reload` -- so rebuilding
  # while logged in lands a config where `general:layout = hy3` is accepted
  # (unregistered layout, not an error) but every `hy3:` bind is rejected
  # with "Invalid dispatcher" and dropped, until the next logout/login.
  #
  # Runs after `writeBoundary` (i.e. after HM's own onChange reload has
  # fired), so the ordering is load-then-reload and the binds land. Both
  # steps are safe to repeat -- a second load is refused with "Cannot load a
  # plugin twice!" and exit 0. XDG_RUNTIME_DIR dance and instance loop
  # lifted from HM's own reloadConfig: an activation has no session
  # environment to inherit, and there may be more than one compositor running.
  home.activation.hyprlandHy3Plugin = lib.mkIf (hyprlandEnabled && hy3) (
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
