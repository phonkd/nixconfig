{ lib, ... }:
{
  # flake.darwinModules is declared by clan-core's flake module (as
  # lazyAttrsOf deferredModule); declaring it here too is an eval error.
  options.flake.homeModules = lib.mkOption {
    type = lib.types.lazyAttrsOf lib.types.raw;
    default = {};
  };
  config = {
    systems = [
      "x86_64-linux"
      "x86_64-darwin"
      "aarch64-linux"
      "aarch64-darwin"
    ];
  };
}
