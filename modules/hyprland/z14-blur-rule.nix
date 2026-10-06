# Hyprland's hyprlang rules cannot condition global blur on an output count.
# Use its monitor/reload events; Caelestia reloads Hyprland when game mode ends.
{ ... }:
{
  flake.homeModules.z14-blur-rule = { config, lib, pkgs, osConfig ? null, ... }:
    let
      hyprctl = "${pkgs.hyprland}/bin/hyprctl";
      shell = lib.getExe' config.programs.caelestia.package "caelestia-shell";
      blurRule = pkgs.writeShellScript "z14-blur-rule" ''
        set -uo pipefail

        # `exec` also starts us on config reload, so a rebuild activates the
        # rule without logging out. Keep only one listener per session.
        exec 9>"$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/z14-blur-rule.lock"
        ${pkgs.util-linux}/bin/flock -n 9 || exit 0

        update_blur() {
          local external_count game_mode enabled
          external_count=$(${hyprctl} monitors -j | ${pkgs.jq}/bin/jq -er '
            [.[] | select(.name | test("^(eDP|LVDS|DSI)-") | not)] | length
          ') || return 0

          enabled=false
          if (( external_count < 2 )); then
            # Never restore blur when the shell cannot confirm game mode is
            # off. In particular, do not infer game mode from blur itself.
            game_mode=$(${pkgs.coreutils}/bin/timeout 2 ${shell} ipc call gameMode isEnabled 2>/dev/null) || return 0
            case "$game_mode" in
              false) enabled=true ;;
              true) enabled=false ;;
              *) return 0 ;;
            esac
          fi
          ${hyprctl} keyword decoration:blur:enabled "$enabled" >/dev/null
        }

        ${pkgs.socat}/bin/socat -u \
          "UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" - |
          {
            update_blur
            while IFS= read -r event; do
              case "$event" in
                monitoradded\>\>*|monitorremoved\>\>*|configreloaded\>\>*)
                  # Let the compositor finish updating its output list and
                  # Caelestia finish applying/restoring game-mode settings.
                  ${pkgs.coreutils}/bin/sleep 0.1
                  update_blur
                  ;;
              esac
            done
          }
      '';
    in {
      config = lib.mkIf (osConfig != null && osConfig.noughty.host.name == "z14"
        && config.wayland.windowManager.hyprland.enable) {
        wayland.windowManager.hyprland.settings.exec = [ "${blurRule}" ];
      };
    };
}
