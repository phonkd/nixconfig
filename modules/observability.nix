{
  self,
  inputs,
  ...
}:
{
  # ───────────────────────────────────────────────────────────────────────────
  # Central observability stack (Hetzner VM, tag "observability-server")
  #
  #   Loki    — log aggregation        (HTTP 3100)
  #   Mimir   — long-term metrics      (HTTP 9009, Prometheus-compatible)
  #   Grafana — dashboards / explore   (HTTP 3000)
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
          target = "all";

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

          ruler_storage = {
            backend = "filesystem";
            filesystem.dir = "/var/lib/mimir/ruler";
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
      # systemd.services.alloy.serviceConfig = {
      #     # Alloy normally runs as an unprivileged user; force root instead.
      #   User  = lib.mkForce "root";
      #   Group = lib.mkForce "root";  # optional, but usually pair with User
      # };
      services.prometheus.exporters.node = {
        # enabledCollectors = [
        #   "node"
        #   "postgres"
        # ];
        enable = true;
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

            // Per-process CPU/memory grouped by executable name.
            // Produces namedprocess_namegroup_cpu_seconds_total{groupname="<exe>"}.
            prometheus.exporter.process "services" {
              track_children = true
              track_threads  = false
              matcher {
                name = "{{.Comm}}"
                comm = [".+"]
              }
            }

            prometheus.scrape "services" {
              targets    = prometheus.exporter.process.services.targets
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
