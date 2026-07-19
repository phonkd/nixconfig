{ self, inputs, ...}:
{
  flake.nixosModules.homelab-dashboard =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    let
      # Retrieve the central app configuration
      apps = config.phonkds.modules;

      # Show an app when the dashboard is enabled AND it's reachable: either
      # via a traefik route (enabled + domain) or a plain dashboard.link that
      # deep-links straight to the device (LAN-only tiles, not reverse-proxied).
      enabledApps = lib.filterAttrs (
        _: v:
        v.dashboard.enable
        && ((v.traefik.enable && v.traefik.domain != null) || v.dashboard.link != null)
      ) apps;

      # Convert the filtered apps into the homepage-dashboard service format
      # Structure: [ { "AppName" = { icon = "..."; href = "..."; ... }; } ]
      mkServiceList = lib.mapAttrsToList (
        name: app:
        let
          hasDomain = app.traefik.enable && app.traefik.domain != null;
          href = if app.dashboard.link != null then app.dashboard.link else "https://${app.traefik.domain}";
        in
        {
          "${name}" = {
            icon = if app.dashboard.icon != null then app.dashboard.icon else "${name}.png";
            inherit href;
            description = if hasDomain then app.traefik.domain else app.ip;
            # Green/red status dot. For proxied apps it goes through traefik so
            # it reflects what a browser would get; for direct-link tiles it
            # pings the device itself (no traefik involved).
            siteMonitor = if hasDomain then "https://${app.traefik.domain}" else href;
          }
          // lib.optionalAttrs (app.dashboard.widget != null) { widget = app.dashboard.widget; };
        }
      );

      # Two columns: live-stats cards left, plain links right.
      widgetApps = lib.filterAttrs (_: app: app.dashboard.widget != null) enabledApps;
      plainApps = lib.filterAttrs (_: app: app.dashboard.widget == null) enabledApps;

    in
    lib.mkIf (noughtyLib.hostHasTag "reverse-proxy") {
      services.homepage-dashboard = {
        enable = true;
        openFirewall = false; # Expose the dashboard port (default 8082)
        settings = {
          background = {
            image = "https://public.s3.w.phonkd.net/walls/20251117_071020.jpg";
            blur = "sm";
            saturate = "30";
            brightness = "30";
            opacity = "80";
          };
          cardblur = "md";
          headerStyle = "boxedWidgets";
          # These are top-level settings, not background options.
          fullWidth = true;
          statusStyle = "dot";
        };
        widgets = [
          {
            search = {
              provider = "duckduckgo";
              target = "_blank";
            };
          }
          {
            resources = {
              label = "System";
              cpu = true;
              memory = true;
              disk = "/";
            };
          }
          {
            resources = {
              label = "S3";
              disk = "/mnt/s3";
            };
          }
          {
            resources = {
              label = "Syncthing";
              disk = "/mnt/syncthing";
            };
          }
          {
            datetime = {
              text_size = "xl";
              format = {
                dateStyle = "long";
                timeStyle = "short";
              };
            };
          }
        ];
        services = [
          {
            "Monitored" = mkServiceList widgetApps;
          }
          {
            "Reverse proxied" = mkServiceList plainApps;
          }
        ];
        allowedHosts = config.phonkds.modules.homepage.traefik.domain;
      };

      phonkds.modules.homepage = {
        ip = "127.0.0.1";
        port = 8082;
        dashboard.enable = true;
        traefik = {
          enable = true;
          domain = "dashboard.w.phonkd.net";
          ipfilter = false;
          auth = true;
        };
      };
    };
}
