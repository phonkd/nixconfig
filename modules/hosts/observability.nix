{ ... }:
{
  flake.nixosModules."observability" =
    {
      config,
      pkgs,
      lib,
      modulesPath,
      ...
    }:
    {
      imports = [
        (modulesPath + "/profiles/qemu-guest.nix")
      ];
      config = lib.mkIf (config.noughty.host.name == "observability") {
        networking.hostName = "observability";
      };
    };
}
