{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-crowdsec" = { config, pkgs, lib, noughtyLib, ... }:
    lib.mkIf (noughtyLib.hostHasTag "homelab-server") {
      phonkds.modules.crowdsec = {
        ip = "127.0.0.1";
        port = 8081;
        dashboard.enable = true;
        traefik = {
          enable = true;
          auth = false;
          domain = "crowdsec.int.w.phonkd.net";
          ipfilter = true;
        };
      };
      # --------------------------------------- #
      services.crowdsec = {
        enable = true;
        autoUpdateService = true;
        hub.collections = [
          "crowdsecurity/linux"
          "crowdsecurity/sshd"
          "crowdsecurity/traefik"
        ];
        localConfig.acquisitions = [
          {
            source = "journalctl";
            journalctl_filter = [ "_SYSTEMD_UNIT=sshd.service" ];
            labels.type = "syslog";
          }
          {
            source = "journalctl";
            # Traefik's own app log goes to a file (see traefik.nix); only
            # accessLog defaults to stdout, which is what lands in the
            # journal and what the crowdsecurity/traefik collection parses.
            journalctl_filter = [ "_SYSTEMD_UNIT=traefik.service" ];
            labels.type = "traefik";
          }
        ];
        # LAPI on 127.0.0.1:8081 (not 8080 - that's traefik's own api entrypoint
        # on this host, see phonkds-skill port allocation notes).
        settings.general.api.server = {
          enable = true;
          listen_uri = "127.0.0.1:8081";
        };
      };
    };
}
