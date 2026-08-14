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
        # Behind traefik the Host header is syncthing.w.phonkd.net, not a loopback
        # address, so syncthing's GUI host check returns 403 "Host check error".
        # Access is already gated by traefik + ipfilter, so skip the check.
        services.syncthing.settings.gui.insecureSkipHostcheck = true;
        services.syncthing.dataDir = "/mnt/syncthing/data";
        # nixpkgs gives syncthing-init `Requisite=syncthing.service` alongside
        # `After=syncthing.service`. Requisite is checked when the start job is
        # dispatched and — unlike Requires — does NOT pull syncthing.service
        # into the transaction, so the After= has nothing to order against.
        # switch-to-configuration issues one StartUnit call per unit, so
        # syncthing-init gets dispatched while syncthing is still stopped (or
        # still blocked on /mnt/syncthing growing): systemd logs "Syncthing
        # service is inactive", the job ends with result 'dependency', and
        # switch-to-configuration exits 4 — which makes deploy-rs throw the
        # whole generation away. Hit twice on 2026-08-14 (19:04:29, 19:11:03),
        # and both times syncthing came up ~1s later and a second
        # syncthing-init job succeeded, i.e. nothing was actually wrong.
        #
        # Requires= puts syncthing.service in the same transaction, so the
        # existing After= finally orders the two. This does not hide anything:
        # if syncthing genuinely fails to start, syncthing-init still fails
        # with 'dependency' exactly as before.
        systemd.services.syncthing-init = {
          requisite = lib.mkForce [ ];
          requires = [ "syncthing.service" ];
        };
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
