{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-vaultwarden" = { config, pkgs, lib, noughtyLib, ... }:
    lib.mkIf (noughtyLib.hostHasTag "homelab-server") {
      phonkds.modules.vaultwarden = {
          ip = "127.0.0.1";
          port = 8000;
          dashboard.enable = true;
          traefik = {
            enable = true;
            domain = "vw.w.phonkd.net";
            auth = false;
            ipfilter = false;
          };
        };
        # --------------------------------------- #
        services.vaultwarden = {
          enable = true;
          config = {
            DOMAIN = "https://${config.phonkds.modules.vaultwarden.traefik.domain}";
            ROCKET_ADDRESS = "127.0.0.1";
            ROCKET_PORT = 8000;
            # Allow Bitwarden clients to opt into HTTP Basic Auth autofill.
            EXPERIMENTAL_CLIENT_FEATURE_FLAGS = "enable-basic-auth-response";
            #SIGNUPS_ALLOWED = false;
          };
        };
        networking.firewall.allowedTCPPorts = [ 8000 ];
    };
}
