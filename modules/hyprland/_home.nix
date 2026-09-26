# Hyprland, Home Manager half: the actual session. Self-gates on osConfig,
# so it is inert if imported on a host without the tag.
#
# The shared scope is built once and handed to every section, so each stays
# an ordinary attrset of Home Manager options.
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
  # Unconditional: the module only declares options, and all of its config
  # hangs off `programs.caelestia.enable` in _shell.nix, itself inside
  # `lib.mkIf enabled` -- so a host without the tag gets no shell.
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
