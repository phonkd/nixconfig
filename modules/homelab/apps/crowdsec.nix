{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-crowdsec" = { config, pkgs, lib, noughtyLib, ... }:
    lib.mkIf (noughtyLib.hostHasTag "homelab-server") {
      # No phonkds.modules registry entry: the LAPI on 8081 is a
      # machine-to-machine REST API with no web UI, so a traefik route
      # would 404 forever. Dashboards live at app.crowdsec.net (console,
      # see enroll note below) and in Grafana ("CrowdSec Metrics" and
      # "CrowdSec Firewall Bouncer", modules/grafana-dashboards) via the
      # Alloy scrapes at the bottom of this file.
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
            # traefik.nix), and 201 reaches Loki over the tailnet as an
            # observability-sender. crowdsec tails the query below via
            # Loki's websocket API. labels.type feeds the s00-raw
            # non-syslog parser, which sets program="traefik" — the hub
            # traefik parser's filter matches on that.
            source = "loki";
            url = "http://100.64.0.4:3100";
            query = ''{service_name="traefik"}'';
            labels.type = "traefik";
            # Do NOT make startup depend on the tailnet being converged.
            # By default the datasource probes <url>/ready for
            # wait_for_ready (10s) before acquisition starts and a failure
            # there is FATAL — crowdsec exits with "loki is not ready:
            # context deadline exceeded". Loki is only reachable from 201
            # over the tailnet (100.64.0.4; the wg-obs 10.9.0.1 path does
            # not exist here — 201's wg0 is the client VPN on 10.8.0.0/24),
            # and the tailnet takes 1-2 minutes to reconverge after
            # activation restarts tailscaled. So every deploy was a coin
            # flip; it lost on 2026-08-14 19:05:36 and rolled back an
            # otherwise fine generation.
            #
            # no_ready_check skips that probe, so StreamingAcquisition
            # returns immediately and the start job succeeds. The tail is
            # not silently dropped: its background query loop retries with
            # exponential backoff, logging "loki is not available, will
            # retry for 10m0s" and then "loki is back after ...". Only
            # after max_failure_duration of CONTINUOUS failure does the
            # source give up and crowdsec exit — so a genuinely dead Loki
            # still surfaces, it just no longer punishes a 2-minute tailnet
            # reconvergence. (Upstream default is 30s, which is shorter than
            # the reconvergence itself.)
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
        # The module ships NO profiles (upstream warns about this at eval),
        # which means alerts never become ban decisions — detection worked
        # but local remediation was a no-op. This is upstream's stock
        # default_ip_remediation. No notifications: bans are watched in
        # Grafana instead (a per-ban Discord ping used to live here and was
        # dropped as noise).
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
        # (those UIs fire dozens of distinct non-static XHRs per page load) and
        # the firewall bouncer then DROPs the device in 201's INPUT chain for
        # the 4h profile duration above — silently, and ahead of traefik, so
        # every home.phonkd.net service simply hangs with no 403 and nothing in
        # the traefik log to look at. Measured on 2026-09-19: z14 arrived as
        # 100.64.0.17, earned a ban on 41 events, and sat in the
        # `crowdsec-blacklists-1` ipset while sabnzbd/sonarr/radarr/jellyfin all
        # timed out from that host. Port 22 kept working throughout, which is
        # what made it look like a routing or sing-box fault rather than a ban.
        #
        # s02-enrich runs before any scenario sees the event, so a whitelisted
        # source never fills a bucket in the first place — cheaper than a
        # postoverflow, and it keeps the alert list readable too.
        #
        # THE CIDR LIST IS A MIRROR, not an independent policy: it is the same
        # set as traefik's `ip-filter` allow-list and authelia's `internal`
        # network (see traefik.nix and authelia/authelia.nix, both of which
        # already carry a note about keeping the three in step). A source one of
        # them trusts and another does not is exactly the asymmetry that
        # produces a silent, un-debuggable failure. Change all three or none.
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

      # Both of these shell out to `cscli hub update`, which resolves and
      # fetches cdn-hub.crowdsec.net — and on 201 a name lookup needs dnsmasq
      # plus tailscaled, both of which activation restarts (see
      # modules/dns.nix for dns-online.service and the full explanation).
      #
      # crowdsec already carries `Wants=network-online.target` from nixpkgs,
      # but that target is reached on this host while the resolver is still
      # down: on 2026-08-14 19:04:29 crowdsec-setup ran ~100ms BEFORE dnsmasq
      # had finished starting and died with "Temporary failure in name
      # resolution". The setup script is `set -euo pipefail`, so the whole
      # ExecStartPre failed, switch-to-configuration exited 4 and deploy-rs
      # discarded the generation.
      #
      # Note `Restart=` does not help here — crowdsec already has
      # Restart=always/RestartSec=60 and the deploy still rolled back.
      # switch-to-configuration-ng sets exit 4 the instant a *start job* ends
      # with result `failed`, long before any restart timer runs. The only fix
      # is for the start not to fail.
      #
      # crowdsec-update-hub is timer-driven so it never aborts its own deploy,
      # but a unit left in `failed` aborts the NEXT one: switch-to-configuration
      # also lists every failed unit on the system after activation settles.
      systemd.services.crowdsec = {
        after = [ "dns-online.service" ];
        wants = [ "dns-online.service" ];
      };
      systemd.services.crowdsec-update-hub = {
        after = [ "dns-online.service" ];
        wants = [ "dns-online.service" ];
      };

      # autoUpdateService's crowdsec-update-hub oneshot runs as the
      # unprivileged crowdsec DynamicUser (NoNewPrivileges, PrivateUsers),
      # but upstream tacks on `ExecStartPost = systemctl reload
      # crowdsec.service` — which needs root/polkit and so dies with
      # "Access denied" (exit 4/NOPERMISSION), failing the whole unit even
      # though `cscli hub update` already succeeded. The reload is pointless
      # anyway: `hub update` only refreshes the local .index.json metadata,
      # it never upgrades an *installed* collection, so a live crowdsec has
      # nothing new to pick up. Drop the broken post-hook.
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

      # Ship crowdsec's and the bouncer's telemetry to Mimir: the nixpkgs
      # crowdsec module enables its Prometheus endpoint by default
      # (127.0.0.1:6060, level "full"), the bouncer's is switched on above,
      # but nothing scrapes either. Alloy (observability-sender, which this
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
