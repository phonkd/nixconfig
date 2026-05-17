{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-paperless" = { config, pkgs, lib, noughtyLib, ... }:
    lib.mkIf (noughtyLib.hostHasTag "homelab-server") {
      phonkds.modules = {
        paperless = {
          ip = "127.0.0.1";
          port = 28981;
          dashboard = {
            enable = true;
            icon = "paperless";
          };
          traefik = {
            enable = true;
            auth = false;
            domain = "paperless.w.phonkd.net";
            ipfilter = true;
          };
        };
      };

      services.paperless = {
        enable = true;
        address = "0.0.0.0";
        settings = {
          PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://paperless.w.phonkd.net";
          ALLOWED_HOSTS = [
            "paperless.w.phonkd.net"
          ];
          PAPERLESS_CORS_ALLOWED_ORIGINS = "https://paperless.w.phonkd.net";

          PAPERLESS_CORS_ALLOWED_HOSTS = "https://paperless.w.phonkd.net";
        };
      };
    };
}
