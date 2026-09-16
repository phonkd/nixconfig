# Keybindings. Returns the four bind attrsets `settings` wants -- `bind`,
# `bindel`, `bindl`, `bindm` -- which _compositor.nix merges in; they share no
# key with anything else in there, so this is a plain `//` and not a decision.
#
# Only _compositor.nix imports this. It is a separate file because it is the
# largest single thing in the session and the one most often edited on its own:
# the keymap changes far more than the compositor's look does, and having it
# alone in a file means a keymap diff is a keymap diff.
#
# The scheme, and every argument for it, is in _scope.nix at `mod` and
# `workspaceKeys` -- read those before moving a key.
{
  config,
  lib,
  pkgs,
  scope,
}:
let
  inherit (scope)
    annotate
    dispatch
    eeVolume
    kitty
    loudnessKnob
    mod
    moveWindowDispatch
    groupBinds
    sinkSwitcher
    workspaceBinds
    zen
    ;
in
{
  # -------------------------------------------------------------
  # Keybindings -- the KDE set, verbatim where KDE has an
  # equivalent action. See modules/kde.nix for the
  # reasoning behind each choice; only the differences are noted
  # here.
  # -------------------------------------------------------------
  bind = [
    # alt-h/j/k/l = focus left/down/up/right
    "${mod}, H, ${dispatch "movefocus"}, l"
    "${mod}, J, ${dispatch "movefocus"}, d"
    "${mod}, K, ${dispatch "movefocus"}, u"
    "${mod}, L, ${dispatch "movefocus"}, r"

    # alt-shift-h/j/k/l = move the window. The KDE half had to
    # spell this as quick-tile, because KWin has no tiling-WM
    # "move node". Hyprland does, so this is a move -- which is
    # what the AeroSpace original actually does.
    #
    # `movewindoworgroup` rather than plain `movewindow`, so the
    # same four keys also get windows in and out of the tab
    # groups below: it moves *into* the neighbour if that
    # neighbour is a group, *out of* the current group if the
    # window is in one, and otherwise is exactly `movewindow`.
    # So nothing about the ungrouped case changes.
    "${mod} SHIFT, H, ${moveWindowDispatch}, l"
    "${mod} SHIFT, J, ${moveWindowDispatch}, d"
    "${mod} SHIFT, K, ${moveWindowDispatch}, u"
    "${mod} SHIFT, L, ${moveWindowDispatch}, r"
  ]
  # The group / split keys, which differ per layout -- spliced in
  # here rather than appended at the end purely so the generated
  # file keeps its existing order: on a dwindle host the rendered
  # hyprland.conf is then byte-for-byte what it was before this
  # option existed.
  ++ groupBinds
  ++ [

    # alt-f = fullscreen
    "${mod}, F, fullscreen, 0"

    # Meta+Q = close window, as in the KDE half. Alt+Q was a
    # workspace key when this landed, which is why it is not on
    # `mod`; the workspaces have since moved to SUPER's number
    # row and freed the letter, but the reason to leave this
    # alone is now muscle memory rather than a collision.
    "SUPER, Q, ${dispatch "killactive"},"

    # Launchers: alt-b/v -- two of the three apps KDE and
    # AeroSpace launch. Spotify was the third, on alt-m, and is
    # gone from here: alt-m now carries per-stream volume (see
    # the bindel block below), which is the key it was asked for.
    #
    # Dropping it costs nothing. Super+D's `combi` searches open
    # windows before .desktop entries, so typing "spotify" raises
    # the running instance and, with none running, falls through
    # to drun and starts one -- see the combi-modes comment in
    # programs.rofi.extraConfig. The package is installed
    # independently of this binding, by
    # users.users.phonkd.packages in modules/desktop.nix, so
    # dropping the last `pkgs.spotify` reference from this module
    # does not take Spotify out of the closure.
    "${mod}, B, exec, ${zen}"
    "${mod}, V, exec, ${kitty}"

    # --- Below here: things Plasma provides for free and a bare
    # --- compositor does not, so they have no counterpart in
    # --- modules/kde.nix.

    # Launcher on Super+D -- the key the pre-GNOME Hyprland config
    # in this repo's history used ($mainMod, D, exec, $menu), so
    # it is the muscle memory that predates the KDE session.
    # Deliberately NOT Alt+Space: that is KRunner's key on the
    # Plasma side, and Alt is already the workspace modifier here.
    #
    # `combi` rather than `drun`: it searches open windows *and*
    # .desktop entries in one list, so the launcher doubles as a
    # window switcher and picking an app that is already running
    # raises it instead of starting a second copy. The sub-modes
    # and their order live in programs.rofi.extraConfig below.
    "SUPER, D, exec, ${pkgs.rofi}/bin/rofi -show combi"
    # Float toggle -- AeroSpace's alt-space, which KDE could not
    # have because KRunner owns that key. Super+Space here.
    "SUPER, SPACE, togglefloating,"
    "SUPER, E, exec, ${pkgs.nautilus}/bin/nautilus"
    "SUPER, L, exec, ${pkgs.hyprlock}/bin/hyprlock"
    "SUPER SHIFT, E, exit,"
    # Screenshots -- Spectacle's job on the Plasma side. Three
    # targets on Super+Shift+1/2/3, screen -> window -> region,
    # narrowing as the number goes up, each one landing in satty
    # to be annotated before it is committed (see `annotate` and
    # `sattyEdit` above for the arrow/box/blur half and for why
    # the pipeline is shaped the way it is). `--freeze` holds the
    # screen still while you select, so menus and hover states
    # can be captured.
    #
    # The annotate step adds a confirmation `copysave` did not
    # have, but it cannot lose a capture: both ways out of satty
    # copy to the clipboard, and only Enter also writes a file
    # (see `sattyEdit`). What it does cost is immediacy, so plain
    # Print below stays on the old no-GUI path -- annotation is
    # the considered shot, Print is the reflex one.
    #
    # On Alt+Shift, and on `code:` rather than the keysyms
    # `1`/`2`/`3`. The keysym spelling is a live trap on this
    # ch/de_nodeadkeys keyboard, where Shift+1 emits `plus`:
    # Hyprland normally still matches the base-level keysym for a
    # SHIFT bind, but when it does not the bind is simply dead and
    # says nothing about it. `code:10`/`11`/`12` are the physical
    # AE01..AE03 keys and cannot be wrong, which is the same call
    # the workspace binds above made.
    #
    # These were on Super+Shift until the workspace keys took the
    # number row; they moved here, and the workspaces moved to
    # Super, in one change -- the two halves swapped modifiers
    # rather than either one carving an exception out of the
    # other. Alt+Shift+3 for a region also puts the considered
    # screenshot a finger-roll from macOS's Cmd+Shift+3.
    #
    # Alt+Shift+1: the monitor the mouse is on.
    "${mod} SHIFT, code:10, exec, ${annotate "output"}"
    # Alt+Shift+2: pick a window. grimblast dropped its `window`
    # target ("now included in 'area'"), so this is `area` with
    # slurp restricted to the window rectangles grimblast already
    # feeds it -- `slurp -r` is "restrict selection to predefined
    # boxes". SLURP_ARGS is grimblast's own documented hook for
    # this, not a wrapper around it. The practical difference from
    # plain `area` is that you cannot free-drag: every selection
    # snaps to exactly one window.
    "${mod} SHIFT, code:11, exec, SLURP_ARGS=-r ${annotate "area"}"
    # Alt+Shift+3: free region (single-clicking a window still
    # grabs that window, which is grimblast's own behaviour).
    "${mod} SHIFT, code:12, exec, ${annotate "area"}"
    # PrtSc keeps the old instant path: straight to the clipboard
    # and to disk, no editor, nothing to confirm. Shift+PrtSc is
    # the same region grab routed through satty, so the annotated
    # flow is also reachable from the obvious key.
    ", Print, exec, ${pkgs.grimblast}/bin/grimblast --freeze copysave area"
    "SHIFT, Print, exec, ${annotate "area"}"
    # Display arrangement GUI -- Win+P, the key Windows puts the
    # projector/display switcher on. `-n 9` because this config
    # has nine workspaces, not nwg-displays' default ten.
    "SUPER, P, exec, ${pkgs.nwg-displays}/bin/nwg-displays -n 9"
    "SUPER, C, exec, ${pkgs.hyprpicker}/bin/hyprpicker -a"
    "SUPER, V, exec, ${pkgs.cliphist}/bin/cliphist list | ${pkgs.rofi}/bin/rofi -dmenu | ${pkgs.cliphist}/bin/cliphist decode | ${pkgs.wl-clipboard}/bin/wl-copy"
    # Force a wallpaper + colour scheme change now, instead of
    # waiting out the timer.
    "SUPER, W, exec, ${pkgs.systemd}/bin/systemctl --user start hyprland-wallpaper.service"

    # Audio output switcher, on alt-0. Alt's digits are free now
    # that the workspaces sit on SUPER, so this no longer has to
    # dodge them -- but 0 stays the right key regardless: the
    # workspace set runs 1..9 and there is no workspace 10, so
    # the number row's last key is the one that never gets
    # claimed on either modifier.
    #
    # `code:19` is AE10, the physical 0. No SHIFT here, so the
    # keysym `0` would in fact have worked -- the Shift+1-emits-
    # `plus` trap needs a SHIFT bind to bite -- but spelling one
    # key of the number row differently from the other nine is
    # the kind of detail that goes wrong later.
    #
    # `bind`, not `bindel`: this opens a menu, and repeating it
    # while the key is held would stack a second rofi on the first.
    "SUPER, code:19, exec, ${sinkSwitcher}"
  ]
  ++ workspaceBinds;

  # Media and brightness keys. `bindel` repeats while held and
  # works on the lock screen.
  bindel = [
    # Device volume: the output as a whole.
    "SUPER, M, exec, ${pkgs.wireplumber}/bin/wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%+"
    "SUPER SHIFT, M, exec, ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
  ]
  # Loudness: the same M key on the other modifier, moving the
  # volume of `easyeffects_sink` -- which is BEFORE the effects,
  # where the device binds above are after them. On a host whose
  # preset lifts bass as a function of level, this is the knob
  # that changes how the speakers *sound* rather than how loud
  # they are: down for bassy quiet listening, up for clean and
  # loud. It deliberately does not move the OSD, because the OSD
  # follows the default sink.
  #
  # Opt-in per host (noughty.hyprland.loudnessKnob), because on a
  # host without such a preset it would be a second, invisible
  # attenuator stacked under the real volume key. See
  # modules/hyprland/ee-volume.nix, and LOUDNESS.md in the
  # laptop-speakers repo for why this is two keys rather than a
  # patched shell.
  ++ lib.optionals loudnessKnob [
    "${mod}, M, exec, ${eeVolume} up"
    "${mod} SHIFT, M, exec, ${eeVolume} down"
  ]
  ++ [
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
}
