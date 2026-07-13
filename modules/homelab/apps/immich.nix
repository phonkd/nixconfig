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
            domain = "immich.w.phonkd.net";
            auth = false;
            ipfilter = false;
          };
        };
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
          # nixpkgs-26.05/unstable are both still on Immich 2.7.5; pull just
          # this package from a newer pin to get 3.0.2.
          package = inputs.nixpkgs-immich.legacyPackages.${pkgs.system}.immich;
          host = "0.0.0.0";
          mediaLocation = "/mnt/solo-sata/immich";
        };
      })
    ];
}
