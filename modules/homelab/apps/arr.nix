{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-arr" = { config, pkgs, lib, noughtyLib, ... }:
    lib.mkIf (noughtyLib.hostHasTag "homelab-server") {
      phonkds.modules.jellyfin = {
        ip = "127.0.0.1";
        port = 8096;
        dashboard.enable = true;
        traefik = {
          enable = true;
          domain = "jellyfin.int.w.phonkd.net";
          auth = false;
          ipfilter = true;
        };
      };
      services.jellyfin.enable = true;
      boot.kernelParams = [ "i915.enable_guc=3" ];

      # Ensure the i915 driver is loaded early
      boot.initrd.kernelModules = [ "i915" ];
      hardware.graphics = {
        enable = true;
        extraPackages = with pkgs; [
          intel-media-driver # The "iHD" driver (Required for 10th Gen+)
          intel-vaapi-driver # Fallback (good to keep)
          libva-vdpau-driver
          libvdpau-va-gl

          # ### THE CRITICAL FIX FOR 10TH GEN+ ###
          intel-compute-runtime # OpenCL/NEO - Required for iHD stability
          vpl-gpu-rt

        ];
      };
      # FIX: Grant the Jellyfin user access to the GPU
      users.users.jellyfin = {
        extraGroups = [
          "render"
          "video"
          "phonkd"
        ];
      };
      # 4. ENVIRONMENT VARIABLES
      # ------------------------
      # Force the correct driver (iHD) instead of the legacy one (i965)
      systemd.services.jellyfin.environment = {
        LIBVA_DRIVER_NAME = "iHD";
      };
      hardware.enableRedistributableFirmware = true;
    };
}
