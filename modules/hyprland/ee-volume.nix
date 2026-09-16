# The loudness knob for the laptop speakers, on Alt+M.
#
# This is the *pre-effects* volume, and it is a different thing from the device
# volume on Super+M in modules/hyprland.nix. Both are needed; they do different
# jobs. See LOUDNESS.md in the laptop-speakers repo for the full decision
# record, measurements included. The short version:
#
# The z14 EasyEffects preset gets its Sonos-like behaviour from LEVEL -- band0
# of the multiband compressor runs in `Boosting` mode, so the quieter the signal
# arriving at the chain, the more bass it adds. The signal path is
#
#     app stream -> easyeffects_sink -> EQ > crystalizer > multiband -> device
#
# so the device volume (`@DEFAULT_AUDIO_SINK@`, Super+M) sits AFTER the effects:
# it changes how loud things are and nothing else. The knob that changes the
# tonal balance has to be upstream of the chain, and `easyeffects_sink` is the
# single node everything passes through before it -- EasyEffects pulls every
# playback stream into that sink regardless of which sink is default, verified
# by watching an untargeted `pw-play` land there.
#
# This replaced hypr-stream-volume, which moved every application stream
# instead. Two reasons it is gone:
#
#   * a stream's volume belongs to the application. Spotify re-applies its
#     in-app slider to its stream on every track change, so the knob was being
#     stomped at the next song. Nothing outside PipeWire can touch a SINK's
#     volume, so this one stays where it is put -- across tracks, across app
#     restarts, and across every app at once.
#   * it was ~200 lines of jq deciding what counts as an application stream.
#     This is one node, by name.
#
# The other half of the mechanism is NOT here: it is the `node.rules` drop-in in
# modules/desktop.nix, which sets `monitor.channel-volumes` on this sink. The
# EasyEffects chain reads the sink's MONITOR ports, and a monitor tap is taken
# before the node's volume stage unless that property is set -- so without the
# drop-in this script moves a volume that nothing in the graph listens to. The
# property has to be set when the node is created; flipping it at runtime with
# pw-cli makes the monitor go silent on the next volume change instead of
# quieter, which is a dead end and not worth re-investigating.
#
# Why wpctl and not `pactl set-sink-volume easyeffects_sink 5%+`, which needs no
# script at all: pactl addresses a sink by name but has no cap, and this gain
# lands *before* the chain, where `bindel`'s repeat-while-held could otherwise
# walk it far past 0 dB. wpctl has `-l` but only addresses a node by id, hence
# the lookup. The cap is 1.0 rather than the device bind's 1.4 for the same
# reason: above unity here is boost into the effects, not loudness out of them.
{
  perSystem =
    { pkgs, ... }:
    {
      packages.hypr-ee-volume = pkgs.writeShellApplication {
        name = "hypr-ee-volume";

        # Absolute store paths rather than `runtimeInputs`, for the reason
        # modules/hyprland.nix gives for its launchers: the compositor's `exec`
        # is not a login shell and guarantees nothing about PATH.
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

          # `first(...)` rather than `... | .id` piped through head: the node
          # name is unique, and an empty result has to stay empty rather than
          # becoming a stray line. EasyEffects not running is an ordinary
          # state -- the service is user-level and can be stopped -- so it must
          # not turn into an error on the compositor's log every key repeat.
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
