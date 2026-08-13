# AFFiNE -- self-hosted block-based docs/whiteboard workspace, on 201-mono
# alongside the rest of the homelab-server apps. Additive to homelab-notes
# (memos stays at notes.home.phonkd.net); nothing migrates.
#
# Why this module looks different from every other app here: nixpkgs has no
# AFFiNE *server*. `pkgs.affine` / `pkgs.affine-bin` are the Electron desktop
# client, and there is no `services.affine`. Upstream ships self-hosting only
# as a container image, so the app runs under oci-containers -- the first
# container on 201.
#
# Postgres and Redis are NOT containers though. Upstream's compose stands up
# pgvector/pgvector:pg16 + redis next to the app; here they are ordinary NixOS
# services so they stay inside the normal backup/observability/GC story. The
# app container joins the host netns (--network=host), which is what lets it
# reach both at 127.0.0.1 with no bridge and no host.containers.internal
# guessing, and lets LISTEN_ADDR pin the listener to loopback so traefik is the
# only way in. See plans/affine.md.
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

        # What it actually binds. Default is 0.0.0.0, which under
        # --network=host would put :3010 on 201's LAN address too; traefik is
        # on this host, so loopback is enough.
        LISTEN_ADDR = "127.0.0.1";
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
    lib.mkIf (noughtyLib.hostHasTag "homelab-server") {
      phonkds.modules.affine = {
        ip = "127.0.0.1";
        inherit port;
        dashboard = {
          enable = true;
          icon = "affine";
        };
        traefik = {
          enable = true;
          auth = false;
          inherit domain;
          ipfilter = true;
        };
      };

      # ------------------------------------------------------------------ #
      # Datastores (upstream runs these as containers; we don't)
      # ------------------------------------------------------------------ #
      services.postgresql = {
        enable = true;
        # pg16, matching upstream's pgvector/pgvector:pg16.
        package = pkgs.postgresql_16;
        # AFFiNE's migrations expect the `vector` type to exist. Shipping the
        # extension is only half of it -- see affine-pgvector below.
        extensions = ps: [ ps.pgvector ];
        ensureDatabases = [ dbName ];
        ensureUsers = [
          {
            name = dbUser;
            ensureDBOwnership = true;
          }
        ];
        # Inserted ABOVE the module's default `host all all 127.0.0.1/32 md5`,
        # and scoped to exactly this role on exactly this database. Postgres
        # listens on loopback only (listen_addresses = "localhost"; we never
        # set enableTCPIP), so this is not reachable off the box.
        authentication = ''
          host ${dbName} ${dbUser} 127.0.0.1/32 trust
        '';
      };

      services.redis.servers.affine = {
        enable = true;
        bind = "127.0.0.1";
        # Named redis instances default to port 0 (unix socket only); AFFiNE's
        # ioredis client speaks TCP.
        port = 6379;
      };

      # ------------------------------------------------------------------ #
      # Container runtime
      # ------------------------------------------------------------------ #
      # 201 ran no containers before this. podman rather than docker: no daemon
      # and no `docker` group on the box that fronts everything. (dnsmasq
      # already excludes podman* interfaces -- see modules/dns.nix.)
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
    };
}
