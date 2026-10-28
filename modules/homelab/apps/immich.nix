# Immich -- self-hosted photo/video backup, living on the media-server VM
# (203-media) alongside oCIS. Split the same way as ocis.nix: routing/
# dashboard config lives on the reverse-proxy host (201), the actual
# service lives on 203-media.
{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-immich" =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    lib.mkMerge [
      (lib.mkIf (noughtyLib.hostHasTag "reverse-proxy") {
        phonkds.modules.immich = {
          ip = "192.168.3.203";
          port = 2283;
          dashboard.enable = true;
          traefik = {
            enable = true;
            domain = "immich.home.phonkd.net";
            auth = false;
            ipfilter = true;
            extraMiddlewares = [ "immich-tailnet-only" ];
          };
        };

        # The shared ip-filter also permits LAN/legacy VPN clients. Require
        # a tailnet peer address for Immich, even if the public ingress is
        # contacted with the new Host header. Use the socket peer address,
        # not client-controlled X-Forwarded-For (no ipStrategy configured).
        services.traefik.dynamicConfigOptions.http.middlewares.immich-tailnet-only.ipAllowList.sourceRange = [
          "100.64.0.0/10"
        ];
      })

      (lib.mkIf (noughtyLib.hostHasTag "media-server") {
        # mediaLocation defaults to /var/lib/immich; put the photo/video
        # library on the same solo-sata disk as the rest of the media
        # stack instead of the system disk. The upstream module's own
        # tmpfiles rule (type "e") only adjusts an existing path, so
        # create it ourselves first.
        systemd.tmpfiles.rules = [
          "d /mnt/solo-sata/immich 0700 immich immich -"
        ];

        services.immich = {
          enable = true;
          # Stable still carries 2.x. Use the maintained unstable input for
          # the 3.x server and its matching machine-learning package.
          package = inputs.nixpkgs-unstable.legacyPackages.${pkgs.system}.immich;
          host = "0.0.0.0";
          mediaLocation = "/mnt/solo-sata/immich";
        };
      })
    ];
}
