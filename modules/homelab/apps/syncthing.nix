{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-syncthing" = { config, pkgs, lib, noughtyLib, ... }:
    lib.mkIf (noughtyLib.hostHasTag "homelab-server") {
      phonkds.modules = {
          syncthing = {
            ip = "127.0.0.1";
            port = 8384;
            dashboard = {
              enable = true;
              icon = "syncthing";
            };
            traefik = {
              enable = true;
              domain = "syncthing.w.phonkd.net";
              ipfilter = true;
            };
          };
        };

        services.syncthing.enable = true;
        services.syncthing.dataDir = "/mnt/syncthing/data";
        systemd.tmpfiles.rules = [
          "d /mnt/syncthing/data 0755 syncthing syncthing -"
        ];
        fileSystems."/mnt/syncthing" = {
          device = "/dev/disk/by-id/virtio-vm-202-disk-3";
          fsType = "ext4";
          options = [
            # If you don't have this options attribute, it'll default to "defaults"
            # boot options for fstab. Search up fstab mount options you can use
            "users" # Allows any user to mount and unmount
            "nofail" # Prevent system from failing if this drive doesn't mount
          ];
          autoFormat = true;
          autoResize = true;
        };
    };
}
