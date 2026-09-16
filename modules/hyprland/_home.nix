# Hyprland, Home Manager half: the actual session. Self-gates the same way the
# KDE home modules do -- on osConfig -- so it is inert if it is ever imported
# on a host without the tag.
#
# This file does nothing but assemble. The shared scope is built once and
# handed to every section, which is what lets the sections stay ordinary
# attrsets of Home Manager options instead of functions of each other.
#
# The merge below is flat where the old single-file module had one enormous
# attrset followed by the theming block. That is the same thing: the three
# eager sections share no top-level option between them, so merging them as
# three list entries and merging them as one attrset produce the same config.
#
# modules/hyprland.nix carries the design notes and a map of this directory.
{ self, inputs }:
{
  config,
  lib,
  pkgs,
  osConfig ? null,
  ...
}:
let
  scope = import ./_scope.nix {
    inherit
      config
      lib
      pkgs
      self
      inputs
      osConfig
      ;
  };

  matugen = import ./_matugen.nix { inherit config lib pkgs scope; };

  section = path: import path { inherit config lib pkgs scope; };
in
{
  # Unconditional, like every other import here: the module only declares
  # options, and all of its config hangs off `programs.caelestia.enable` in
  # _shell.nix, which is itself inside `lib.mkIf enabled`. A host without the
  # hyprland tag therefore gets the options and none of the shell.
  imports = [ inputs.caelestia.homeManagerModules.default ];

  config = lib.mkIf scope.enabled (
    lib.mkMerge [
      (section ./_compositor.nix)
      (section ./_shell.nix)
      (section ./_session.nix)

      # Split out so that setting noughty.hyprland.wallpaperDir = null leaves a
      # perfectly usable static-colour session.
      (lib.mkIf scope.themingEnabled (
        import ./_theming.nix {
          inherit
            config
            lib
            pkgs
            scope
            matugen
            ;
        }
      ))
    ]
  );
}
