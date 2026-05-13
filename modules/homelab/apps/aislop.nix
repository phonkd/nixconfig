{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-aislop" = { config, pkgs, lib, ... }:
    {
      phonkds.modules.aislop = {
        ip = "127.0.0.1";
        port = 11111;
        dashboard.enable = true;
        traefik = {
          enable = true;
          domain = "openwebui.int.w.phonkd.net";
          auth = false;
          ipfilter = true;
        };
      };
      services.openwebui = {
        enable = true;
        port = 11111;
        host = "openwebui.int.w.phonkd.net";
      };
    };
}
