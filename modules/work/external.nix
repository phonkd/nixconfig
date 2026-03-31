{ inputs, ... }:
let
  homeDir = if builtins.pathExists /Users/phonkd then "/Users/phonkd" else "/home/phonkd";
  bedagSetup = "${homeDir}/git/bedag-setup/home-manager";
in
{
  flake.homeModules.work-external-config =
    { pkgs, ... }:
    {
      imports = [
        "${bedagSetup}/ssh.nix"
        "${bedagSetup}/shell.nix"
        "${bedagSetup}/options.nix"
        "${bedagSetup}/gitconfig.nix"
      ];
    };
}
