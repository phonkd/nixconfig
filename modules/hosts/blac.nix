{
  self,
  inputs,
  ...
}:
{
  imports = [
    inputs.home-manager.flakeModules.home-manager
  ];

  flake.nixosConfigurations."blac" = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      /etc/nixos/hardware-configuration.nix
      inputs.home-manager.nixosModules.home-manager
      {
        # home-manager.users.phonkd.imports = [
        #   self.homeModules.gui-nixos
        # ];
      }
      self.nixosModules.gui
      self.nixosModules.blac
      self.nixosModules.nvidia-desktop
    ];
  };
  flake.nixosModules.blac =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      system.stateVersion = "26.05";
      users.users.phonkd.extraGroups = [ "dialout" ];
      networking.networkmanager.enable = true;
      # Use declarative networking with secondary IP
      #networking.useDHCP = true;
      networking.hostName = "blac";
      networking.nameservers = [
        "192.168.1.201"
        "1.1.1.1"
      ];

      # Disable IPv6
      networking.enableIPv6 = false;
      networking.nat.externalInterface = lib.mkForce "enp9s0";

      boot.loader.systemd-boot.enable = true;
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

      boot.kernelParams = [
        #"pcie_aspm=off"
        "pci=noaer"
        "btusb.enable_autosuspend=n"
        "amd_iommu=on"
        "iommu=nopt"
      ];

      hardware.nvidia = {
        open = true;
        modesetting.enable = true;
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
        #acceleration = "cuda";
      };

      environment.etc."libinput/local-overrides.quirks".text = ''
        [Company Mouse Debounce Override]
        MatchName=*COMPANY*USB*Device*
        ModelBouncingKeys=1
      '';
    };

}
