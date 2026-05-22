# Host-specific NixOS config for blac.
#
# This file used to wire `flake.nixosConfigurations.blac` by hand and
# pick a module list. That responsibility moved to lib/registry.nix +
# modules/_builder.nix. Here we only declare what the *blac* host should
# do, and self-gate so the module is safe to import into any host.
{ ... }:
{
  flake.nixosModules.blac =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    lib.mkIf (config.noughty.host.name == "blac") {
      programs.steam.enable = true;
      hardware.bluetooth.enable = true;
      system.stateVersion = "26.05";
      users.users.phonkd.extraGroups = [ "dialout" ];
      networking.networkmanager.enable = true;
      networking.hostName = "blac";
      networking.nameservers = [
        "192.168.3.201"
        "1.1.1.1"
      ];

      networking.enableIPv6 = false;
      networking.nat.externalInterface = lib.mkForce "enp9s0";

      boot.loader.systemd-boot.enable = false;
      boot.loader.limine = {
        enable = true;
        secureBoot.enable = true;
      };
      boot.loader.efi.canTouchEfiVariables = true;
      services.hardware.bolt.enable = true;
      services.gvfs.enable = true;

      services.xserver.enable = true;

      services.greetd = {
        enable = true;
        settings = {
          default_session = {
            command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --remember --cmd start-hyprland";
            user = "greeter";
          };
        };
      };

      boot.kernelParams = [
        "pci=noaer"
        "btusb.enable_autosuspend=n"
        "amd_iommu=on"
        "iommu=nopt"
      ];

      hardware.nvidia = {
        open = true;
        modesetting.enable = true;
        powerManagement.enable = true;
        package = config.boot.kernelPackages.nvidiaPackages.latest;
      };

      environment.systemPackages = with pkgs; [
        cudatoolkit
      ];

      services.sunshine = {
        enable = false;
        autoStart = true;
        capSysAdmin = true;
        openFirewall = true;
      };
      services.ollama = {
        enable = true;
      };

      environment.etc."libinput/local-overrides.quirks".text = ''
        [Company Mouse Debounce Override]
        MatchName=*COMPANY*USB*Device*
        ModelBouncingKeys=1
      '';
    };
}
