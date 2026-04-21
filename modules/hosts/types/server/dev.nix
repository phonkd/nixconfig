{
  inputs,
  lib,
  self,
  ...
}:
{
  flake.nixosModules.dev-hypervisor = {
    # imports = [

    # ];
    services.cockpit = {
      enable = true;
    };
  };
}
