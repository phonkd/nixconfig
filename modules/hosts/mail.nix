{ ... }:
{
  flake.nixosModules."ext-mail" =
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
      config = lib.mkIf (config.noughty.host.name == "ext-mail") {
        networking.hostName = "ext-mail";
      };
    };
}
