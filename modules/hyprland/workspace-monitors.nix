# Which screen each workspace lives on, decided by where the screens *are*.
#
#     workspaces 1 2 3   the built-in z14 panel
#     workspaces 4 5 6   the leftmost external
#     workspaces 7 8 9   the rightmost external
#
# and a screen that is not plugged in falls back to the panel.
#
# Hyprland has the rule for this already -- `workspace = 4, monitor:HDMI-A-1`,
# which also handles the fallback on its own: it parks the workspaces of a
# vanished monitor elsewhere and pulls them back when it returns. What it has no
# spelling for is the *selector*. A workspace rule names one monitor, by
# connector name or by `desc:`, and there is no "the second one from the left".
# That is the whole reason this file exists rather than three lines in
# _compositor.nix: which port the externals land in is not a property of this
# config (HDMI-A-1 today, some DP-N in another dock), while which side of the
# desk they sit on is exactly what the user means by "monitor 2".
#
# So the mapping is computed from the live output list and pushed in as dynamic
# rules. Slotting, in `order` below:
#
#   * slot 1 is the internal panel -- eDP/LVDS/DSI -- by definition, not by
#     position. It sits *below* the leftmost external here, so sorting purely by
#     x would make it the leftmost screen and steal workspaces 4-6.
#   * slots 2, 3, ... are the externals sorted by x, left to right.
#
# Externals keep their slot whether or not the panel is on. With the lid shut,
# workspaces 4-6 therefore stay on the left screen and 7-9 on the right, and
# only 1-3 relocate -- the alternative (renumber everything up by one when the
# panel goes away) moves three groups instead of one and breaks the muscle
# memory that is the entire point of pinning them.
#
# Two pushes per workspace, because they answer different questions:
#
#   * `keyword workspace <n>,monitor:<name>` is where the workspace will open
#     the *next* time it is opened. It does nothing to one that already exists.
#   * `dispatch moveworkspacetomonitor` moves the ones that do.
#
# Re-run on monitoradded/monitorremoved, obviously -- and on `configreloaded`,
# which is not optional and is the easiest thing here to get wrong: rules set
# with `hyprctl keyword` are *dynamic*, and a config reload drops every one of
# them. Something reloads this session every few minutes (the wallpaper
# rotation's post_hook, see _matugen.nix), so without that case the mapping
# would quietly evaporate a few minutes into every login.
#
# nwg-displays' `workspaces.conf` (Super+P, the dialog's workspace column) is
# sourced by _compositor.nix and can set the same rules statically. It is not
# wrong to use, it just loses: it names a connector, and this helper overwrites
# whatever it said on the next event. Leave that column empty.
{
  perSystem =
    { pkgs, ... }:
    {
      packages.hypr-workspace-monitors = pkgs.writeShellApplication {
        name = "hypr-workspace-monitors";

        # `runtimeInputs` rather than the absolute store paths the two audio
        # helpers spell out: those are launched from a keybind, where the
        # compositor's `exec` guarantees nothing about PATH. This one is a
        # systemd user unit, which inherits no PATH at all -- so the wrapper's
        # own `export PATH=` is the thing that has to be right, and that is
        # precisely what runtimeInputs writes.
        runtimeInputs = with pkgs; [
          hyprland # hyprctl
          jq
          socat
          coreutils
        ];

        text = ''
          # Monitor slots, one per line, in the order described at the top of
          # this file. Line 1 is the internal panel and is EMPTY when there
          # isn't one (lid shut, or a desktop) -- an empty line rather than a
          # dropped one, so the externals keep slots 2 and 3 either way.
          order() {
            hyprctl -j monitors | jq -r --arg panel '^(eDP|LVDS|DSI)' '
              (map(select(.name | test($panel))) | sort_by(.x) | .[0].name // ""),
              (map(select(.name | test($panel) | not)) | sort_by(.x) | .[].name)
            '
          }

          apply() {
            local -a slots
            mapfile -t slots < <(order)

            # What a workspace whose slot is unplugged falls back to: the panel
            # if there is one, else the leftmost screen that does exist. Also
            # the guard for having no outputs at all, mid-hotplug.
            local fallback="" m
            for m in "''${slots[@]}"; do
              if [ -n "$m" ]; then
                fallback=$m
                break
              fi
            done
            [ -n "$fallback" ] || return 0

            # Only existing workspaces can be moved; `moveworkspacetomonitor` on
            # one that was never opened is an error, not a no-op.
            local -A live=()
            local id
            while read -r id; do live[$id]=1; done < <(
              hyprctl -j workspaces | jq -r '.[].id'
            )

            local -a batch=()
            local ws idx target
            for ws in 1 2 3 4 5 6 7 8 9; do
              idx=$(((ws - 1) / 3))
              target=''${slots[idx]:-}
              [ -n "$target" ] || target=$fallback

              # No space after the comma: `--batch` splits on `;` but hyprctl
              # still reassembles each command from argv.
              batch+=("keyword workspace $ws,monitor:$target")
              if [ -n "''${live[$ws]:-}" ]; then
                batch+=("dispatch moveworkspacetomonitor $ws $target")
              fi
            done

            # One IPC round trip for all of it, so a hotplug cannot be seen
            # half-applied.
            local IFS=";"
            hyprctl --batch "''${batch[*]}" >/dev/null
          }

          sig=''${HYPRLAND_INSTANCE_SIGNATURE:-}
          if [ -z "$sig" ]; then
            echo "hypr-workspace-monitors: not inside a Hyprland session" >&2
            exit 1
          fi

          apply

          # socket2 is the event stream. `monitoradded` fires before the new
          # output has been positioned by monitors.conf, and position is the
          # whole input to `order` -- hence the settle. The burst of events a
          # single hotplug produces (monitoradded, monitoraddedv2, and the
          # focus changes behind them) just re-runs an idempotent apply.
          socat -U - "UNIX-CONNECT:''${XDG_RUNTIME_DIR}/hypr/$sig/.socket2.sock" |
            while read -r line; do
              case $line in
              monitoradded* | monitorremoved* | configreloaded*)
                sleep 0.3
                apply
                ;;
              esac
            done
        '';
      };
    };
}
