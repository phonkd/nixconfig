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
          traefik = {
            enable = true;
            domain = "ocis.w.phonkd.net";
            auth = false;
            ipfilter = false;
            # oCIS terminates TLS itself with a self-signed cert on its
            # main port even with OCIS_INSECURE set (same situation as
            # oldblac's Proxmox UI in orphans.nix) -- skip verification
            # rather than fight it.
            scheme = "https";
            transport = "insecureTransport";
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

        sops.templates."ocis.env" = {
          content = ''
            ADMIN_PASSWORD=${config.sops.placeholder."ocis-admin-password"}
          '';
          owner = "ocis";
        };

        services.ocis = {
          enable = true;
          address = "0.0.0.0";
          url = "https://ocis.w.phonkd.net";
          stateDir = "/mnt/solo-sata/ocis";
          environmentFile = config.sops.templates."ocis.env".path;
        };
      })
    ];
}
