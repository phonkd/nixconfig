# Routing entries for services that don't run on the homelab itself --
# external boxes (router, easyeffects on 203, oldblac PVE, etc.)
# Belongs on the reverse-proxy host because these are pure routing
# declarations consumed by traefik / dashboard / teleport.
{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules.homelab-orphans =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    lib.mkIf (noughtyLib.hostHasTag "reverse-proxy") {
      phonkds.modules = {
        traefik = {
          ip = "127.0.0.1";
          port = 8080;
          path = "/dashboard/";
          dashboard = {
            enable = true;
            icon = "traefik";
          };
          teleport = {
            enable = true;
            insecure = true;
            name = "traefik";
            scheme = "http";
          };
        };
        easyeffects = {
          ip = "192.168.1.203";
          port = 8085;
          dashboard = {
            enable = true;
            icon = "https://public.s3.w.phonkd.net/icons/ezfx.svg";
          };
          traefik = {
            enable = true;
            auth = true;
            domain = "easyeffects.int.w.phonkd.net";
            ipfilter = true;
            extraMiddlewares = [ "vnc-root-rewrite" ];
            transport = "insecureTransport";
          };
        };
        oldblac = {
          dashboard = {
            enable = true;
            icon = "sh-proxmox";
          };
          ip = "192.168.1.47";
          port = 8006;
          traefik = {
            enable = true;
            domain = "oldblac.int.phonkd.net";
            scheme = "https";
            transport = "insecureTransport";
            ipfilter = true;
            extraMiddlewares = [ "pve-headers" ];
          };
        };
        zyxel = {
          ip = "192.168.1.1";
          port = 443;
          dashboard = {
            enable = true;
            icon = "router";
          };
          traefik = {
            enable = true;
            domain = "1.int.phonkd.net";
            scheme = "https";
            transport = "insecureTransport";
            ipfilter = true;
          };
        };
      };
    };
}
