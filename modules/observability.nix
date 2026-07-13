{
  self,
  inputs,
  ...
}:
{
  # ───────────────────────────────────────────────────────────────────────────
  # Central observability stack (Hetzner VM, tag "observability-server")
  #
  #   Loki      — log aggregation      (HTTP 3100)
  #   Mimir     — long-term metrics    (HTTP 9009, Prometheus-compatible)
  #   Grafana   — dashboards / explore (HTTP 3000)
  #
  # Reachability: services bind on all interfaces but the firewall only opens
  # their ports on the WireGuard interface (see observability-vpn below). Home
  # VMs reach Loki/Mimir over a site-to-site VPN terminated on the user's
  # router, so nothing here is exposed on the public internet.
  # ───────────────────────────────────────────────────────────────────────────
  flake.nixosModules.observability-server =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    let
      lokiHttpPort = 3100;
      lokiGrpcPort = 9096;
      mimirHttpPort = 9009;
      mimirGrpcPort = 9095;
      grafanaPort = 3000;
    in
    lib.mkIf (noughtyLib.hostHasTag "observability-server") {
      # Override the hetzner-vm default UUIDs — the observability disk has
      # different UUIDs (changed when a private network interface was attached).
      fileSystems."/" = lib.mkForce {
        device = "/dev/disk/by-uuid/5781b336-4eff-4fed-8f60-20c827635786";
        fsType = "ext4";
      };
      fileSystems."/efi" = lib.mkForce {
        device = "/dev/disk/by-uuid/E416-7905";
        fsType = "vfat";
        options = [ "fmask=0077" "dmask=0077" ];
      };

      # ── Loki ────────────────────────────────────────────────────────────────
      # Single-binary, filesystem-backed. State lives under /var/lib/loki.
      services.loki = {
        enable = true;
        configuration = {
          auth_enabled = false;
          analytics.reporting_enabled = false;

          server = {
            http_listen_port = lokiHttpPort;
            grpc_listen_port = lokiGrpcPort;
            log_level = "warn";
          };

          common = {
            instance_addr = "127.0.0.1";
            path_prefix = "/var/lib/loki";
            replication_factor = 1;
            ring.kvstore.store = "inmemory";
            storage.filesystem = {
              chunks_directory = "/var/lib/loki/chunks";
              rules_directory = "/var/lib/loki/rules";
            };
          };

          schema_config.configs = [
            {
              from = "2024-01-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];

          # Keep logs forever for now; tune once disk usage is understood.
          limits_config = {
            retention_period = "0s";
            reject_old_samples = false;
            allow_structured_metadata = true;
          };
        };
      };

      # ── Mimir ───────────────────────────────────────────────────────────────
      # Monolithic single-node ("target = all") with filesystem block storage.
      # Modelled on Grafana's canonical single-process example; state under
      # /var/lib/mimir.
      services.mimir = {
        enable = true;
        configuration = {
          multitenancy_enabled = false;
          usage_stats.enabled = false;
          # "all" deliberately excludes the alertmanager and overrides-exporter
          # components — Mimir won't start the Alertmanager (or expose it on
          # the admin page) unless it's opted into the target list explicitly.
          target = "all,alertmanager";

          server = {
            http_listen_port = mimirHttpPort;
            grpc_listen_port = mimirGrpcPort;
            log_level = "warn";
          };

          blocks_storage = {
            backend = "filesystem";
            filesystem.dir = "/var/lib/mimir/blocks";
            bucket_store.sync_dir = "/var/lib/mimir/tsdb-sync";
            tsdb.dir = "/var/lib/mimir/tsdb";
          };

          compactor = {
            data_dir = "/var/lib/mimir/compactor";
            sharding_ring.kvstore.store = "memberlist";
          };

          distributor.ring = {
            instance_addr = "127.0.0.1";
            kvstore.store = "memberlist";
          };

          ingester.ring = {
            instance_addr = "127.0.0.1";
            kvstore.store = "memberlist";
            replication_factor = 1;
          };

          store_gateway.sharding_ring.replication_factor = 1;

          # "filesystem" (not "local") so Mimir's own DynamicUser owns the whole
          # tree it writes into. The ruler config API (used by mimirtool, and by
          # the mimir-rules-sync service below) needs to create/update rule-group
          # objects at runtime; "local" only supports reading rule files placed
          # by an external process and 500s on API writes because the directory
          # ends up root-owned (created by an activation script) while Mimir
          # runs as a dynamic, non-root service user that can't write into it.
          ruler_storage = {
            backend = "filesystem";
            filesystem.dir = "/var/lib/mimir/ruler-storage";
          };

          # Tell the ruler where to send firing alerts — Mimir's own bundled
          # Alertmanager (included in target=all), reached on the same port.
          ruler.alertmanager_url = "http://127.0.0.1:${toString mimirHttpPort}/alertmanager";

          # Storage for the Alertmanager's tenant config (contact points,
          # notification policies, e.g. a Discord webhook receiver). Configured
          # entirely through Grafana's Alerting UI once pointed at the
          # "Mimir Alertmanager" datasource below — no receiver config or
          # secrets need to live in this repo.
          alertmanager_storage = {
            backend = "filesystem";
            filesystem.dir = "/var/lib/mimir/alertmanager-storage";
          };
        };
      };

      # ── Grafana ─────────────────────────────────────────────────────────────
      # Datasources provisioned declaratively. Reached over the VPN on :3000.
      services.grafana = {
        enable = true;

        settings = {
          server = {
            http_addr = "0.0.0.0";
            http_port = grafanaPort;
          };
          analytics.reporting_enabled = false;
          # nixpkgs 26.05 dropped the built-in default secret_key. Provided via
          # sops (global server secrets file) and read through Grafana's file
          # provider so nothing secret lands in the repo.
          security.secret_key = "$__file{${config.sops.secrets."grafana-secret-key".path}}";
        };

        provision = {
          enable = true;
          datasources.settings.datasources = [
            {
              name = "Mimir";
              type = "prometheus";
              access = "proxy";
              # Mimir serves the Prometheus query API under /prometheus.
              url = "http://127.0.0.1:${toString mimirHttpPort}/prometheus";
              isDefault = true;
            }
            {
              name = "Mimir Alertmanager";
              type = "alertmanager";
              access = "proxy";
              # No "/alertmanager" suffix: Grafana's "mimir" implementation
              # adds the right prefix itself per-operation — the root address
              # for tenant config CRUD (GET/POST /api/v1/alerts, Mimir's
              # Cortex-style config API), vs. "/alertmanager/api/v2/..." for
              # browsing alerts/silences. Pointing this at .../alertmanager
              # directly instead routes config requests into the embedded
              # Alertmanager engine's own (deprecated, v1-removed) API and
              # breaks the config editor — verified live against the server.
              url = "http://127.0.0.1:${toString mimirHttpPort}";
              jsonData.implementation = "mimir";
            }
            {
              name = "Loki";
              type = "loki";
              access = "proxy";
              url = "http://127.0.0.1:${toString lokiHttpPort}";
            }
          ];
        };
      };

      # Grafana's secret_key, decrypted to /run/secrets and owned by grafana.
      # Lives in the global server secrets file (server-sops defaultSopsFile).
      # Add the value with:
      #   sops modules/homelab/global-secrets/secret.yaml
      #   # add a line:  grafana-secret-key: <openssl rand -base64 32>
      sops.secrets."grafana-secret-key".owner = "grafana";

      # Expose the stack ONLY on the WireGuard interface — never publicly.
      networking.firewall.interfaces.wg-obs.allowedTCPPorts = [
        grafanaPort
        lokiHttpPort
        mimirHttpPort
      ];

      # ── Mimir alerting rules ─────────────────────────────────────────────────
      # Pushed into Mimir's ruler via its config API (mimirtool, bundled with
      # the mimir package) rather than dropped as a raw file — the "filesystem"
      # ruler_storage backend above doesn't scan a directory the way the old
      # "local" backend did, and API-driven writes are also what lets other
      # tools (e.g. Hermes) create/update rules at runtime the same way.
      # Tenant is "anonymous" (single-tenant mode, multitenancy_enabled = false).
      systemd.services.mimir-rules-sync =
        let
          rulesFile = pkgs.writeText "homelab.yaml" ''
            groups:
              - name: instance
                interval: 1m
                rules:
                  # A dead host never produces up == 0: each host scrapes
                  # itself via Alloy and remote_writes the result, so when the
                  # host dies the series just stops existing (verified during
                  # the 2026-07-06 Proxmox outage — all five VMs vanished
                  # without a single 0 sample). The second clause catches
                  # that: series had samples within 24h but has none now.
                  # After 24h of continuous downtime the alert self-resolves
                  # as the series ages out of the lookback window.
                  - alert: InstanceDown
                    expr: >
                      up{job="integrations/unix"} == 0
                      or
                      (max_over_time(up{job="integrations/unix"}[24h]) unless up{job="integrations/unix"})
                    for: 5m
                    labels:
                      severity: critical
                    annotations:
                      summary: "{{ $labels.instance }} is unreachable"
                      description: "{{ $labels.instance }} has stopped reporting metrics (host down, or its exporter/remote_write pipeline is broken)."

              - name: cpu
                interval: 1m
                rules:
                  - alert: HighCPU
                    expr: >
                      100 - (avg by (instance) (irate(node_cpu_seconds_total{mode="idle",job="integrations/unix"}[5m])) * 100) > 90
                    for: 10m
                    labels:
                      severity: warning
                    annotations:
                      summary: "High CPU on {{ $labels.instance }}"
                      description: 'CPU above 90% for 10 min (current: {{ $value | printf "%.1f" }}%).'
                  - alert: HighLoadAverage
                    expr: >
                      node_load1{job="integrations/unix"}
                      / count without(cpu, mode) (node_cpu_seconds_total{mode="idle",job="integrations/unix"}) > 3
                    for: 10m
                    labels:
                      severity: warning
                    annotations:
                      summary: "High load on {{ $labels.instance }}"
                      description: '1m load is {{ $value | printf "%.2f" }}x the CPU count.'

              - name: memory
                interval: 1m
                rules:
                  - alert: HighMemory
                    expr: >
                      (1 - node_memory_MemAvailable_bytes{job="integrations/unix"}
                           / node_memory_MemTotal_bytes{job="integrations/unix"}) * 100 > 90
                    for: 10m
                    labels:
                      severity: warning
                    annotations:
                      summary: "High memory on {{ $labels.instance }}"
                      description: 'Memory usage is {{ $value | printf "%.1f" }}%.'
                  - alert: CriticalMemory
                    expr: >
                      (1 - node_memory_MemAvailable_bytes{job="integrations/unix"}
                           / node_memory_MemTotal_bytes{job="integrations/unix"}) * 100 > 97
                    for: 5m
                    labels:
                      severity: critical
                    annotations:
                      summary: "Critical memory on {{ $labels.instance }}"
                      description: 'Memory is {{ $value | printf "%.1f" }}% — OOM imminent.'

              - name: disk
                interval: 1m
                rules:
                  - alert: DiskSpaceWarning
                    expr: >
                      (1 - node_filesystem_avail_bytes{job="integrations/unix",fstype!~"tmpfs|devtmpfs|overlay|squashfs|fuse.*"}
                           / node_filesystem_size_bytes{job="integrations/unix",fstype!~"tmpfs|devtmpfs|overlay|squashfs|fuse.*"}) * 100 > 80
                    for: 5m
                    labels:
                      severity: warning
                    annotations:
                      summary: "Disk {{ $labels.mountpoint }} filling on {{ $labels.instance }}"
                      description: '{{ $labels.mountpoint }} is {{ $value | printf "%.1f" }}% full.'
                  - alert: DiskSpaceCritical
                    expr: >
                      (1 - node_filesystem_avail_bytes{job="integrations/unix",fstype!~"tmpfs|devtmpfs|overlay|squashfs|fuse.*"}
                           / node_filesystem_size_bytes{job="integrations/unix",fstype!~"tmpfs|devtmpfs|overlay|squashfs|fuse.*"}) * 100 > 95
                    for: 5m
                    labels:
                      severity: critical
                    annotations:
                      summary: "Disk {{ $labels.mountpoint }} nearly full on {{ $labels.instance }}"
                      description: '{{ $labels.mountpoint }} is {{ $value | printf "%.1f" }}% full.'
                  - alert: DiskWillFillIn24h
                    expr: >
                      predict_linear(
                        node_filesystem_avail_bytes{job="integrations/unix",fstype!~"tmpfs|devtmpfs|overlay|squashfs|fuse.*"}[6h],
                        86400
                      ) < 0
                    for: 1h
                    labels:
                      severity: warning
                    annotations:
                      summary: "{{ $labels.mountpoint }} on {{ $labels.instance }} will fill in 24h"
                      description: "Based on last 6h growth, {{ $labels.mountpoint }} will run out within 24 hours."

              - name: systemd
                interval: 1m
                rules:
                  - alert: SystemdServiceFailed
                    expr: node_systemd_unit_state{job="integrations/unix",state="failed"} == 1
                    for: 2m
                    labels:
                      severity: critical
                    annotations:
                      summary: "Service {{ $labels.name }} failed on {{ $labels.instance }}"
                      description: "systemd unit {{ $labels.name }} is in failed state on {{ $labels.instance }}."
        '';
        in
        {
          description = "Push homelab alert rules into Mimir's ruler via the API";
          after = [ "mimir.service" ];
          wants = [ "mimir.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            RuntimeDirectory = "mimir-rules-sync";
          };
          # Mimir takes a few seconds to become ready after (re)starting, so
          # retry rather than racing it once and failing the unit.
          #
          # `rules sync` is a mirror operation: it deletes any namespace not
          # present in the given files, tenant-wide. rulesFile lives at a
          # hashed nix store path, so passing it directly would make the
          # namespace name (mimirtool derives it from the filename) churn
          # every time the rule content changes, and — worse — a bare `sync`
          # would wipe out any other namespace in this tenant, including ones
          # a tool like Hermes creates dynamically via the same API. Copying
          # to a fixed filename fixes the namespace as "homelab", and
          # --namespaces=homelab scopes the sync to only that namespace so
          # everything else is left alone. Verified live against the
          # observability server: an unscoped sync deleted an unrelated
          # namespace it had no business touching.
          script = ''
            install -m 0644 ${rulesFile} /run/mimir-rules-sync/homelab.yaml
            for i in $(seq 1 30); do
              if ${config.services.mimir.package}/bin/mimirtool rules sync /run/mimir-rules-sync/homelab.yaml \
                --address=http://127.0.0.1:${toString mimirHttpPort} --id=anonymous --namespaces=homelab; then
                exit 0
              fi
              sleep 2
            done
            echo "mimir-rules-sync: gave up after 30 attempts" >&2
            exit 1
          '';
        };
    };

  # ───────────────────────────────────────────────────────────────────────────
  # WireGuard endpoint for the observability server (tag "observability-server")
  #
  # The user's home router holds the other end of a site-to-site tunnel, so the
  # single peer below is the *router*, and its allowedIPs cover the whole home
  # LAN. Every home VM then routes its Loki/Mimir traffic through the router and
  # over this tunnel — no per-VM WireGuard config required.
  #
  #   Server (this host): 10.9.0.1/24
  #   Router peer:        10.9.0.2/32  + home subnet(s) in allowedIPs
  #
  # Key bootstrap (run once on the server):
  #   mkdir -p /etc/wireguard
  #   (umask 077; wg genkey > /etc/wireguard/obs-private.key)
  #   wg pubkey < /etc/wireguard/obs-private.key   # → server pubkey for the router
  # ───────────────────────────────────────────────────────────────────────────
  flake.nixosModules.observability-vpn =
    {
      pkgs,
      lib,
      noughtyLib,
      config,
      ...
    }:
    lib.mkIf (noughtyLib.hostHasTag "observability-server") {
      networking.wireguard.interfaces.wg-obs = {
        privateKeyFile = "/etc/wireguard/obs-private.key";
        listenPort = 51821;
        ips = [ "10.9.0.1/24" ];

        peers = [
          # The home router (10.3.0.0 is its VPN-client "tunnel IP"). allowedIPs
          # carries every RFC1918 range so any home VM, on any private subnet,
          # can reach the stack and have replies routed back through the tunnel.
          # NB: 172.16.0.0/12 overlaps Docker's default 172.17.0.0/16 bridge, but
          # Docker's more-specific route wins so container networking is fine.
          {
            publicKey = "REU5RaPQY5YyPyfVNDpnRzqZ8vy2kNTQVBKN9++bm18=";
            allowedIPs = [
              "10.0.0.0/8"
              "172.16.0.0/12"
              "192.168.0.0/16"
            ];
          }
        ];
      };

      # Only the WireGuard handshake port is reachable publicly.
      networking.firewall.allowedUDPPorts = [ 51821 ];
    };

  # ───────────────────────────────────────────────────────────────────────────
  # Sender side (tag "observability-sender") — stub.
  #
  # Home VMs will ship logs/metrics to the central stack from here (Grafana
  # Alloy / Promtail → Loki, Prometheus remote_write / Alloy → Mimir).
  # Wired up later — no host carries this tag yet, so this module is inert.
  # ───────────────────────────────────────────────────────────────────────────
  flake.nixosModules.observability-sender =
    {
      pkgs,
      lib,
      noughtyLib,
      config,
      ...
    }:
    lib.mkIf (noughtyLib.hostHasTag "observability-sender") {
      # Enable cgroup CPU/memory accounting so node_exporter's systemd collector
      # and the process exporter can read accurate per-service resource usage.
      systemd.settings.Manager = {
        DefaultCPUAccounting = true;
        DefaultMemoryAccounting = true;
      };

      services.alloy.enable = true;
      systemd.services.alloy.serviceConfig.SupplementaryGroups = [ "systemd-journal" ];
      services.prometheus.exporters.node.enable = true;

      # SMART disk metrics. smartctl is its own exporter (:9633), NOT a
      # node_exporter collector — passing it via enabledCollectors makes
      # node_exporter fail on an unknown --collector.smartctl flag. It only
      # yields data on hosts whose disks actually expose SMART; plain virtio
      # disks in VMs don't, so expect empty results there.
      services.prometheus.exporters.smartctl.enable = true;

      # Process exporter for per-service CPU/memory metrics.
      # Runs as root so it can read /proc for all processes.
      services.prometheus.exporters.process = {
        enable = true;
        port = 9256;
        user = "root";
        settings.process_names = [
          {
            name = "{{.ExeBase}}";
            cmdline = [ ".+" ];
          }
        ];
      };

      environment.etc."alloy/config.alloy" = {
        text =
          let
            hostname = config.networking.hostName;
            lokiendpoint = "http://10.9.0.1:3100/loki/api/v1/push";
            mimirendpoint = "http://10.9.0.1:9009/api/v1/push";
          in
          ''
            prometheus.exporter.unix "gagu" {
              enable_collectors = ["systemd"]
            }

            // Configure a prometheus.scrape component to collect unix metrics.
            prometheus.scrape "gagu" {
              targets    = prometheus.exporter.unix.gagu.targets
              forward_to = [prometheus.remote_write.nixvms.receiver]
            }

            // Scrape the standalone smartctl exporter (port 9633). Without a
            // scrape job its metrics never reach Mimir — the exporter just
            // sits there answering /metrics to nobody.
            prometheus.scrape "smartctl" {
              targets    = [{"__address__" = "127.0.0.1:9633"}]
              job_name   = "integrations/smartctl"
              forward_to = [prometheus.remote_write.nixvms.receiver]
            }

            // Scrape the NixOS-native process exporter (runs as root, port 9256).
            // Produces namedprocess_namegroup_cpu_seconds_total{groupname="<exe>"}.
            prometheus.scrape "process" {
              targets    = [{"__address__" = "127.0.0.1:9256"}]
              job_name   = "integrations/process"
              forward_to = [prometheus.remote_write.nixvms.receiver]
            }

            prometheus.remote_write "nixvms" {
              external_labels = {
                hostname = "${hostname}",
                instance = "${hostname}",
              }
              endpoint {
                url = "${mimirendpoint}"
                remote_timeout = "10s"
              }
            }
            loki.relabel "journal" {
              forward_to = []

              rule {
                source_labels = ["__journal__systemd_unit"]
                target_label  = "unit"
              }
            }

            loki.source.journal "read"  {
              forward_to    = [loki.write.endpoint.receiver]
              relabel_rules = loki.relabel.journal.rules
              labels        = {
                component = "loki.source.journal",
              }
            }

            loki.write "endpoint" {
              external_labels = {
                hostname = "${hostname}",
              }
              endpoint {
                url = "${lokiendpoint}"
              }
            }
          '';
      };
    };
}
