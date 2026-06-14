{ ... }:
{
  flake.nixosModules."ext-mail" =
    {
      config,
      pkgs,
      lib,
      modulesPath,
      ...
    }:
    {
      imports = [
        (modulesPath + "/profiles/qemu-guest.nix")
      ];
      config = lib.mkIf (config.noughty.host.name == "ext-mail") {
        networking.hostName = "ext-mail";
        services.openssh = {
          enable = true;
          ports = [ 5432 ];
          openFirewall = true;
          settings = {
            PasswordAuthentication = false;
            KbdInteractiveAuthentication = false;
            PermitRootLogin = "no";
            AllowUsers = [ "phonkd" ];
          };
        };
        boot.loader.systemd-boot.configurationLimit = 10;
        time.timeZone = lib.mkDefault "Europe/Zurich";
        i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";
        services.xserver.xkb = lib.mkDefault {
          layout = "ch";
          variant = "";
        };
        console.keyMap = lib.mkDefault "sg";
        users.users.phonkd = {
          isNormalUser = true;
          description = "phonkd";
          extraGroups = [
            "networkmanager"
            "wheel"
            "docker"
          ];
        };
        security.sudo.wheelNeedsPassword = false;
        sops.age.keyFile = "/home/phonkd/.config/sops/age/keys.txt";
        sops.defaultSopsFile = ./secrets/secret.yaml;
        virtualisation.docker.enable = true;
        system.stateVersion = lib.mkForce "26.05";

        boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
        boot.initrd.kernelModules = [ ];
        boot.kernelModules = [ ];
        boot.extraModulePackages = [ ];
        boot.loader.grub = {
          enable = true;
          efiSupport = true;
          efiInstallAsRemovable = true;
          device = "nodev";
        };
        boot.loader.efi.efiSysMountPoint = "/efi";
        fileSystems."/" = {
          device = "/dev/disk/by-uuid/4c720436-405e-43af-abed-be474257acd9";
          fsType = "ext4";
        };
        fileSystems."/efi" = {
          device = "systemd-1";
          fsType = "autofs";
        };
        swapDevices = [ ];
        networking.useDHCP = lib.mkDefault true;
        nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
      };
    };
}
