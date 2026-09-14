# Per-application volume for the Hyprland session.
#
# modules/hyprland.nix already has DEVICE volume, on Super+M / Super+Shift+M:
# `wpctl set-volume @DEFAULT_AUDIO_SINK@` moves the output as a whole. This is
# the other half -- the per-stream mixer fader that Plasma's volume applet and
# pavucontrol expose, so Spotify can be turned down without turning the laptop
# down. Bound on the `mod` (Alt) side of the same M key; the exact binds live
# in modules/hyprland.nix's `bindel` list, and `bindel` is deliberate: it
# repeats while held, which is what makes a 5% step usable.
#
# Packaged as its own perSystem package (like `linver` in modules/kde.nix)
# rather than inlined as a `writeShellScript` in the bind, for two reasons: it
# is far too much logic for a bind line, and it can be built and run on its own
# -- `nix build .#hypr-stream-volume` and then `./result/bin/hypr-stream-volume
# up` -- without evaluating a host closure. Consumers name it as
# `self.packages.${pkgs.system}.hypr-stream-volume`.
#
# Which streams? -- the interpretation, and how to change it
# ----------------------------------------------------------
# The request was "volume of all audio streams (not devices but e.g. spotify)",
# and this implements that literally: EVERY application playback stream moves
# together, by a relative step, so streams that sat at different levels stay at
# different levels. Two alternatives were considered and rejected as defaults:
#
#   (b) only the focused window's stream. Technically fine -- `hyprctl
#       activewindow -j` gives a pid and PipeWire nodes carry
#       application.process.id (verified: Spotify's window pid and its node's
#       application.process.id are the same process) -- but it is silent
#       whenever the focused window makes no sound, which is the *common* case
#       for this key: you are reading something else and want the music
#       quieter. Turning the volume key into a no-op depending on focus is a
#       worse trade than occasionally moving two streams at once.
#   (c) only the stream that is currently `running`. Means a paused Spotify
#       cannot be pre-set, and the key silently does nothing during a gap
#       between tracks.
#
# Both are a one-line swap at `restrict` below, which is why that line exists
# at all instead of the filter being written straight through.
#
# What counts as "an application audio stream"
# --------------------------------------------
# The object class is what decides this, not a name blocklist. PipeWire nodes
# carry `media.class`, and only `Stream/Output/Audio` is an application playing
# audio. Checked against what is actually live on z14:
#
#   * Audio/Sink, Audio/Source, Audio/Source/Virtual -- the DEVICES the user
#     explicitly does not mean. This drops the ALSA card, the four AirPlay
#     (raop_sink) Sonos targets, and EasyEffects' virtual sink/source.
#   * Stream/Input/Audio -- RECORDING streams. This is what drops the two
#     WEBRTC VoiceEngine capture streams and, more importantly, the six
#     monitor/capture streams pavucontrol opens just by having its window
#     open. A "set the volume of every stream" script that parsed `wpctl
#     status`'s flat Streams list would have grabbed all of those.
#   * media.class absent entirely -- EasyEffects' filter chain
#     (ee_soe_equalizer, ee_soe_crystalizer, ...) is `media.role = "DSP"` with
#     no media.class, so the chain is skipped for free. Worth stating because
#     EasyEffects is the one thing here that could have needed special
#     handling and does not: Spotify's stream is routed *into* the Easy Effects
#     Sink rather than the default device, and a stream's own volume is applied
#     at the stream, so this works identically whether or not the EE detour is
#     in the path. That is exactly the property the device-volume bind lacks.
#
# The one exclusion that is not a class check is notification blips. libcanberra
# and anything else playing a freedesktop sound DOES open a real, if very
# short-lived, Stream/Output/Audio. Setting a volume on it is harmless but
# pointless, and it would make an Alt+M press mean something different
# depending on whether a notification happened to be sounding. They are
# excluded by role. Note the spelling: PulseAudio clients set
# `media.role=event`, and PipeWire hands it back normalised to
# `"Notification"` -- verified by playing one and dumping the node, not read
# off a wiki. `"Event"` is checked too, for a native client that spells it the
# PipeWire way.
#
# WEBRTC *playback* is deliberately NOT excluded: the far end of a call is
# audio coming out of the speakers, and "make everything quieter" should make
# it quieter too.
#
# Why pw-dump + jq rather than parsing `wpctl status`
# ---------------------------------------------------
# `wpctl status` prints streams as a tree with box-drawing characters, with the
# port list nested underneath, and nothing in it says which class a stream is
# or what role it has -- the filtering above is simply not expressible. It also
# prints application names verbatim, so any parse has to survive names with
# spaces ("PulseAudio Volume Control", and whatever a user's app is called).
# pw-dump emits JSON and this script never touches anything but the numeric
# node ids, so the spaces question disappears. Cost: ~45ms for pw-dump plus a
# jq startup, measured on z14 -- cheap enough for a key that repeats while
# held, and the same order as the wpctl call it replaces.
{
  perSystem =
    { pkgs, ... }:
    {
      packages.hypr-stream-volume = pkgs.writeShellApplication {
        name = "hypr-stream-volume";

        # Absolute store paths for every binary below rather than
        # `runtimeInputs`, for the reason modules/hyprland.nix states for its
        # launchers: this is run by the compositor's `exec`, not by a login
        # shell, so nothing guarantees a useful PATH.
        text = ''
          # Relative steps, and 5% to match the device binds in
          # modules/hyprland.nix rather than inventing a second step size.
          case "''${1-}" in
            up)
              # -l caps the RESULT, so it belongs on the up direction only --
              # exactly as on the device bind. Passing it while going down
              # would yank a stream that pavucontrol had put above 1.4 down to
              # the cap on the first press, which is not what the key says it
              # does. 1.4 is the device bind's cap; a stream fader multiplies
              # into the sink's, so this is 140% of an already-140%-capable
              # output and is meant as a rescue for quiet sources, not a
              # normal operating point.
              cap=( -l 1.4 )
              step="5%+"
              ;;
            down)
              cap=()
              step="5%-"
              ;;
            *)
              echo "usage: hypr-stream-volume up|down" >&2
              exit 2
              ;;
          esac

          # -- INTERPRETATION SWITCH -------------------------------------
          # (a) every application playback stream. See the header for why
          # this is the default. To switch:
          #
          #   (b) focused window only -- ALSO uncomment the jq arg:
          #       restrict='select(.info.props["application.process.id"] == ($focused | tonumber))'
          #       focused=( --arg focused "$(hyprctl activewindow -j | jq -r .pid)" )
          #       ...with both of those spelled as absolute store paths.
          #   (c) only what is audibly playing right now:
          #       restrict='select(.info.state == "running")'
          restrict='select(true)'

          # Object class first, then the notification-role exclusion. `!=`
          # against a missing key is true in jq (null != "Notification"), which
          # is what we want: a stream with no media.role at all is a normal
          # application stream and stays in.
          filter="
            .[]
            | select(.type == \"PipeWire:Interface:Node\")
            | select(.info.props[\"media.class\"] == \"Stream/Output/Audio\")
            | select(.info.props[\"media.role\"] != \"Notification\")
            | select(.info.props[\"media.role\"] != \"Event\")
            | $restrict
            | .id
          "

          # `|| true` because "no audio at all" is a completely ordinary state
          # for this key -- PipeWire not up yet, or simply nothing playing --
          # and it must not turn into an error on the compositor's log every
          # time the key repeats. An empty list falls through to the exit
          # below.
          mapfile -t ids < <(
            ${pkgs.pipewire}/bin/pw-dump 2>/dev/null \
              | ${pkgs.jq}/bin/jq -r "$filter" 2>/dev/null \
              || true
          )

          if [ "''${#ids[@]}" -eq 0 ]; then
            exit 0
          fi

          for id in "''${ids[@]}"; do
            # Streams are born and die constantly -- a track ending, a Chromium
            # tab closing -- so a node enumerated a few milliseconds ago may
            # already be gone by the time wpctl reaches it. That is expected,
            # not a failure, and it must not abort the loop and leave the
            # remaining streams unchanged: `set -e` would do exactly that
            # without the `|| true`.
            ${pkgs.wireplumber}/bin/wpctl set-volume "''${cap[@]}" "$id" "$step" || true
          done
        '';
      };
    };
}
