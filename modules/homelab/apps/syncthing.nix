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
        # `After=syncthing.service`. Requisite is checked at dispatch and,
        # unlike Requires, does NOT pull syncthing.service into the
        # transaction, so After= has nothing to order against: syncthing-init
        # can get dispatched while syncthing is still stopped, fail with
        # 'dependency', and take the whole deploy-rs generation down with it.
        # Hit twice on 2026-08-14 even though syncthing came up ~1s later both
        # times. Requires= puts both units in the same transaction so After=
        # finally orders them; a genuine syncthing failure still fails
        # syncthing-init exactly as before.
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
            "users" # any user can mount/unmount
            "nofail" # don't fail boot if this drive doesn't mount
          ];
          autoFormat = true;
          autoResize = true;
        };
    };
}
