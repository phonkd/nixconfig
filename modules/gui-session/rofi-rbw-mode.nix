# Bitwarden as a rofi script mode: the launcher's `bitwarden` mode (Ctrl+1
# inside SUPER+D, see programs.rofi in _session.nix).
#
# Not a wrapper around rofi-rbw: rofi initialises every configured mode when
# it starts, so a mode that merely launched rofi-rbw would fire on every
# SUPER+D. Instead this lists rbw's Login entries itself, and Enter types
# username, Tab, password -- rofi-rbw's own default action. A locked vault
# shows a single "Unlock" row that hands off to rofi-rbw, which runs the
# pinentry unlock and its full menu; never prompting here keeps SUPER+D
# from raising pinentry just by opening.
#
# perSystem package like rofi-sink-switcher.nix; import-tree picks it up.
{
  perSystem =
    { pkgs, ... }:
    {
      packages.rofi-rbw-mode = pkgs.writeShellApplication {
        name = "rofi-rbw-mode";
        # The detached `bash -c` bodies take their values as $1.. on purpose.
        excludeShellChecks = [ "SC2016" ];

        # Absolute store paths: rofi runs this under the compositor's PATH.
        text = ''
          rbw=${pkgs.rbw}/bin/rbw

          case "''${ROFI_RETV:-0}" in
            0)
              printf '\0prompt\x1fBitwarden\n'
              if ! "$rbw" unlocked >/dev/null 2>&1; then
                printf 'Unlock vault\0info\x1funlock\n'
                exit 0
              fi
              # info carries id<TAB>user so selection needs no second lookup.
              "$rbw" list --raw 2>/dev/null \
                | ${pkgs.jq}/bin/jq -r '
                    .[]
                    | select(.type == "Login")
                    | (.user // "") as $user
                    | .name
                      + (if $user != "" then "  (" + $user + ")" else "" end)
                      + (if (.folder // "") != "" then "  [" + .folder + "]" else "" end)
                      + "\u0000info\u001f" + .id + "\t" + $user
                  ' \
                || true
              ;;
            1)
              info="''${ROFI_INFO:-}"
              [ -n "$info" ] || exit 0
              rofi_pid="$PPID"

              # Detached, with stdout closed: rofi reads this script's stdout
              # to EOF before it can exit. Wait for rofi to go so focus is
              # back on the target window, then type into it.
              if [ "$info" = unlock ]; then
                ${pkgs.util-linux}/bin/setsid -f ${pkgs.bash}/bin/bash -c '
                  for _ in {1..40}; do kill -0 "$1" 2>/dev/null || break; sleep 0.05; done
                  exec ${pkgs.rofi-rbw-wayland}/bin/rofi-rbw
                ' _ "$rofi_pid" >/dev/null 2>&1 </dev/null
                exit 0
              fi

              id="''${info%%	*}"
              user="''${info#*	}"
              ${pkgs.util-linux}/bin/setsid -f ${pkgs.bash}/bin/bash -c '
                for _ in {1..40}; do kill -0 "$1" 2>/dev/null || break; sleep 0.05; done
                sleep 0.15
                pass="$(${pkgs.rbw}/bin/rbw get -- "$2")" || exit 1
                if [ -n "$3" ]; then
                  printf "%s" "$3" | ${pkgs.wtype}/bin/wtype -
                  ${pkgs.wtype}/bin/wtype -k Tab
                fi
                printf "%s" "$pass" | ${pkgs.wtype}/bin/wtype -
              ' _ "$rofi_pid" "$id" "$user" >/dev/null 2>&1 </dev/null
              ;;
          esac
        '';
      };
    };
}
