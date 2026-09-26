{ inputs, ... }:
let
  # The bedag work config is a separate, private repo consumed by absolute path
  # rather than as a flake input. `builtins.pathExists` is an impure eval-time
  # probe, so this only resolves for a build happening ON the machine it
  # targets -- fine, since both consumers (the Mac and z14) build locally.
  homeDir = if builtins.pathExists /Users/phonkd then "/Users/phonkd" else "/home/phonkd";
  bedagSetup = "${homeDir}/git/bedag-setup/home-manager";
in
{
  flake.homeModules.work-external-config =
    { pkgs, ... }:
    {
      # NB: no jjconfig.nix -- it doesn't exist in the bedag-setup checkout, and
      # importing it fails eval on any host without an untracked local copy.
      imports = [
        "${bedagSetup}/ssh.nix"
        "${bedagSetup}/shell.nix"
        "${bedagSetup}/options.nix"
        "${bedagSetup}/gitconfig.nix"
        "${bedagSetup}/ica-proxy.nix"
        "${bedagSetup}/tools.nix"
      ];
    };
}
