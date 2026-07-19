# ownCloud Infinite Scale (oCIS) -- personal cloud storage / file sync,
# living on the media-server VM (203-media) alongside the *arr stack.
# Split the same way as arr-slime.nix: routing/dashboard config lives on
# the reverse-proxy host (201), the actual service lives on 203-media.
{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-ocis" =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    lib.mkMerge [
      (lib.mkIf (noughtyLib.hostHasTag "reverse-proxy") {
        phonkds.modules.ocis = {
          ip = "192.168.3.203";
          port = 9200;
          dashboard.enable = true;
          # Default icon resolves to a nonexistent "ocis.png" -> broken tile.
          # oCIS = ownCloud Infinite Scale; selfh.st ships the ownCloud glyph.
          dashboard.icon = "sh-owncloud";
          traefik = {
            enable = true;
            domain = "ocis.w.phonkd.net";
            auth = false;
            ipfilter = false;
          };
        };
      })

      (lib.mkIf (noughtyLib.hostHasTag "media-server") {
        # oCIS ships under a non-free EULA (see ocis_5-bin in nixpkgs) --
        # allow just this package rather than the whole unfree set.
        nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
          "ocis_5-bin"
        ];

        sops.secrets."ocis-admin-password" = { };

        # ADMIN_PASSWORD seeds `ocis init` on first boot; IDM_ADMIN_PASSWORD
        # keeps the runtime idm service in agreement afterwards.
        sops.templates."ocis.env" = {
          content = ''
            ADMIN_PASSWORD=${config.sops.placeholder."ocis-admin-password"}
            IDM_ADMIN_PASSWORD=${config.sops.placeholder."ocis-admin-password"}
          '';
          owner = "ocis";
        };

        services.ocis = {
          enable = true;
          address = "0.0.0.0";
          port = 9200;
          url = "https://ocis.w.phonkd.net";
          stateDir = "/mnt/solo-sata/ocis";
          environmentFile = config.sops.templates."ocis.env".path;
          environment = {
            # TLS terminates at traefik on 201; serve plain HTTP here and
            # skip cert verification between oCIS's internal services.
            PROXY_TLS = "false";
            OCIS_INSECURE = "true";
            # oCIS's internal "web" service defaults to 9100, which
            # node_exporter (observability-sender) already holds on this
            # host — the only overlap between oCIS's fullstack ports and
            # what 203 runs. Purely internal, only the proxy talks to it.
            WEB_HTTP_ADDR = "127.0.0.1:9101";
          };
        };

        # The nixpkgs module doesn't bootstrap oCIS's config (jwt secrets,
        # service accounts, ...) and `ocis server` refuses to start without
        # one -- generate it on first boot. EnvironmentFile above is
        # unit-level, so $ADMIN_PASSWORD is available here too.
        systemd.services.ocis.preStart = ''
          if [ ! -f "${config.services.ocis.stateDir}/config/ocis.yaml" ]; then
            ${lib.getExe config.services.ocis.package} init \
              --config-path "${config.services.ocis.stateDir}/config" \
              --admin-password "$ADMIN_PASSWORD" \
              --insecure true
          fi
        '';
      })
    ];
}
