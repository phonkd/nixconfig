# The shared scope of the Home Manager half: everything the old single-file
# module kept in one enormous `let`, minus the colour machinery (_matugen.nix).
#
# This is a `rec` attrset rather than a `let` for one reason -- the bindings
# reference each other exactly as they did before, and a `rec` is the only
# translation that needs no second listing of every name. _home.nix imports it
# once and hands the result to every section file as `scope`; each of those
# `inherit` the handful of names it actually uses, so the code in them is
# unchanged from when it all lived together.
#
# Nothing here reads `_matugen.nix`, and that is deliberate: it keeps the
# dependency one-way. `generated`, `groupbarMode` and `toggleGroupbarMode` live
# here rather than there even though they look like colour machinery, because
# the compositor and session sections name them and a cycle between the two
# files would need a fixpoint to break.
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
  enabled = osConfig == null || builtins.elem "hyprland" hostTags;

  cursorName = "Bibata-Modern-Classic";
  cursorSize = 24;

  cfg = osConfig.noughty.hyprland or { };
  wallpaperDir = cfg.wallpaperDir or null;
  wallpaperInterval = cfg.wallpaperInterval or 300;
  colorMode = cfg.colorMode or "dark";
  colorScheme = cfg.colorScheme or "scheme-tonal-spot";
  scale = cfg.scale or "1";
  loudnessKnob = cfg.loudnessKnob or false;
  workspaceScreens = cfg.workspaceScreens or { };

  layout = cfg.layout or "dwindle";
  hy3 = layout == "hy3";

  # The plugin .so. This is the same path Home Manager's own `plugins`
  # option would derive ($out/lib/lib<pname>.so), and hy3 ships exactly
  # that -- but that option is deliberately not used; see `exec-once`.
  #
  # It comes from nixpkgs, NOT from hy3's flake. That matters: hy3's README
  # tells you to add a `hy3` flake input with
  # `inputs.hyprland.follows = "hyprland"`, which here would build it
  # against this flake's `hyprland` input (Hyprland *master*) while the
  # session actually runs pkgs.hyprland. Hyprland refuses to load a plugin
  # built against a different commit, so that route yields a plugin that
  # silently never loads. pkgs.hyprlandPlugins.hy3 is built against
  # pkgs.hyprland by construction -- verified: the two share a store path
  # reference, and it substitutes from cache.nixos.org rather than building.
  hy3Plugin = "${pkgs.hyprlandPlugins.hy3}/lib/libhy3.so";

  # Absolute, like every other binary named from this config: `exec-once` is
  # run by the compositor, not by a login shell, so nothing guarantees the
  # user profile is on its PATH. (The matugen post_hook further down can say
  # a bare `hyprctl` only because it puts one on PATH itself.)
  hyprctl = "${pkgs.hyprland}/bin/hyprctl";

  # hy3 replaces the dispatchers that have to understand its tree. The
  # stock ones still exist under hy3 but operate on Hyprland's own notion
  # of layout, so leaving any of these unswapped makes the layout misbehave
  # in ways that look like bugs rather than misconfiguration.
  dispatch = name: if hy3 then "hy3:${name}" else name;

  # alt-shift-h/j/k/l is the one that does NOT follow the pattern above.
  # The dwindle side deliberately uses `movewindoworgroup` rather than
  # plain `movewindow`, so the same four keys also move windows in and out
  # of the native tab groups (see the bind's own comment). hy3 has no
  # `orgroup` variant -- `hy3:movewindow` is already tree-aware and does
  # the equivalent -- so the two spellings are named explicitly instead of
  # being derived, to keep `dispatch` from silently dropping the `orgroup`.
  moveWindowDispatch = if hy3 then "hy3:movewindow" else "movewindoworgroup";

  # Layout-specific settings, merged into `settings` below.
  #
  # Deliberately a plain `if`, not `lib.mkIf`: the Home Manager `settings`
  # option is a value type, not a submodule, so a nested mkIf is never
  # resolved -- it would reach toHyprconf as an attrset with
  # `_type = "if"` and be rendered into the config file verbatim.
  layoutSettings =
    if hy3 then
      {
        # Every key here is taken from the plugin binary's own option
        # strings (`strings libhy3.so | grep plugin:hy3`), not from the
        # README -- which is how the `radius`/`rounding` trap below was
        # caught.
        plugin.hy3 = {
          # Stacks on top of general:gaps_in (8), so deliberately smaller
          # than hy3's default of 10: otherwise every grouped node gains a
          # second, wider margin and reads as noticeably airier than the
          # same windows under dwindle.
          group_inset = 6;

          tabs = {
            height = 20;
            padding = 6;
            # `radius`, not `rounding` -- hy3 does not follow Hyprland's
            # own `decoration:rounding` spelling.
            radius = 6;
            border_width = 2;
            render_text = true;
            # Matches the native groupbar's font on the dwindle side, so
            # the two layouts' tab bars are the same object visually.
            text_font = "JetBrainsMono Nerd Font";
            text_height = 11;

            # `colors` is deliberately absent here, exactly as in `general`
            # and `group`: the tab palette is re-derived from the wallpaper
            # and arrives through the `source`d matugen file.
            #
            # This is a safety property, not just consistency. The obvious
            # alternative -- emit `$hy3TabActive` variables from matugen and
            # reference them from here -- breaks on a host where the seeding
            # activation finds no readable wallpaper: it writes an *empty*
            # colours file, and an undefined hyprlang variable is a hard
            # error ("failed to parse $hy3TabActive as a color"), verified
            # with --verify-config. With the keys living in the generated
            # file instead, an empty file simply means hy3 keeps its own
            # defaults and the session still comes up.
          };

          autotile = {
            # hy3 defaults this off, i.e. every split is manual. That is
            # strict i3 behaviour and a real step down from dwindle for
            # casual use, so it is on -- with triggers meaning "only
            # auto-split a node already big enough to be worth splitting".
            enable = true;
            trigger_width = 800;
            trigger_height = 500;
          };
        };
      }
    else
      {
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

        # -------------------------------------------------------------
        # Tabbed / stacked groups -- AeroSpace's accordion, in the one
        # place the Mac layout had something a plain dwindle tree does
        # not.
        #
        # On the Mac, alt-comma folds the focused container into an
        # accordion: the windows stop sharing the screen and take turns
        # in one tile. Hyprland's native groups are the same idea with
        # a tab bar on top -- which is i3's "tabbed", and with
        # `stacked` on, i3's "stacking". No plugin: hy3 would give the
        # full i3 tree (explicit split containers, groups holding
        # sub-splits), but it is an ABI-coupled plugin that has to be
        # rebuilt in lockstep with every Hyprland bump, and none of
        # what it adds beyond this is what the Mac layout does.
        #
        # Colours are deliberately absent here, exactly as in `general`
        # above: the groupbar palette is re-derived from the wallpaper
        # and arrives through the `source`d matugen file.
        group = {
          # Hyprland's default is ON, and it is the wrong default for a
          # layout meant to mirror AeroSpace: with auto_group on, every
          # window opened while a group has focus is silently swallowed
          # into that group. Grouping should only ever happen because
          # the keybind or a drag asked for it.
          auto_group = false;

          groupbar = {
            enabled = true;
            # `stacked` is deliberately NOT set here. It is the one
            # group option owned by the sourced groupbarMode file, so
            # that the toggle keybind can rewrite it; setting it here
            # too would win (hyprland.conf is parsed after its own
            # `source` lines) and pin the mode to whatever this says.
            #
            # The rest is sizing. Hyprland's defaults (14px bar, 8px
            # font) are tuned for a much tighter config than this one
            # -- 3px borders, 8/16 gaps, 12px rounding -- and a bar
            # that thin reads as a stripe rather than a tab.
            height = 20;
            font_family = "JetBrainsMono Nerd Font";
            font_size = 11;
          };
        };

        binds = {
          # What makes alt-h/j/k/l behave like AeroSpace inside an
          # accordion, and the reason this needs no extra "next tab"
          # key: with this on, movefocus cycles through the group's own
          # windows first and only leaves the group once it runs off
          # the end. Off (the default), focus skips straight past the
          # group's other tabs to the next tile, and the tabs are
          # reachable only with the mouse.
          movefocus_cycles_groupfirst = true;
        };
      };

  # Group / split bindings. alt-comma is AeroSpace's `layout accordion` and
  # keeps that meaning under both layouts -- only the machinery behind it
  # changes, so the muscle memory does not.
  #
  # hy3 adds the rest of the i3 tree, which the native groups have no
  # equivalent for. Key space is tight: ALT already owns H J K L F B V M,
  # COMMA, the six workspace letters (Q W E A S D) and the 1/2/3 number
  # row, which leaves C G N P R T U I O X Y Z. Letters rather than
  # AeroSpace's literal punctuation
  # (alt-slash "flip axis") -- on this ch/de_nodeadkeys keyboard `/` is
  # Shift+7, and the module already carries a note at the screenshot binds
  # about keysym-vs-`code:` spelling biting exactly that way. COMMA is
  # safe because it is an unshifted key on this layout; `/` is not.
  groupBinds =
    if hy3 then
      [
        # Fold the focused node into a tab group, and back out again.
        "${mod}, COMMA, hy3:changegroup, toggletab"
        # alt-shift-comma was "tabbed vs stacked" under the native
        # groupbar. hy3 has no stacked mode, so the key is reused for the
        # other half of AeroSpace's layout pair: flip the split axis
        # (AeroSpace's alt-slash).
        "${mod} SHIFT, COMMA, hy3:changegroup, opposite"
        # i3's `split h` / `split v` -- the explicit split containers that
        # are the whole reason for running hy3 over dwindle.
        "${mod}, N, hy3:makegroup, h"
        "${mod} SHIFT, N, hy3:makegroup, v"
        # i3's `focus parent` / `focus child`: walk up and down the tree
        # so a whole container can be moved or tabbed, not just a window.
        "${mod}, P, hy3:changefocus, raise"
        "${mod} SHIFT, P, hy3:changefocus, lower"
        # Cycle tabs within a group. Under dwindle this needs no key --
        # binds:movefocus_cycles_groupfirst puts it on alt-h/l -- but hy3
        # has no equivalent option, so the tabs get their own key.
        "SUPER, Tab, hy3:focustab, r"
        "SUPER SHIFT, Tab, hy3:focustab, l"
        # Temporarily grow a node over its siblings, and back.
        "${mod}, X, hy3:expand, expand"
        "${mod} SHIFT, X, hy3:expand, base"
      ]
    else
      [
        # alt-comma = group / ungroup, mirroring AeroSpace's
        # `layout accordion` on the same key. Tab bar appears, the
        # windows take turns in one tile, alt-h/l walks the tabs
        # (see binds:movefocus_cycles_groupfirst above).
        "${mod}, COMMA, togglegroup,"
        # alt-shift-comma = flip that bar between tabbed and stacked.
        # An exec rather than a dispatcher because Hyprland has no
        # dispatcher for it -- see toggleGroupbarMode for why the
        # mode has to be written to a file as well as set live.
        "${mod} SHIFT, COMMA, exec, ${toggleGroupbarMode}"
      ];

  cfgHome = config.xdg.configHome;

  # -- Keybindings -------------------------------------------------------
  #
  # Inherited from modules/kde.nix, which was itself AeroSpace's Option-key
  # layout with Option spelled Alt. `mod` is the knob for the
  # window-management half: set it to SUPER and focus, movement, grouping,
  # fullscreen and the launchers all move off Alt at once.
  #
  # It is no longer *every* bind, and the workspace keys are the exception
  # -- they sit on SUPER unconditionally now, for the reasons written out
  # at workspaceKeys below. Flipping `mod` to SUPER would collide them with
  # the window-management set rather than move them.
  #
  # The Alt-vs-menu-mnemonics caveat the KDE module carried applies here
  # too: on Linux Alt+<letter> is also how Qt/GTK apps reach their menu
  # bars, and a compositor bind wins over the focused app.
  mod = "ALT";

  # The whole number row, 1..9, onto workspaces 1..9 -- and on SUPER, not
  # on `mod`. This is the one part of the keymap that does not follow the
  # knob above, so it is worth saying why out loud.
  #
  # The scheme this replaces put workspaces on three keyboard *rows*
  # (123/QWE/ASD) as a 3x3 grid under Alt. It read well and it cost the
  # number row's Alt bindings, which is what made it untenable: the
  # screenshot keys wanted Alt+Shift+1/2/3, and under the grid that chord
  # was already send-to-workspace. Moving the workspaces one modifier over
  # frees Alt's digits outright rather than carving an exception out of
  # them, and a straight 1..9 needs no mnemonic -- the workspace number is
  # the key you press.
  #
  # Nothing collides on SUPER. Its letters are the ones spoken for (Q close,
  # W wallpaper, E files, D launcher, and the rest below), and this scheme
  # no longer uses letters at all; SUPER+1..9 and SUPER+Shift+1..9 were
  # both free, the latter only because the screenshot binds vacated it in
  # the same change.
  #
  # modules/aerospace.nix still runs the older layout -- the all-letters
  # QWE/ASD/UIO set that AeroSpace's binder forces; modules/kde.nix ran the
  # 123/QWE/ASD grid until it was removed. The sessions agreeing was always
  # a nicety rather than a constraint, and this one is a Hyprland keyboard
  # decision.
  #
  # Spelled `code:` rather than `1`..`9`, and that is not cosmetic. Every
  # one of these keys also carries a SHIFT bind (send-to-workspace), and
  # this is a ch/de_nodeadkeys keyboard where Shift+1 emits `plus` -- the
  # exact trap the screenshot binds carry a note about, and a dead
  # send-to-workspace key would fail silently. `code:` matches the physical
  # key, so it is immune both to that and to any later layout change. The
  # values are the X11 keycodes for AE01..AE09 (evdev code + 8), read off
  # xkb's own keycodes/evdev table rather than remembered.
  workspaceKeys = [
    "code:10"
    "code:11"
    "code:12"
    "code:13"
    "code:14"
    "code:15"
    "code:16"
    "code:17"
    "code:18"
  ];

  workspaceBinds = lib.flatten (
    lib.imap1 (i: key: [
      "SUPER, ${key}, workspace, ${toString i}"
      "SUPER SHIFT, ${key}, ${dispatch "movetoworkspace"}, ${toString i}"
    ]) workspaceKeys
  );

  # Launchers. Absolute store paths, for the same reason the KDE half used
  # them: `exec` is run by the compositor, not by a login shell, so nothing
  # guarantees the user profile is on its PATH.
  zen = "${inputs.zen-browser.packages.${pkgs.system}.default}/bin/zen";
  kitty = "${config.programs.kitty.package}/bin/kitty";

  # The two audio helpers, from their own files in modules/hyprland/.
  # Both are perSystem packages rather than `writeShellScript` inlined into
  # a bind, because both are far too much logic for a bind line and both
  # are worth being able to run by hand -- `nix run .#hypr-sink-switcher`
  # -- without bringing up a session. import-tree picks their files up
  # automatically; there is no import list to add them to.
  eeVolume = "${self.packages.${pkgs.system}.hypr-ee-volume}/bin/hypr-ee-volume";
  sinkSwitcher = "${self.packages.${pkgs.system}.hypr-sink-switcher}/bin/hypr-sink-switcher";

  # -- Screenshots: capture, then annotate -------------------------------
  #
  # grimblast keeps doing the capturing -- the targets, the freeze, the
  # window snapping -- and satty is bolted on behind it as the annotation
  # step: arrows, boxes, blur, text, highlight and auto-numbered markers
  # drawn over the capture before it goes anywhere. Tool keys inside
  # satty, since they are nowhere in its --help: z arrow, r rectangle,
  # e ellipse, i line, b brush, t text, g highlight, m numbered marker,
  # u blur, c crop, p pointer. Enter copies *and* saves a file; Escape
  # copies to the clipboard and keeps no file.
  #
  # The seam is grimblast's own `edit` action rather than a pipe. `edit`
  # writes the capture to a temp file and runs $GRIMBLAST_EDITOR with that
  # path as its final argument, which is exactly the hook this wants. The
  # obvious alternative -- `grimblast save area - | satty --filename -` --
  # is a trap: grimblast's save() ends in `echo "$file"`, so against a `-`
  # target it drops a stray "-\n" onto stdout directly behind the PNG's
  # IEND chunk. Decoders generally skip trailing bytes; nothing promises
  # they must, and a temp file costs nothing.
  #
  # satty then does *both* halves of what `copysave` used to do. The
  # action list is order-sensitive in a way its --help does not admit:
  # satty raises its early-exit flag after running the first action and
  # checks it immediately, so `--early-exit` next to a multi-action list
  # copies to the clipboard, logs "Early exit, ignoring further actions."
  # and never writes the file. Hence no `--early-exit`, and a trailing
  # `exit` inside the list, which runs all three in order.
  #
  # Escape is the other half of that, and it is not satty's default --
  # upstream's is a bare `exit`, i.e. throw the capture away. Here it
  # copies first, so neither exit from the editor can lose the shot:
  # Enter means "clipboard and keep a file", Escape means "clipboard
  # only". Nothing reachable from the editor discards, which is what
  # makes the annotate step safe to put on the primary screenshot keys
  # at all -- the old `copysave` was unconditional, and a GUI that can
  # silently eat a capture is a downgrade however good its arrows are.
  # The same trailing-`exit` ordering applies, for the same reason.
  #
  # --copy-command rather than satty's native GTK clipboard: a Wayland
  # clipboard offer dies with the process that made it and satty exits
  # straight after copying. wl-copy forks a small daemon that keeps
  # serving the selection, which is also what grimblast does today.
  #
  # Directory and filename format are grimblast's own, so an annotated
  # shot lands beside a plain one under the same naming.
  sattyEdit = pkgs.writeShellScript "satty-edit" ''
    set -u
    dir="''${XDG_SCREENSHOTS_DIR:-''${XDG_PICTURES_DIR:-$HOME}}"
    ${pkgs.coreutils}/bin/mkdir -p "$dir"
    ${pkgs.satty}/bin/satty \
      --filename "$1" \
      --output-filename "$dir/%Y%m%d_%H%M%S.png" \
      --actions-on-enter save-to-clipboard,save-to-file,exit \
      --actions-on-escape save-to-clipboard,exit \
      --copy-command ${pkgs.wl-clipboard}/bin/wl-copy
    ${pkgs.coreutils}/bin/rm -f "$1"
  '';

  # grimblast parks `edit`'s temp file in /tmp, which is world readable.
  # $XDG_RUNTIME_DIR is 0700 and goes away with the session, which is a
  # better home for a screenshot nobody has decided to keep yet -- and the
  # wrapper above deletes it either way.
  annotate =
    target:
    "env GRIMBLAST_EDITOR=${sattyEdit} DEFAULT_TMP_EDITOR_DIR=\"$XDG_RUNTIME_DIR\""
    + " ${pkgs.grimblast}/bin/grimblast --freeze edit ${target}";

  # -- Display settings GUI ----------------------------------------------
  #
  # nwg-displays is the arrange-your-monitors dialog Plasma had and a bare
  # compositor does not: position, resolution, refresh rate, scale,
  # rotation, mirroring, applied live via hyprctl and then written out.
  #
  # It persists by *writing Hyprland config*, which is the whole problem:
  # hyprland.conf here is a read-only symlink into the store. Same shape
  # as matugen and the colours, and the same answer -- the tool owns its
  # own file and this config pulls it in by absolute path. It picks the
  # paths up from $XDG_CONFIG_HOME/hypr and creates both files itself if
  # they are missing, so the defaults are already the right ones and only
  # the workspace count needs saying.
  monitorsConf = "${cfgHome}/hypr/monitors.conf";
  workspacesConf = "${cfgHome}/hypr/workspaces.conf";

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

  # Deliberately NOT in `generated` above: that attrset is matugen's output
  # and every entry in it is rewritten on each wallpaper rotation. This one
  # is user state -- which way round the groupbar draws -- and nothing but
  # the toggle keybind ever writes it.
  #
  # It has to be a `source`d file rather than a plain `hyprctl keyword`,
  # and that is not a stylistic choice. The wallpaper timer runs `hyprctl
  # reload` every wallpaperInterval seconds (300 by default, see the
  # matugen post_hook), and a reload resets every keyword override back to
  # what the config files say. A mode set with `keyword` alone would
  # therefore revert itself within five minutes. Sourced, it survives --
  # reload re-reads it like any other config.
  groupbarMode = "${cfgHome}/hypr/groupbar-mode.conf";

  # Flip the groupbar between tabbed (titles side by side, i3's "tabbed")
  # and stacked (titles listed one per row, i3's "stacking"). Hyprland has
  # one knob for both -- `group:groupbar:stacked` -- so this is a toggle
  # rather than two dispatchers.
  #
  # Current state is read back from the file rather than from `hyprctl
  # getoption`, which keeps the script honest about what will survive the
  # next reload and saves parsing JSON for one integer. A missing or empty
  # file reads as 0, which is both Hyprland's default and what the seeding
  # activation below writes.
  #
  # The file is written *and* the option is set live: writing alone would
  # not show up until the next `hyprctl reload` (up to wallpaperInterval
  # away), and setting alone would not survive it.
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

  themingEnabled = wallpaperDir != null;
}
