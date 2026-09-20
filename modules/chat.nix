# Matrix homeserver (Synapse) + the Signal / WhatsApp / Discord puppeting
# bridges, and the desktop client that talks to them.
#
# Both halves of the feature live here, the way modules/kde.nix,
# modules/hyprland.nix and modules/desktop.nix each keep their NixOS and
# Home Manager sides together:
#
#   flake.nixosModules.chat-server -- the homeserver, gated on the
#                                     "chat-server" tag (lib/registry.nix)
#   flake.homeModules.chat         -- the Matrix client for a desktop
#
# See plans/matrix-bridges.md for the why, the port map and the landmines.
#
# NOTHING HERE IS LIVE YET: no host carries the "chat-server" tag, so the
# whole server half sits behind `mkIf false`. Tagging a host is what turns
# it on -- and the secrets listed in plans/matrix-bridges.md ("Secrets")
# have to exist first, or Synapse and all three bridges fail to start.
{
  self,
  inputs,
  ...
}:
{
  # ── server half ───────────────────────────────────────────────────────
  flake.nixosModules.chat-server =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    let
      # server_name is PERMANENT -- it is baked into every MXID and every
      # room this server ever joins, and cannot be changed later without
      # abandoning the account. phonkd.net (not matrix.phonkd.net) so the
      # MXIDs read @phonkd:phonkd.net; federation finds the actual host via
      # the _matrix-fed._tcp SRV record.
      serverName = "phonkd.net";
      matrixHost = "matrix.phonkd.net";

      chatSecrets = ./homelab/secrets/chat.yaml;

      # Every service on this box reaches postgres over the unix socket --
      # landmine 1 in the plan: sshd owns :5432 on hetzner-vm hosts, so
      # postgres must not bind TCP at all.
      pgUri = db: "postgresql:///${db}?host=/run/postgresql";

      # All three bridges regenerate their config file on every start, so a
      # secret left at the module default ("" or "generate") changes on each
      # restart -- which invalidates every encrypted session. The modules'
      # answer is envsubst: each preStart runs the settings file through it,
      # so a "$VAR" below is replaced at start time by the value supplied
      # through environmentFile. The names must match the sops.templates.

      # The two well-known documents. Both are served from matrix.phonkd.net
      # rather than the apex: the apex A record points at the *home* IP and
      # serves no valid cert there, so federation discovery falls through to
      # SRV. Harmless here, and correct if anything ever redirects.
      wellKnownServer = builtins.toJSON { "m.server" = "${matrixHost}:443"; };
      wellKnownClient = builtins.toJSON {
        "m.homeserver".base_url = "https://${matrixHost}";
      };
    in
    {
      config = lib.mkIf (noughtyLib.hostHasTag "chat-server") {

        # ── secrets ───────────────────────────────────────────────────────
        # Per-app sops file, populated by `sops-secret chat.<key> --generate`
        # (modules/devshell.nix). Every value is a random string; none is an
        # account credential. The Signal / WhatsApp / Discord logins happen
        # at runtime over a bot DM, never through this file.
        sops.secrets =
          lib.genAttrs
            [
              "chat_synapse_registration_shared_secret"
              "chat_synapse_macaroon_secret_key"
              "chat_synapse_form_secret"
              "chat_whatsapp_pickle_key"
              "chat_whatsapp_provisioning_secret"
              "chat_whatsapp_public_media_key"
              "chat_whatsapp_direct_media_key"
              "chat_signal_pickle_key"
              "chat_signal_provisioning_secret"
              "chat_signal_public_media_key"
              "chat_signal_direct_media_key"
              "chat_discord_provisioning_secret"
              "chat_discord_avatar_proxy_key"
              "chat_discord_direct_media_key"
            ]
            (_: {
              sopsFile = chatSecrets;
            });

        # Synapse refuses these three as nix-store values: the module carries
        # mkRemovedOptionModule entries telling you to use extraConfigFiles
        # (synapse.nix ~L418), precisely so they never land in /nix/store.
        sops.templates."synapse-extra-config.yaml" = {
          content = ''
            registration_shared_secret: "${config.sops.placeholder."chat_synapse_registration_shared_secret"}"
            macaroon_secret_key: "${config.sops.placeholder."chat_synapse_macaroon_secret_key"}"
            form_secret: "${config.sops.placeholder."chat_synapse_form_secret"}"
          '';
          owner = "matrix-synapse";
        };

        sops.templates."mautrix-whatsapp.env" = {
          content = ''
            MAUTRIX_WHATSAPP_ENCRYPTION_PICKLE_KEY=${config.sops.placeholder."chat_whatsapp_pickle_key"}
            MAUTRIX_WHATSAPP_PROVISIONING_SHARED_SECRET=${
              config.sops.placeholder."chat_whatsapp_provisioning_secret"
            }
            MAUTRIX_WHATSAPP_PUBLIC_MEDIA_SIGNING_KEY=${
              config.sops.placeholder."chat_whatsapp_public_media_key"
            }
            MAUTRIX_WHATSAPP_DIRECT_MEDIA_SERVER_KEY=${config.sops.placeholder."chat_whatsapp_direct_media_key"}
          '';
          owner = "mautrix-whatsapp";
        };

        sops.templates."mautrix-signal.env" = {
          content = ''
            MAUTRIX_SIGNAL_ENCRYPTION_PICKLE_KEY=${config.sops.placeholder."chat_signal_pickle_key"}
            MAUTRIX_SIGNAL_PROVISIONING_SHARED_SECRET=${
              config.sops.placeholder."chat_signal_provisioning_secret"
            }
            MAUTRIX_SIGNAL_PUBLIC_MEDIA_SIGNING_KEY=${config.sops.placeholder."chat_signal_public_media_key"}
            MAUTRIX_SIGNAL_DIRECT_MEDIA_SERVER_KEY=${config.sops.placeholder."chat_signal_direct_media_key"}
          '';
          owner = "mautrix-signal";
        };

        sops.templates."mautrix-discord.env" = {
          content = ''
            MAUTRIX_DISCORD_PROVISIONING_SHARED_SECRET=${
              config.sops.placeholder."chat_discord_provisioning_secret"
            }
            MAUTRIX_DISCORD_AVATAR_PROXY_KEY=${config.sops.placeholder."chat_discord_avatar_proxy_key"}
            MAUTRIX_DISCORD_DIRECT_MEDIA_SERVER_KEY=${config.sops.placeholder."chat_discord_direct_media_key"}
          '';
          owner = "mautrix-discord";
        };

        # ── libolm ────────────────────────────────────────────────────────
        # All three bridges link libolm, which nixpkgs marks insecure
        # (deprecated upstream, side-channel issues in its crypto library).
        # It is a buildInputs dependency, so turning bridge encryption off
        # would not drop it. mautrix-whatsapp and mautrix-signal expose a
        # `withGoolm` flag that swaps in a pure-Go Olm, but mautrix-discord
        # has no such flag -- and upstream calls goolm experimental and "not
        # recommended". So the only way to build this host is to permit it.
        #
        # The version is pinned in the string, so a nixpkgs bump that moves
        # olm past 3.2.16 turns this into a build failure rather than a
        # silent no-op. That is the intended failure mode: revisit then.
        nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];

        # ── postgres ──────────────────────────────────────────────────────
        services.postgresql = {
          enable = true;

          # Landmine 1: hetzner-vm.nix puts sshd on :5432, and nixpkgs'
          # postgresql binds 127.0.0.1:5432 even with enableTCPIP = false.
          # Nothing orders the two services, so which one loses the bind is a
          # race -- and the bad branch leaves the box reachable only through
          # the Hetzner console. Everything here uses the socket, so bind no
          # TCP at all.
          settings.listen_addresses = lib.mkForce "";

          # Synapse refuses to start against a database that is not C
          # collated, and `ensureDatabases` issues a bare CREATE DATABASE
          # with no locale control -- so the *cluster* has to be initialised
          # that way. This takes effect at initdb time only, i.e. on the very
          # first start of a fresh host. Retrofitting an existing cluster
          # means dump, re-initdb, restore.
          initdbArgs = [
            "--locale=C"
            "--encoding=UTF8"
          ];

          ensureDatabases = [
            "matrix-synapse"
            "mautrix_whatsapp"
            "mautrix_signal"
            "mautrix_discord"
          ];
          ensureUsers = [
            {
              name = "matrix-synapse";
              ensureDBOwnership = true;
            }
            { name = "mautrix-whatsapp"; }
            { name = "mautrix-signal"; }
            { name = "mautrix-discord"; }
          ];
        };

        # ensureDBOwnership asserts that the role name equals the database
        # name, and it cannot hold for the bridges: their system users are
        # `mautrix-whatsapp` while a postgres database name with a hyphen
        # would have to be quoted everywhere in their connection URIs. So the
        # databases are `mautrix_whatsapp` etc., and ownership is handed over
        # here, once, after ensureDatabases has created them.
        systemd.services.postgresql.postStart = lib.mkAfter ''
          $PSQL -tAc 'ALTER DATABASE "mautrix_whatsapp" OWNER TO "mautrix-whatsapp";'
          $PSQL -tAc 'ALTER DATABASE "mautrix_signal"   OWNER TO "mautrix-signal";'
          $PSQL -tAc 'ALTER DATABASE "mautrix_discord"  OWNER TO "mautrix-discord";'
        '';

        # ── synapse ───────────────────────────────────────────────────────
        services.matrix-synapse = {
          enable = true;
          extraConfigFiles = [ config.sops.templates."synapse-extra-config.yaml".path ];
          settings = {
            server_name = serverName;
            public_baseurl = "https://${matrixHost}/";
            enable_registration = false;

            listeners = [
              {
                port = 8008;
                bind_addresses = [ "127.0.0.1" ];
                type = "http";
                tls = false;
                x_forwarded = true;
                resources = [
                  {
                    names = [
                      "client"
                      "federation"
                    ];
                    compress = false;
                  }
                ];
              }
            ];

            database = {
              name = "psycopg2";
              args = {
                database = "matrix-synapse";
                host = "/run/postgresql";
              };
            };
          };
        };

        # ── bridges ───────────────────────────────────────────────────────
        # registerToSynapse defaults to services.matrix-synapse.enable, so
        # each bridge appends its own registration file to synapse's
        # app_service_config_files and adds itself to its SupplementaryGroups.
        # No hand-written registration YAML anywhere.
        services.mautrix-whatsapp = {
          enable = true;
          environmentFile = config.sops.templates."mautrix-whatsapp.env".path;
          settings = {
            homeserver = {
              address = "http://127.0.0.1:8008";
              domain = serverName;
            };
            database = {
              type = "postgres";
              uri = pgUri "mautrix_whatsapp";
            };
            encryption = {
              allow = true;
              default = true;
              pickle_key = "$MAUTRIX_WHATSAPP_ENCRYPTION_PICKLE_KEY";
            };
            provisioning.shared_secret = "$MAUTRIX_WHATSAPP_PROVISIONING_SHARED_SECRET";
            public_media.signing_key = "$MAUTRIX_WHATSAPP_PUBLIC_MEDIA_SIGNING_KEY";
            direct_media.server_key = "$MAUTRIX_WHATSAPP_DIRECT_MEDIA_SERVER_KEY";
            bridge.permissions = {
              "*" = "relay";
              ${serverName} = "admin";
            };
          };
        };

        services.mautrix-signal = {
          enable = true;
          environmentFile = config.sops.templates."mautrix-signal.env".path;
          settings = {
            homeserver = {
              address = "http://127.0.0.1:8008";
              domain = serverName;
            };
            database = {
              type = "postgres";
              uri = pgUri "mautrix_signal";
            };
            encryption = {
              allow = true;
              default = true;
              pickle_key = "$MAUTRIX_SIGNAL_ENCRYPTION_PICKLE_KEY";
            };
            provisioning.shared_secret = "$MAUTRIX_SIGNAL_PROVISIONING_SHARED_SECRET";
            public_media.signing_key = "$MAUTRIX_SIGNAL_PUBLIC_MEDIA_SIGNING_KEY";
            direct_media.server_key = "$MAUTRIX_SIGNAL_DIRECT_MEDIA_SERVER_KEY";
            bridge.permissions = {
              "*" = "relay";
              ${serverName} = "admin";
            };
          };
        };

        # mautrix-discord is the odd one out: it still uses the pre-bridgev2
        # config layout, so the database block hangs off `appservice` and the
        # secrets live under `bridge`, not at the top level.
        services.mautrix-discord = {
          enable = true;
          environmentFile = config.sops.templates."mautrix-discord.env".path;
          settings = {
            homeserver = {
              address = "http://127.0.0.1:8008";
              domain = serverName;
            };
            appservice.database = {
              type = "postgres";
              uri = pgUri "mautrix_discord";
            };
            bridge = {
              encryption = {
                allow = true;
                default = true;
              };
              provisioning.shared_secret = "$MAUTRIX_DISCORD_PROVISIONING_SHARED_SECRET";
              avatar_proxy_key = "$MAUTRIX_DISCORD_AVATAR_PROXY_KEY";
              direct_media.server_key = "$MAUTRIX_DISCORD_DIRECT_MEDIA_SERVER_KEY";
              permissions = {
                "*" = "relay";
                ${serverName} = "admin";
              };
            };
          };
        };

        # ── nginx ─────────────────────────────────────────────────────────
        security.acme.acceptTerms = true;
        security.acme.defaults.email = "bhonk123@gmail.com";

        services.nginx = {
          enable = true;
          recommendedProxySettings = true;
          recommendedTlsSettings = true;
          recommendedGzipSettings = true;

          virtualHosts.${matrixHost} = {
            forceSSL = true;
            enableACME = true;

            locations."/_matrix" = {
              proxyPass = "http://127.0.0.1:8008";
              # Matrix media uploads are the large bodies here; nginx's
              # 1m default rejects most of them.
              extraConfig = "client_max_body_size 100M;";
            };
            locations."/_synapse/admin" = {
              proxyPass = "http://127.0.0.1:8008";
              extraConfig = "client_max_body_size 100M;";
            };

            locations."= /.well-known/matrix/server".extraConfig = ''
              add_header Content-Type application/json;
              add_header Access-Control-Allow-Origin *;
              return 200 '${wellKnownServer}';
            '';
            locations."= /.well-known/matrix/client".extraConfig = ''
              add_header Content-Type application/json;
              add_header Access-Control-Allow-Origin *;
              return 200 '${wellKnownClient}';
            '';
          };
        };

        # Federation rides 443 via the SRV record, so 8448 stays shut.
        # The Hetzner *cloud* firewall is separate from this one -- the
        # headscale rollout was bitten by exactly that
        # (plans/headscale-mesh.md); open 80/443 there too or ACME silently
        # never completes.
        networking.firewall.allowedTCPPorts = [
          80
          443
        ];

        # hetzner-vm.nix turns Docker on for every host wearing that tag.
        # Nothing here needs it, and it is ~1 GB of closure plus a bridge
        # network on a 40 GB disk.
        virtualisation.docker.enable = lib.mkForce false;
      };
    };

  # ── client half ───────────────────────────────────────────────────────
  # Imported from flake.homeModules.gui-nixos (modules/hosts/types/gui),
  # which is the list blac, g14 and z14 already pull. The Mac takes an
  # `element` cask in gui-darwin instead -- HM links apps as store symlinks
  # that Spotlight will not index, so a nix-installed GUI app is
  # unlaunchable on Tahoe (the same reason affine and discord are casks).
  #
  # element-desktop over nheko/fluffychat because the bridges are driven
  # entirely by bot DMs with !wa / !signal / !discord commands, and Element
  # is where those flows are actually tested.
  flake.homeModules.chat =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.element-desktop ];
    };
}
