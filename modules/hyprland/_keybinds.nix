# Keybindings. Returns the four bind attrsets `settings` wants -- `bind`,
# `bindel`, `bindl`, `bindm` -- which _compositor.nix merges in with a plain
# `//` (they share no key with anything else there).
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
    kitty
    mod
    moveWindowDispatch
    groupBinds
    sinkSwitcher
    workspaceBinds
    zen
    ;
in
{
  bind = [
    # alt-h/j/k/l = focus left/down/up/right
    "${mod}, H, ${dispatch "movefocus"}, l"
    "${mod}, J, ${dispatch "movefocus"}, d"
    "${mod}, K, ${dispatch "movefocus"}, u"
    "${mod}, L, ${dispatch "movefocus"}, r"

    # alt-shift-h/j/k/l = move the window. `movewindoworgroup` rather than
    # plain `movewindow`, so the same four keys also move windows in and out
    # of the tab groups below: it moves *into* the neighbour if that
    # neighbour is a group, *out of* the current group if the window is in
    # one, otherwise exactly `movewindow`.
    "${mod} SHIFT, H, ${moveWindowDispatch}, l"
    "${mod} SHIFT, J, ${moveWindowDispatch}, d"
    "${mod} SHIFT, K, ${moveWindowDispatch}, u"
    "${mod} SHIFT, L, ${moveWindowDispatch}, r"
  ]
  # Spliced in here rather than appended at the end, so a dwindle host's
  # rendered hyprland.conf keeps its existing byte-for-byte order.
  ++ groupBinds
  ++ [

    # alt-f = fullscreen
    "${mod}, F, fullscreen, 0"

    "SUPER, Q, ${dispatch "killactive"},"

    # alt-m carries per-stream volume (bindel block below), not Spotify --
    # Super+D's `combi` already raises a running Spotify by name (see
    # combi-modes in programs.rofi.extraConfig), so nothing is lost.
    "${mod}, B, exec, ${zen}"
    "${mod}, V, exec, ${kitty}"

    # `combi` rather than `drun`: searches open windows *and* .desktop
    # entries in one list, so picking an already-running app raises it
    # instead of starting a second copy. Sub-modes live in
    # programs.rofi.extraConfig below.
    "SUPER, D, exec, ${pkgs.rofi}/bin/rofi -show combi"
    "SUPER, SPACE, togglefloating,"
    "SUPER, E, exec, ${pkgs.nautilus}/bin/nautilus"
    "SUPER, L, exec, ${pkgs.hyprlock}/bin/hyprlock"
    "SUPER SHIFT, E, exit,"
    # Three targets, screen -> window -> region, each landing in satty to be
    # annotated (see `annotate`/`sattyEdit` in _scope.nix). `--freeze` holds
    # the screen still while you select. Both exits from satty copy to the
    # clipboard and only Enter also writes a file, so nothing here can lose
    # a capture -- plain Print below stays on the old no-GUI path for when
    # immediacy matters more than the annotation step.
    #
    # `code:` rather than keysyms `1`/`2`/`3`: on this ch/de_nodeadkeys
    # keyboard Shift+1 emits `plus`, so a SHIFT bind on the keysym can go
    # silently dead. `code:10`/`11`/`12` are the physical AE01..AE03 keys.
    #
    # Alt+Shift+1: the monitor the mouse is on.
    "${mod} SHIFT, code:10, exec, ${annotate "output"}"
    # Alt+Shift+2: pick a window -- `area` with slurp restricted to the
    # window rectangles grimblast feeds it (`SLURP_ARGS=-r`, grimblast's own
    # documented hook), since it dropped its own `window` target. No
    # free-drag: every selection snaps to exactly one window.
    "${mod} SHIFT, code:11, exec, SLURP_ARGS=-r ${annotate "area"}"
    # Alt+Shift+3: free region (single-clicking a window still grabs it).
    "${mod} SHIFT, code:12, exec, ${annotate "area"}"
    # PrtSc: instant clipboard + disk, no editor. Shift+PrtSc is the same
    # region grab routed through satty.
    ", Print, exec, ${pkgs.grimblast}/bin/grimblast --freeze copysave area"
    "SHIFT, Print, exec, ${annotate "area"}"
    # `-n 9`: this config has nine workspaces, not nwg-displays' default ten.
    "SUPER, P, exec, ${pkgs.nwg-displays}/bin/nwg-displays -n 9"
    "SUPER, C, exec, ${pkgs.hyprpicker}/bin/hyprpicker -a"
    "SUPER, V, exec, ${pkgs.cliphist}/bin/cliphist list | ${pkgs.rofi}/bin/rofi -dmenu | ${pkgs.cliphist}/bin/cliphist decode | ${pkgs.wl-clipboard}/bin/wl-copy"
    # Force a wallpaper + colour scheme change now, instead of waiting out the timer.
    "SUPER, W, exec, ${pkgs.systemd}/bin/systemctl --user start hyprland-wallpaper.service"

    # `code:19` is the physical 0 (AE10) -- 0 is the number row's last key,
    # never claimed on either modifier since the workspace set is 1..9.
    # `bind`, not `bindel`: this opens a menu, and repeat-while-held would
    # stack a second rofi on the first.
    "SUPER, code:19, exec, ${sinkSwitcher}"
  ]
  ++ workspaceBinds;

  # `bindel` repeats while held and works on the lock screen.
  bindel = [
    # Device volume: the output as a whole.
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

  bindm = [
    "SUPER, mouse:272, movewindow"
    "SUPER, mouse:273, resizewindow"
  ];
}
