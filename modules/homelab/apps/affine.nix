# AFFiNE -- self-hosted block-based docs/whiteboard workspace. Routing and
# dashboard on 201 (reverse-proxy), workload on 203-media, split the same way as
# ocis.nix / immich.nix. Additive to homelab-notes (memos keeps
# notes.home.phonkd.net); nothing migrates.
#
# Why this module looks different from every other app here: nixpkgs has no
# AFFiNE *server*. `pkgs.affine` / `pkgs.affine-bin` are the Electron desktop
# client, and there is no `services.affine`. Upstream ships self-hosting only
# as a container image, so the app runs under oci-containers -- the only
# container in this config.
#
# It lives on 203 rather than 201 because 203 is already the busy host, and
# because 201 fronts everything. podman rather than docker for the same reason
# in both directions: docker's daemon installs its own iptables chains and a
# bridge, and BOTH candidate hosts are routing-sensitive -- 201 does NAT for
# wg0 and is the tailscale exit node, 203 runs a ProtonVPN full tunnel whose ip
# rules have to stay below Tailscale's (see nixconfig-ops). podman with
# --network=host adds neither. Backend is two lines if that ever changes.
#
# Postgres and Redis are NOT containers. Upstream's compose stands up
# pgvector/pgvector:pg16 + redis next to the app; here they are ordinary NixOS
# services, and on 203 postgres already exists because immich enables it -- so
# this module merges into it rather than declaring its own. See plans/affine.md.
{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-affine" =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    let
      domain = "affine.home.phonkd.net";
      port = 3010;
      dataDir = "/var/lib/affine";
      dbName = "affine";
      dbUser = "affine";

      # Pinned, not upstream's floating `stable` tag: that would move version
      # under us on any container restart and re-run migrations unattended.
      # Bumping = new tag AND new digest (skopeo inspect docker://<image>).
      image = "ghcr.io/toeverything/affine:0.27.3@sha256:d9d145f9f47b862d1fa96e2a887052b5762846237f75fbb077be990ef646e05c";

      # Env var names verified against v0.27.3's own config definitions
      # (packages/backend/server/src/{core/config,base/redis,base/prisma}/config.ts),
      # not from the docs site.
      environment = {
        # The password is ignored -- pg_hba below grants `trust` for this
        # role/db over loopback, mirroring upstream compose's
        # POSTGRES_HOST_AUTH_METHOD: trust. It is present only because the
        # value has to parse as a URL (prisma validates with z.string().url()).
        DATABASE_URL = "postgresql://${dbUser}:${dbUser}@127.0.0.1:5432/${dbName}";
        REDIS_SERVER_HOST = "127.0.0.1";
        REDIS_SERVER_PORT = "6379";

        # Used for generating external links (invites, share URLs, OAuth
        # redirects) -- unrelated to what the process binds.
        AFFINE_SERVER_HTTPS = "true";
        AFFINE_SERVER_HOST = domain;
        AFFINE_SERVER_EXTERNAL_URL = "https://${domain}";

        # What it actually binds. Not loopback any more: traefik is on 201 and
        # has to reach this across the LAN. Safe because 203's firewall drops
        # everything except `ip saddr 192.168.3.201 accept` (arr-slime.nix), so
        # :3010 is reachable from the reverse proxy and nowhere else -- same
        # posture as every *arr on this host.
        LISTEN_ADDR = "0.0.0.0";
        AFFINE_SERVER_PORT = toString port;

        # Matches upstream's compose: the indexer wants Elasticsearch, which we
        # do not run. Costs server-side full-text search across docs.
        AFFINE_INDEXER_ENABLED = "false";
      };

      volumes = [
        "${dataDir}/storage:/root/.affine/storage"
        "${dataDir}/config:/root/.affine/config"
      ];

      # The migration one-shot runs the same image with the same env/volumes,
      # so build both arg lists once.
      envArgs = lib.mapAttrsToList (k: v: "-e ${lib.escapeShellArg "${k}=${v}"}") environment;
      volArgs = map (v: "-v ${lib.escapeShellArg v}") volumes;
    in
    lib.mkMerge [
      # ---------------- routing + dashboard (201) ---------------- #
      (lib.mkIf (noughtyLib.hostHasTag "reverse-proxy") {
        phonkds.modules.affine = {
          ip = "192.168.3.203";
          inherit port;
          dashboard = {
            enable = true;
            icon = "affine";
          };
          traefik = {
            enable = true;
            # AFFiNE has its own account system, so authelia is the outer lock
            # only: bypassed from `internal`, deny otherwise (see the
            # access_control rule naming this domain in authelia.nix).
            auth = true;
            inherit domain;
            ipfilter = true;
          };
        };
      })

      # ---------------- workload (203-media) ---------------- #
      (lib.mkIf (noughtyLib.hostHasTag "media-server") {
        services.postgresql = {
          enable = true;
          # NO `package` here on purpose. immich already enables postgres on
          # this host and leaves the version at the nixpkgs default (17.10 as
          # deployed), with a data dir to match. Pinning 16 to mirror upstream's
          # pgvector:pg16 image would point a pg16 binary at a pg17 cluster and
          # refuse to start. AFFiNE is happy on 17.
          #
          # `extensions` is functionTo (listOf path), which the module system
          # merges by CONCATENATION -- verified, not assumed -- so this adds to
          # immich's list rather than replacing it, and the duplicate pgvector
          # both modules ask for is the same store path.
          extensions = ps: [ ps.pgvector ];
          ensureDatabases = [ dbName ];
          ensureUsers = [
            {
              name = dbUser;
              ensureDBOwnership = true;
            }
          ];
          # Inserted ABOVE the module's default `host all all 127.0.0.1/32 md5`,
          # and scoped to exactly this role on exactly this database, so it
          # cannot loosen immich's access. Postgres listens on loopback only
          # (listen_addresses = "localhost"; nothing sets enableTCPIP).
          authentication = ''
            host ${dbName} ${dbUser} 127.0.0.1/32 trust
          '';
        };

        # immich's redis is a named instance on a unix socket (named servers
        # default to port 0), so 6379 is free -- verified with `ss -lntp`.
        services.redis.servers.affine = {
          enable = true;
          bind = "127.0.0.1";
          port = 6379;
        };

        virtualisation.podman.enable = true;
        virtualisation.oci-containers.backend = "podman";

        virtualisation.oci-containers.containers.affine = {
          inherit image environment volumes;
          extraOptions = [ "--network=host" ];
          autoStart = true;
        };

        systemd.tmpfiles.rules = [
          "d ${dataDir} 0750 root root -"
          "d ${dataDir}/storage 0750 root root -"
          "d ${dataDir}/config 0750 root root -"
        ];

        # `CREATE EXTENSION` needs superuser, and the affine role is not one --
        # so AFFiNE's own `CREATE EXTENSION IF NOT EXISTS vector` in its
        # migrations would fail on a fresh database. Creating it here first turns
        # that statement into a no-op, which needs no privileges.
        systemd.services.affine-pgvector = {
          description = "Create the pgvector extension in AFFiNE's database";
          requires = [ "postgresql-setup.service" ];
          after = [ "postgresql-setup.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "postgres";
            Group = "postgres";
            ExecStart = pkgs.writeShellScript "affine-pgvector" ''
              exec ${config.services.postgresql.finalPackage}/bin/psql \
                -d ${dbName} -c 'CREATE EXTENSION IF NOT EXISTS vector'
            '';
          };
        };

        # Upstream's `affine_migration` compose service, as a one-shot. The
        # server container refuses to start until this has succeeded once; it
        # re-runs whenever the image pin changes, which is exactly when new
        # migrations land.
        systemd.services.affine-migrate = {
          description = "AFFiNE self-host predeploy (database migrations)";
          requires = [
            "postgresql-setup.service"
            "redis-affine.service"
            "affine-pgvector.service"
          ];
          after = [
            "postgresql-setup.service"
            "redis-affine.service"
            "affine-pgvector.service"
            "network-online.target"
          ];
          wants = [ "network-online.target" ];
          before = [ "podman-affine.service" ];
          requiredBy = [ "podman-affine.service" ];
          path = [ config.virtualisation.podman.package ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "affine-migrate" ''
              set -eu
              exec podman run --rm --network=host \
                ${lib.concatStringsSep " \\\n  " (envArgs ++ volArgs)} \
                ${image} node ./scripts/self-host-predeploy.js
            '';
          };
        };
      })
    ];
}
