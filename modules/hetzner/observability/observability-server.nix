{ self, inputs, ...}:
{
  flake.nixosModules.observability-server =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    {
      config = lib.mkIf (noughtyLib.hostHasTag "observability-server") {
        services.cortex-metrics = {
          enable = true;
        };
      };
    };
}
