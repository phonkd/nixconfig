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
            # Traefik logs come from Loki rather than the local journal:
            # traefik already ships app+access logs to Loki via OTLP (see
            # traefik.nix), and 201 reaches Loki over wg-obs as an
            # observability-sender. crowdsec tails the query below via
            # Loki's websocket API. labels.type feeds the s00-raw
            # non-syslog parser, which sets program="traefik" — the hub
            # traefik parser's filter matches on that.
            source = "loki";
            url = "http://10.9.0.1:3100";
            query = ''{service_name="traefik"}'';
            labels.type = "traefik";
          }
        ];
        # LAPI on 127.0.0.1:8081 (not 8080 - that's traefik's own api entrypoint
        # on this host, see phonkds-skill port allocation notes).
        settings.general.api.server = {
          enable = true;
          listen_uri = "127.0.0.1:8081";
        };
        # Runtime-generated credentials, written by the module's setup script
        # into crowdsec's own state dir (not sops - they don't exist until
        # first start). lapi: `cscli machine add --auto` for the local agent;
        # eval FAILS with a null-coerce error if unset while api.server is
        # enabled. capi: triggers `cscli capi register`, which signs 201 up
        # for the community blocklists.
        settings.lapi.credentialsFile = "/var/lib/crowdsec/state/lapi-credentials.yaml";
        settings.capi.credentialsFile = "/var/lib/crowdsec/state/capi-credentials.yaml";
      };

      # Enforcement: drops LAPI-banned IPs in the INPUT chain, ahead of
      # traefik. Everything else is derived by the nixpkgs module: api_url
      # follows listen_uri above, registration happens automatically against
      # the local crowdsec (cscli bouncers add), and mode resolves to
      # "iptables" because 201 doesn't run nftables.
      services.crowdsec-firewall-bouncer.enable = true;
    };
}
