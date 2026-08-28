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
            # Paperless has its own login, so authelia is here as the outer
            # lock, not as a sign-on: bypassed from `internal`, deny otherwise
            # (see the access_control rule naming this domain in authelia.nix).
            # Belt and braces with ipfilter, which blocks the same sources one
            # layer down.
            auth = true;
            domain = "paperless.home.phonkd.net";
            ipfilter = true;
          };
        };
      };

      services.paperless = {
        enable = true;
        address = "0.0.0.0";
        settings = {
          PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://paperless.home.phonkd.net";
          ALLOWED_HOSTS = [
            "paperless.home.phonkd.net"
          ];
          PAPERLESS_CORS_ALLOWED_ORIGINS = "https://paperless.home.phonkd.net";

          PAPERLESS_CORS_ALLOWED_HOSTS = "https://paperless.home.phonkd.net";
        };
      };
    };
}
