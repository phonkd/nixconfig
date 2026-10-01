# Hyprland's windows as a rofi script mode: the launcher's `windows` mode,
# first in combi so a running window sorts above the .desktop entry that
# would start a second copy (see programs.rofi in _session.nix).
#
# Replaces rofi's built-in `window` mode on Hyprland for one reason: that
# mode's result handler ignores kb-custom-<k> and exits, and combi routes
# the key to whichever row is highlighted -- so Ctrl+<n> (switch mode)
# closed the launcher whenever a window row was selected. Script modes
# return kb-custom-<k> as "switch to mode index k-1", like drun does.
#
# Hidden windows (background hy3 tabs) are listed too, as the built-in
# mode lists every foreign toplevel.
#
# Order is most recently focused first, with the window that had focus when
# rofi opened moved to the end: picking the top row is "go back", as with
# Alt+Tab.
#
# perSystem package like rofi-sink-switcher.nix; import-tree picks it up.
{
  perSystem =
    { pkgs, ... }:
    {
      packages.rofi-hypr-windows = pkgs.writeShellApplication {
        name = "rofi-hypr-windows";

        # Absolute store paths: rofi runs this under the compositor's PATH.
        text = ''
          hyprctl=${pkgs.hyprland}/bin/hyprctl

          case "''${ROFI_RETV:-0}" in
            0)
              # Same row layout as the built-in mode's `{c}   {t}`; the icon
              # is looked up by class, which is the app id on Wayland.
              "$hyprctl" clients -j 2>/dev/null \
                | ${pkgs.jq}/bin/jq -r '
                    map(select(.mapped))
                    | sort_by(if .focusHistoryID == 0 then 1e9 else .focusHistoryID end)
                    | .[]
                    | .class + "   " + .title
                      + "\u0000icon\u001f" + .class
                      + "\u001finfo\u001f" + .address
                  ' \
                || true
              ;;
            1)
              if [ -n "''${ROFI_INFO:-}" ]; then
                "$hyprctl" dispatch focuswindow "address:$ROFI_INFO" >/dev/null
              fi
              ;;
          esac
        '';
      };
    };
}
