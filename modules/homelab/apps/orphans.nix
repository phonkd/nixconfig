# Routing entries for services that don't run on the homelab itself --
# external boxes (router, oldblac PVE, etc.)
# Belongs on the reverse-proxy host because these are pure routing
# declarations consumed by traefik / dashboard.
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
        };
        oldblac = {
          dashboard = {
            enable = true;
            icon = "sh-proxmox";
          };
          ip = "192.168.3.47";
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
        unifi = {
          ip = "192.168.1.1";
          port = 443;
          dashboard = {
            enable = true;
            icon = "router";
          };
        };
        home-assistant = {
          ip = "192.168.1.115";
          port = 8123;
          dashboard = {
            enable = true;
            icon = "home-assistant";
          };
          traefik = {
            enable = true;
            domain = "home.phonkd.net";
            auth = false;
            ipfilter = true;
          };
        };
        # Direct-link tiles only -- deliberately NOT reverse-proxied. They
        # render via dashboard.link (see homelab-dashboard) rather than a
        # traefik route, so they just deep-link to the device on the LAN.
        jetkvm = {
          ip = "192.168.1.39";
          port = 80;
          dashboard = {
            enable = true;
            icon = "sh-jetkvm";
            link = "http://192.168.1.39";
          };
        };
        mystrom = {
          ip = "192.168.1.102";
          port = 80;
          dashboard = {
            enable = true;
            # No selfh.st/dashboard-icons entry for myStrom -> generic MDI plug.
            icon = "mdi-power-socket-eu";
            link = "http://192.168.1.102";
          };
        };
        grafana = {
          # Reached over the tailnet now, not the wg-obs tunnel — traefik on
          # 201 is itself an enrolled node. See plans/retire-wg-obs.md.
          ip = "100.64.0.4";
          port = 3000;
          dashboard.enable = true;
          traefik = {
            enable = true;
            domain = "grafana.phonkd.net";
            auth = false;
            ipfilter = false;
          };
        };
      };
    };
}
