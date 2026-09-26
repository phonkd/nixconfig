{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-crowdsec" = { config, pkgs, lib, noughtyLib, ... }:
    lib.mkIf (noughtyLib.hostHasTag "homelab-server") {
      # No phonkds.modules registry entry: the LAPI on 8081 is a
      # machine-to-machine REST API with no web UI. Dashboards live at
      # app.crowdsec.net (console, see enroll note below) and in Grafana
      # ("CrowdSec Metrics"/"CrowdSec Firewall Bouncer") via the Alloy
      # scrapes at the bottom of this file.
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
            # traefik ships app+access logs to Loki via OTLP (traefik.nix), and
            # crowdsec tails the query below via Loki's websocket API.
            # labels.type feeds the s00-raw non-syslog parser, which sets
            # program="traefik" — the hub traefik parser's filter matches on
            # that.
            source = "loki";
            url = "http://100.64.0.4:3100";
            query = ''{service_name="traefik"}'';
            labels.type = "traefik";
            # Do NOT make startup depend on the tailnet being converged. By
            # default the datasource probes <url>/ready before acquisition
            # starts and a failure there is FATAL. The tailnet takes 1-2
            # minutes to reconverge after activation restarts tailscaled, so
            # every deploy was a coin flip; it lost on 2026-08-14 19:05:36 and
            # rolled back an otherwise fine generation. no_ready_check skips
            # the probe; the tail isn't silently dropped — it retries with
            # exponential backoff and only gives up (crowdsec exits) after
            # max_failure_duration of CONTINUOUS failure, so a genuinely dead
            # Loki still surfaces.
            no_ready_check = true;
            max_failure_duration = "10m";
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
        # enabled. capi: triggers `cscli capi register`, signing 201 up for
        # the community blocklists.
        settings.lapi.credentialsFile = "/var/lib/crowdsec/state/lapi-credentials.yaml";
        settings.capi.credentialsFile = "/var/lib/crowdsec/state/capi-credentials.yaml";
        # The module defaults console_path to a generated file in the nix
        # store, so `cscli console enroll` dies rewriting it ("read-only file
        # system"). Point it at the state dir instead (tmpfiles rule below
        # seeds it once); enroll manually after rebuild:
        #   sudo cscli console enroll <key from app.crowdsec.net>
        # (settings.console.tokenFile would automate this, but its setup
        # script is also broken: an inverted existence check still hits the
        # store path.)
        settings.general.api.server.console_path = "/var/lib/crowdsec/state/console.yaml";
        # The module ships NO profiles (upstream warns about this at eval),
        # so alerts never become ban decisions without one. This is
        # upstream's stock default_ip_remediation; bans are watched in
        # Grafana instead of via notifications.
        localConfig.profiles = [
          {
            name = "default_ip_remediation";
            filters = [ ''Alert.Remediation == true && Alert.GetScope() == "Ip"'' ];
            decisions = [
              {
                type = "ban";
                duration = "4h";
              }
            ];
            on_success = "break";
          }
        ];

        # Our own devices must never be banned. Without this, browsing an *arr
        # web UI over the tailnet trips crowdsecurity/http-crawl-non_statics
        # (dozens of non-static XHRs per page load), and the firewall bouncer
        # DROPs the device in 201's INPUT chain — silently, ahead of traefik,
        # so every home.phonkd.net service hangs with no 403 and nothing in
        # the traefik log. Measured 2026-09-19: z14 (100.64.0.17) earned a ban
        # on 41 events and sat in `crowdsec-blacklists-1` while
        # sabnzbd/sonarr/radarr/jellyfin all timed out; port 22 kept working,
        # which is what made it look like a routing fault rather than a ban.
        #
        # s02-enrich runs before any scenario sees the event, so a whitelisted
        # source never fills a bucket in the first place.
        #
        # THE CIDR LIST IS A MIRROR, not an independent policy: same set as
        # traefik's `ip-filter` allow-list and authelia's `internal` network
        # (traefik.nix, authelia/authelia.nix — both note keeping the three in
        # step). Change all three or none.
        localConfig.parsers.s02Enrich = [
          {
            name = "homelab/trusted-networks";
            description = "Whitelist the tailnet and the home/homelab LANs";
            whitelist = {
              reason = "trusted homelab networks — mirrors traefik ip-filter";
              cidr = [
                "192.168.3.0/24"
                "192.168.1.0/24"
                "192.168.2.0/24"
                "10.8.0.0/16"
                # The headscale tailnet: single-user, headscale-authenticated,
                # and holds only our own devices. This is the entry that
                # actually matters — away from the LAN every one of our clients
                # reaches 201 as 100.64.0.x, so it is the range all of our own
                # browsing arrives from.
                "100.64.0.0/10"
              ];
            };
          }
        ];
      };

      # Both shell out to `cscli hub update`, which needs DNS -- see
      # modules/dns.nix's dns-online.service for the full race explanation.
      # crowdsec-setup ran ~100ms before dnsmasq finished starting on
      # 2026-08-14 19:04:29 and died ("Temporary failure in name resolution"),
      # failing its ExecStartPre and rolling back an otherwise fine deploy.
      # `Restart=` doesn't help: switch-to-configuration-ng exits 4 the
      # instant a start job fails, before any restart timer runs.
      systemd.services.crowdsec = {
        after = [ "dns-online.service" ];
        wants = [ "dns-online.service" ];
      };
      systemd.services.crowdsec-update-hub = {
        after = [ "dns-online.service" ];
        wants = [ "dns-online.service" ];
      };

      # autoUpdateService's crowdsec-update-hub oneshot runs as the
      # unprivileged crowdsec DynamicUser, but upstream tacks on
      # `ExecStartPost = systemctl reload crowdsec.service` — needs
      # root/polkit and dies "Access denied", failing the unit even though
      # `hub update` already succeeded. Also pointless: `hub update` only
      # refreshes local metadata, never upgrades an installed collection.
      # Drop the broken post-hook.
      systemd.services.crowdsec-update-hub.serviceConfig.ExecStartPost = lib.mkForce [ ];

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
      # registerBouncer is deliberately OFF, twice broken as of nixpkgs 26.05:
      # its oneshot pairs DynamicUser with StateDirectory=crowdsec, which
      # migrates /var/lib/crowdsec into root-only /var/lib/private and bricks
      # crowdsec itself (mkdir EACCES on every restart); and its script calls
      # raw cscli without -c, expecting a config.yaml this module never
      # writes. Instead register the API key (lives in sops) once by hand:
      #   sudo cscli bouncers add firewall-bouncer \
      #     --key "$(sudo cat /run/secrets/crowdsec-bouncer-api-key)"
      sops.secrets."crowdsec-bouncer-api-key" = { };
      services.crowdsec-firewall-bouncer = {
        enable = true;
        registerBouncer.enable = false;
        secrets.apiKeyPath = config.sops.secrets."crowdsec-bouncer-api-key".path;
        # Without this nothing listens on :60601 (checked on 201,
        # 2026-09-11) — the nixpkgs module writes only what's set here. The
        # fw_bouncer_* series (banned IPs, dropped packets/bytes per origin)
        # feed the "CrowdSec Firewall Bouncer" Grafana dashboard.
        settings.prometheus = {
          enabled = true;
          listen_addr = "127.0.0.1";
          listen_port = "60601";
        };
      };

      # Ship crowdsec's and the bouncer's telemetry to Mimir: both expose a
      # Prometheus endpoint but nothing scrapes them by default. Alloy loads
      # every /etc/alloy/*.alloy file with cross-file references working, so
      # forward straight to the remote_write in config.alloy — same pattern
      # as pve.alloy in observability.nix. Logs need no wiring: alloy already
      # ships the whole journal to Loki.
      environment.etc."alloy/crowdsec.alloy".text = ''
        prometheus.scrape "crowdsec" {
          targets = [{
            "__address__" = "127.0.0.1:6060",
          }]
          job_name   = "crowdsec"
          forward_to = [prometheus.remote_write.nixvms.receiver]
        }

        prometheus.scrape "crowdsec_firewall_bouncer" {
          targets = [{
            "__address__" = "127.0.0.1:60601",
          }]
          job_name   = "crowdsec-firewall-bouncer"
          forward_to = [prometheus.remote_write.nixvms.receiver]
        }
      '';
    };
}
