{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-garage" = { config, pkgs, lib, noughtyLib, ... }:
    lib.mkIf (noughtyLib.hostHasTag "homelab-server") {
      phonkds.modules = {
        s3-public = {
          ip = "127.0.0.1";
          port = 3902;
          traefik = {
            enable = true;
            domain = "public.s3.w.phonkd.net";
            ipfilter = false;
          };
        };
        # The `public` bucket predates this repo (created 2025-12-29) and still
        # carries a second global alias, `s3.phonkd.net`, from the pre-nix
        # homelab. Garage serves it through the exact-domain path rather than
        # s3_web.root_domain, and the Cloudflare A record still points here --
        # only the traefik router was never carried over, so the host fell back
        # to TRAEFIK DEFAULT CERT and TLS failed. This restores the route; the
        # bucket alias and DNS needed no change.
        s3-legacy-public = {
          ip = "127.0.0.1";
          port = 3902;
          dashboard.enable = false;
          traefik = {
            enable = true;
            domain = "s3.phonkd.net";
            ipfilter = false;
          };
        };
        s3-priv = {
          ip = "127.0.0.1";
          port = 3902;
          dashboard.enable = false;
          traefik = {
            enable = true;
            domain = "priv.s3.w.phonkd.net";
            ipfilter = false;
            auth = true;
          };
        };
        s3-api = {
          ip = "127.0.0.1";
          port = 3900;
          dashboard.enable = false;
          traefik = {
            enable = true;
            domain = "api.s3.w.phonkd.net";
            ipfilter = true;
          };
        };
        # garage-webui removed: upstream is unmaintained and it was dropped from
        # nixpkgs (2026-06-23). Its only clean build path pulled an insecure
        # pnpm, so we no longer run the web UI.
      };

      users.users.garage = {
        group = "garage";
        isSystemUser = true;
      };
      users.groups.garage = { };

      sops.secrets."garage-rpc" = {
        owner = "garage";
        mode = "0400";
      };

      sops.secrets."garage-metrics" = {
        owner = "garage";
        mode = "0400";
      };
      sops.secrets."garage-admin" = {
        owner = "garage";
        mode = "0400";
      };

      # 3. Configure Garage
      services.garage = {
        enable = true;
        package = pkgs.garage_2;

        settings = {
          replication_factor = 1;
          consistency_mode = "consistent";
          db_engine = "lmdb";

          metadata_dir = "/mnt/s3/meta";
          data_dir = "/mnt/s3/data";

          rpc_bind_addr = "[::]:3901";
          bootstrap_peers = [ ];

          rpc_secret_file = config.sops.secrets."garage-rpc".path;

          s3_api = {
            api_bind_addr = "127.0.0.1:3900";
            s3_region = "us-east-1";
            root_domain = ".api.s3.w.phonkd.net";
          };

          admin = {
            api_bind_addr = "127.0.0.1:3903";
            metrics_token_file = config.sops.secrets."garage-metrics".path;
            admin_token_file = config.sops.secrets."garage-admin".path;
          };
          s3_web = {

            bind_addr = "127.0.0.1:3902";

            # 2. Define the suffix for your websites
            #    If you create a bucket named "mysite", it will be served at:
            #    http://mysite.web.phonkd.net
            #    (You can also name a bucket "example.com" to serve that exact domain)
            root_domain = ".s3.w.phonkd.net";

            add_host_to_metrics = true;
          };
        };
      };

      # 4. OVERRIDE SYSTEMD SETTINGS
      #    We must explicitly disable DynamicUser.
      #    If we don't, Systemd will ignore our static 'garage' user and create a random one,
      #    which won't have permission to read the secrets.
      systemd.services.garage.serviceConfig = {
        DynamicUser = lib.mkForce false; # FORCE this off
        User = "garage";
        Group = "garage";
      };
      fileSystems."/mnt/s3" = {
        device = "/dev/disk/by-id/virtio-vm-202-disk-2";
        fsType = "xfs";
        options = [
          # If you don't have this options attribute, it'll default to "defaults"
          # boot options for fstab. Search up fstab mount options you can use
          "users" # Allows any user to mount and unmount
          "nofail" # Prevent system from failing if this drive doesn't mount

        ];
        autoFormat = true;
        autoResize = true;
      };
      systemd.tmpfiles.rules = [
        "d /mnt/s3      0755 garage garage - -"
        "d /mnt/s3/data 0700 garage garage - -"
        "d /mnt/s3/meta 0700 garage garage - -"
      ];
      systemd.services.garage = {
        after = [ "mnt-s3.mount" ];
        requires = [ "mnt-s3.mount" ];
      };
    };
}
