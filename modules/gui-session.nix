# Shared Home Manager session used by Linux compositors.
{ self, inputs, ... }:
{
  flake.homeModules.linux-gui-session =
    import ./gui-session/_home.nix { inherit self inputs; };
}
