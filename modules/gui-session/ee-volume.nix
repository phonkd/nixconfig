# Optional pre-effects loudness helper used by the Hyprland keymap.
# volume, distinct from the device volume on Super+M. See LOUDNESS.md in the
# laptop-speakers repo for the full decision record.
#
# The z14 EasyEffects preset gets its Sonos-like behaviour from LEVEL: band0
# of the multiband compressor runs in `Boosting` mode, so the quieter the
# signal arriving at the chain, the more bass it adds. The device volume
# (Super+M) sits AFTER the effects and only changes loudness; the tonal-balance
# knob has to be upstream, at `easyeffects_sink` -- the one node every
# playback stream passes through regardless of which sink is default.
#
# Replaced hypr-stream-volume (which moved every application stream instead):
# a stream's volume belongs to the app -- Spotify re-applies its own slider on
# every track change, stomping the knob -- so this moves the SINK's volume,
# which stays put across tracks and app restarts.
#
# The other half of the mechanism is the `node.rules` drop-in in
# modules/desktop.nix, which sets `monitor.channel-volumes` on this sink:
# EasyEffects reads the MONITOR ports, and without that property a monitor tap
# is taken before this node's volume stage, so this script would move a volume
# nothing listens to. Must be set at node creation -- flipping it at runtime
# with pw-cli goes silent on the next change instead of quieter.
#
# wpctl, not `pactl set-sink-volume easyeffects_sink 5%+`: pactl has no cap,
# and this gain lands *before* the chain where `bindel`'s repeat-while-held
# could walk it far past 0 dB. wpctl's `-l` cap only addresses a node by id,
# hence the lookup. Capped at 1.0 rather than the device bind's 1.4 -- above
# unity here is boost into the effects, not loudness out of them.
{
  perSystem =
    { pkgs, ... }:
    {
      packages.hypr-ee-volume = pkgs.writeShellApplication {
        name = "hypr-ee-volume";

        # Absolute store paths rather than `runtimeInputs`: `exec` runs under
        # the compositor, not a login shell, and guarantees nothing about PATH.
        text = ''
          case "''${1-}" in
            up)
              cap=( -l 1.0 )
              step="5%+"
              ;;
            down)
              cap=()
              step="5%-"
              ;;
            *)
              echo "usage: hypr-ee-volume up|down" >&2
              exit 2
              ;;
          esac

          # EasyEffects not running is an ordinary state -- must not become an
          # error on the compositor's log every key repeat.
          id="$(
            ${pkgs.pipewire}/bin/pw-dump 2>/dev/null \
              | ${pkgs.jq}/bin/jq -r 'first(.[]
                  | select(.type == "PipeWire:Interface:Node")
                  | select(.info.props["node.name"] == "easyeffects_sink")
                  | .id) // empty' 2>/dev/null \
              || true
          )"

          if [ -z "$id" ]; then
            exit 0
          fi

          ${pkgs.wireplumber}/bin/wpctl set-volume "''${cap[@]}" "$id" "$step"
        '';
      };
    };
}
