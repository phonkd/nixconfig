# Audio output switcher for the Hyprland session, on alt-0.
#
# A rofi menu of the PipeWire sinks; picking one makes it the default output.
# On z14, four of the six sinks are AirPlay (`raop_sink.*`) targets on the LAN
# (three Sonos units and 203-media's shairport), via
# `libpipewire-module-raop-discover` in modules/hosts/z14.nix.
#
# Packaged as a perSystem package like ee-volume.nix, for the same reasons:
# too much logic for a bind line, worth running by hand
# (`nix run .#hypr-sink-switcher`). import-tree picks this file up on its
# own; modules/hyprland.nix only names the package.
#
# Setting the default is the whole job -- NOT chasing every stream with
# `pactl move-sink-input`, which would be wrong here: EasyEffects
# (services.easyeffects.enable in modules/desktop.nix) pulls application
# audio into its own virtual sink first, so the real chain is
#
#     spotify -> easyeffects_sink -> ee_soe_equalizer -> ee_soe_crystalizer
#             -> ee_soe_multiband_compressor -> ee_soe_spectrum
#             -> ee_soe_output_level -> alsa_output...analog-stereo
#
# and "move every stream" would yank Spotify out of the middle of that chain,
# bypassing the EQ. Only the chain's tail, `ee_soe_output_level`, needs
# re-pointing, and it does so on its own: it carries no `target.object` or
# `node.target`, so WirePlumber re-links it whenever the default changes --
# verified by pointing the default at a throwaway null sink and watching it
# follow. `wpctl set-default` is therefore the entire operation, correct
# whether or not EasyEffects is in the path: an unpinned stream follows for
# the same reason, and a stream pinned to a specific device by hand should
# stay put.
{
  perSystem =
    { pkgs, ... }:
    {
      packages.hypr-sink-switcher = pkgs.writeShellApplication {
        name = "hypr-sink-switcher";

        # Absolute store paths rather than `runtimeInputs`: `exec` runs under
        # the compositor, not a login shell, and guarantees nothing about PATH.
        text = ''
          # Read from the `default` metadata rather than `wpctl status`, whose
          # default marker is a `*` glyph inside a box-drawing tree.
          default_name="$(
            ${pkgs.pipewire}/bin/pw-metadata -n default 2>/dev/null \
              | ${pkgs.gnused}/bin/sed -n "s/.*key:'default\.audio\.sink' value:'\([^']*\)'.*/\1/p" \
              | ${pkgs.jq}/bin/jq -r '.name // empty' \
              || true
          )"

          # One line per sink: the node id, a tab, then the label rofi shows.
          # `easyeffects_sink` is excluded by name -- it's a processing stage,
          # not an output, and picking it would point the chain at its own
          # input; other virtual sinks (null sinks, loopbacks) stay listed.
          # node.description is the human name, node.name the fallback.
          # The current default is bulleted and sorted to the top.
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

          # No sinks means PipeWire is not up yet; an empty rofi is worse than none.
          if [ -z "$menu" ]; then
            exit 0
          fi

          # rofi is handed only the label column and gives back the line it
          # was given; the id is recovered by matching it back against $menu,
          # so the label is free to contain anything at all.
          choice="$(
            printf '%s\n' "$menu" \
              | ${pkgs.coreutils}/bin/cut -f2 \
              | ${pkgs.rofi}/bin/rofi -dmenu -i -p "Output" \
              || true
          )"

          # Escape, or rofi killed: no selection, and this must not look like a failure.
          if [ -z "$choice" ]; then
            exit 0
          fi

          # Exact whole-line match, not a substring search: sink descriptions
          # can contain regex metacharacters and be prefixes of one another.
          id="$(
            printf '%s\n' "$menu" \
              | ${pkgs.gawk}/bin/awk -F'\t' -v want="$choice" '$2 == want { print $1; exit }'
          )"

          if [ -z "$id" ]; then
            exit 0
          fi

          ${pkgs.wireplumber}/bin/wpctl set-default "$id"
        '';
      };
    };
}
