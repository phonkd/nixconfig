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
        # The module defaults console_path to a generated file in the nix
        # store, so `cscli console enroll` dies rewriting it ("read-only
        # file system"). Point it at the state dir instead; the tmpfiles
        # rule below seeds it once with the module's defaults. Enroll
        # manually after rebuild (then accept the machine on the site):
        #   sudo cscli console enroll <key from app.crowdsec.net>
        # (settings.console.tokenFile would automate this, but its setup
        # script is broken too: the existence check on the token file is
        # inverted, and enroll would still hit the store path.)
        settings.general.api.server.console_path = "/var/lib/crowdsec/state/console.yaml";
      };

      # cscli loads the whole config on EVERY invocation and hard-fails if
      # the CAPI credentials file above doesn't exist yet - which deadlocks
      # the setup script's own `machine add` step, since `capi register`
      # (the thing that writes the file) only runs after it. Upstream debs
      # ship this file empty for exactly this reason.
      systemd.tmpfiles.settings."11-crowdsec-homelab" = {
        "/var/lib/crowdsec/state/capi-credentials.yaml".f = {
          user = config.services.crowdsec.user;
          group = config.services.crowdsec.group;
          mode = "0600";
        };
        # Seed a writable console.yaml (see console_path above). "C" only
        # copies when the target doesn't exist, so an enrolled config is
        # never clobbered. Content mirrors the module's defaults.
        "/var/lib/crowdsec/state/console.yaml".C = {
          argument = toString (pkgs.writeText "console-defaults.yaml" ''
            share_manual_decisions: false
            share_custom: false
            share_tainted: false
            share_context: false
          '');
          user = config.services.crowdsec.user;
          group = config.services.crowdsec.group;
          mode = "0600";
        };
      };

      # Enforcement: drops LAPI-banned IPs in the INPUT chain, ahead of
      # traefik. api_url follows listen_uri above; mode resolves to
      # "iptables" because 201 doesn't run nftables.
      #
      # registerBouncer is deliberately OFF, twice broken as of
      # nixpkgs 26.05: its oneshot pairs DynamicUser with
      # StateDirectory=crowdsec, which migrates /var/lib/crowdsec into
      # root-only /var/lib/private and bricks the crowdsec service itself
      # (mkdir EACCES on every restart); and its script calls raw cscli
      # without -c, expecting an /etc/crowdsec/config.yaml this module
      # never writes. Instead the API key lives in sops; register it once
      # on the host after the first successful crowdsec start:
      #   sudo cscli bouncers add firewall-bouncer \
      #     --key "$(sudo cat /run/secrets/crowdsec-bouncer-api-key)"
      # Ship crowdsec's own telemetry to Mimir: the nixpkgs module enables
      # the Prometheus endpoint by default (127.0.0.1:6060, level "full"),
      # but nothing scrapes it. Alloy (observability-sender, which this
      # host also is) loads every /etc/alloy/*.alloy file and cross-file
      # references work, so forward straight to the remote_write defined
      # in config.alloy — same pattern as pve.alloy in observability.nix.
      # Logs need no wiring: alloy already ships the whole journal to Loki.
      environment.etc."alloy/crowdsec.alloy".text = ''
        prometheus.scrape "crowdsec" {
          targets = [{
            "__address__" = "127.0.0.1:6060",
          }]
          job_name   = "crowdsec"
          forward_to = [prometheus.remote_write.nixvms.receiver]
        }
      '';

      sops.secrets."crowdsec-bouncer-api-key" = { };
      services.crowdsec-firewall-bouncer = {
        enable = true;
        registerBouncer.enable = false;
        secrets.apiKeyPath = config.sops.secrets."crowdsec-bouncer-api-key".path;
      };
    };
}
