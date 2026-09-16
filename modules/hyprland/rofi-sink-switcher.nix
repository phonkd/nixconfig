# Audio output switcher for the Hyprland session, on alt-0.
#
# A rofi menu of the PipeWire sinks, and picking one makes it the default
# output. The list on z14 is mostly not the laptop: four of the six sinks are
# AirPlay (`raop_sink.*`) targets discovered on the LAN -- three Sonos units
# and 203-media's shairport -- because modules/hosts/z14.nix loads
# `libpipewire-module-raop-discover`. Switching between "laptop speakers" and
# "the Sonos in the kitchen" is the whole point of the key.
#
# Packaged as a perSystem package like modules/hyprland/ee-volume.nix, and
# for the same reasons: too much logic for a bind line, and worth being able to
# run by hand (`nix run .#hypr-sink-switcher`) without a session. import-tree
# picks this file up on its own; modules/hyprland.nix only names the package.
#
# Why setting the default is the whole job
# ----------------------------------------
# The obvious worry with a sink switcher is stale streams: change the default
# and the music keeps playing out of the old device, because PipeWire created
# those links against the sink that was default at the time. The usual answer
# is to chase every stream with `pactl move-sink-input`. That answer is wrong
# here, and actively harmful:
#
# EasyEffects is running (services.easyeffects.enable in modules/desktop.nix),
# and it pulls application audio into its own virtual sink to process it. The
# real chain on this host is
#
#     spotify -> easyeffects_sink -> ee_soe_equalizer -> ee_soe_crystalizer
#             -> ee_soe_multiband_compressor -> ee_soe_spectrum
#             -> ee_soe_output_level -> alsa_output...analog-stereo
#
# so the application stream is NOT attached to the output device at all -- it
# is attached to EasyEffects, six nodes upstream. "Move every stream to the
# chosen sink" would yank Spotify out of the middle of that chain and bypass
# the user's entire EQ. The thing that actually needs to be re-pointed is the
# *tail* of the chain, `ee_soe_output_level`.
#
# And that follows the default on its own. It carries no `target.object` and no
# `node.target`, so WirePlumber owns where it lands and re-links it whenever the
# default changes -- verified on this host by pointing the default at a
# throwaway null sink and watching ee_soe_output_level move to it and back,
# rather than by trusting the documentation. EasyEffects' own output-device
# setting is likewise unset (`dconf read
# /com/github/wwmm/easyeffects/streamoutputs/output-device` is empty), which is
# its "follow the system default" state.
#
# So `wpctl set-default` is the entire operation, and it is the correct one
# whether or not EasyEffects is in the path: an ordinary unpinned stream is
# moved by WirePlumber for the same reason, and a stream someone pinned to a
# specific device by hand was pinned deliberately and should not be dragged
# along by a key that says "change the output".
{
  perSystem =
    { pkgs, ... }:
    {
      packages.hypr-sink-switcher = pkgs.writeShellApplication {
        name = "hypr-sink-switcher";

        # Absolute store paths rather than `runtimeInputs`, for the reason
        # modules/hyprland.nix gives for its launchers: the compositor's `exec`
        # is not a login shell and guarantees nothing about PATH.
        text = ''
          # Which sink is default right now, by node.name. Read from the
          # `default` metadata rather than `wpctl status`, whose default marker
          # is a `*` glyph inside a box-drawing tree -- the same reason
          # ee-volume.nix does not parse that output either. The value is
          # JSON, so jq reads the name out instead of a second regex.
          default_name="$(
            ${pkgs.pipewire}/bin/pw-metadata -n default 2>/dev/null \
              | ${pkgs.gnused}/bin/sed -n "s/.*key:'default\.audio\.sink' value:'\([^']*\)'.*/\1/p" \
              | ${pkgs.jq}/bin/jq -r '.name // empty' \
              || true
          )"

          # One line per sink: the node id, a tab, then the label rofi shows.
          #
          # `easyeffects_sink` is deliberately not offered. It is a processing
          # stage, not somewhere sound comes out -- picking it as the output
          # would point the EasyEffects chain at its own input. Every other
          # virtual sink stays listed, because a null sink or a loopback IS a
          # legitimate destination; this excludes one node by name rather than
          # excluding virtual sinks as a class.
          #
          # node.description is the human name ("Bedroom", "Ryzen HD Audio
          # Controller Analog Stereo"); node.name is the stable identifier
          # ("raop_sink.Sonos-...") and is only the fallback, for a sink that
          # somehow carries no description.
          #
          # The current default is marked with a bullet and sorted to the top,
          # so the menu opens on what is playing now and the labels still line
          # up for the ones that are not.
          menu="$(
            ${pkgs.pipewire}/bin/pw-dump 2>/dev/null \
              | ${pkgs.jq}/bin/jq -r --arg default "$default_name" '
                  .[]
                  | select(.type == "PipeWire:Interface:Node")
                  | select(.info.props["media.class"] == "Audio/Sink")
                  | select(.info.props["node.name"] != "easyeffects_sink")
                  | (.info.props["node.name"]) as $name
                  | [ (if $name == $default then 0 else 1 end)
                    , .id
                    , (if $name == $default then "● " else "  " end)
                      + (.info.props["node.description"] // $name)
                    ]
                  | @tsv
                ' 2>/dev/null \
              | ${pkgs.coreutils}/bin/sort -k1,1n -k3 \
              | ${pkgs.coreutils}/bin/cut -f2,3 \
              || true
          )"

          # No sinks at all means PipeWire is not up yet. Nothing useful to
          # show, and an empty rofi is worse than no rofi.
          if [ -z "$menu" ]; then
            exit 0
          fi

          # rofi is handed only the label column, and gives back the line it
          # was given; the id is recovered by matching that line back against
          # $menu. Passing the id through rofi's display would mean either
          # showing it to the user or relying on -format, and this way the
          # label is free to contain anything at all.
          #
          # `rofi -dmenu` matches the clipboard bind in modules/hyprland.nix, so
          # this inherits the same matugen theme with no extra configuration.
          choice="$(
            printf '%s\n' "$menu" \
              | ${pkgs.coreutils}/bin/cut -f2 \
              | ${pkgs.rofi}/bin/rofi -dmenu -i -p "Output" \
              || true
          )"

          # Escape, or rofi killed: no selection, nothing to do, and this must
          # not look like a failure. `|| true` above already swallowed rofi's
          # exit code for `set -e`; this is the actual control flow.
          if [ -z "$choice" ]; then
            exit 0
          fi

          # Recover the id for the chosen label. Exact whole-line match on the
          # second field -- not a substring search -- because sink descriptions
          # are user-visible strings that can contain regex metacharacters and
          # can be prefixes of one another. awk with the label in a variable
          # compares it as data, so nothing in the name is ever interpreted.
          id="$(
            printf '%s\n' "$menu" \
              | ${pkgs.gawk}/bin/awk -F'\t' -v want="$choice" '$2 == want { print $1; exit }'
          )"

          if [ -z "$id" ]; then
            exit 0
          fi

          # The whole operation -- see the header for why nothing else is
          # needed, and why chasing individual streams would be wrong.
          ${pkgs.wireplumber}/bin/wpctl set-default "$id"
        '';
      };
    };
}
