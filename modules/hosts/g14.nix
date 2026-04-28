{
  self,
  inputs,
  ...
}:
{
  imports = [
    inputs.home-manager.flakeModules.home-manager
  ];

  flake.nixosConfigurations."g14" = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      /etc/nixos/hardware-configuration.nix
      inputs.home-manager.nixosModules.home-manager
      {
        home-manager.backupFileExtension = "hm-backup";
      }
      self.nixosModules.gui
      self.nixosModules.g14
      self.nixosModules.nvidia-desktop
      self.nixosModules.gigaplayer-client
    ];
  };
  flake.nixosModules.g14 =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        "${builtins.fetchGit { url = "https://github.com/NixOS/nixos-hardware.git"; }}/asus/zephyrus/ga401"
      ];
      programs.steam.enable = true;
      hardware.bluetooth.enable = true;
      system.stateVersion = "26.05";
      users.users.phonkd.extraGroups = [ "dialout" ];
      networking.networkmanager.enable = true;
      # Use declarative networking with secondary IP
      networking.hostName = "g14";
      networking.nameservers = [
        "192.168.1.201"
        "1.1.1.1"
      ];

      # Disable IPv6
      #networking.enableIPv6 = false;
      #networking.nat.externalInterface = lib.mkForce "enp9s0";

      boot.loader.systemd-boot.enable = false;
      boot.loader.limine = {
        enable = true;
        # secureBoot.enable = true;
      };
      boot.loader.efi.canTouchEfiVariables = true;
      services.hardware.bolt.enable = true;

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
      environment.etc."libinput/local-overrides.quirks".text = ''
        [Company Mouse Debounce Override]
        MatchName=*COMPANY*USB*Device*
        ModelBouncingKeys=1
      '';
      systemd.tmpfiles.rules = [
        "w /sys/devices/system/cpu/cpufreq/boost - - - - 0"
      ];
      hardware.nvidia.prime = {
        offload.enable = lib.mkForce false;
        reverseSync.enable = true;
        allowExternalGpu = true;
      };
      programs.rog-control-center.enable = true;
      boot.extraModprobeConfig = ''
        options nvidia NVreg_EnableGpuFirmware=0
      '';
      hardware.nvidia = {
        open = false;
        powerManagement.enable = false;
        #allowExternalGpu = true;
      };
      systemd.services.nvidia-powerd = {
        unitConfig.StartLimitAction = "none";
        serviceConfig.Restart = "no";
        wantedBy = lib.mkForce [ ];
      };
      services.upower.enable = true;
    };

}
