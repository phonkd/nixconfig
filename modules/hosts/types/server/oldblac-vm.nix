{
  inputs,
  lib,
  self,
  ...
}:
{
  flake.nixosModules.oldblac-vm =
    { modulesPath, lib, ... }:
    {
      imports = [
        (modulesPath + "/profiles/qemu-guest.nix")
      ];
      fileSystems."/" = {
        device = "/dev/disk/by-uuid/f222513b-ded1-49fa-b591-20ce86a2fe7f";
        fsType = "ext4";
      };

      fileSystems."/boot" = {
        device = "/dev/disk/by-uuid/12CE-A600";
        fsType = "vfat";
      };
      nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
      label.labels = [ "vm" ];
      boot.loader.grub.device = "/dev/vda";
      boot.initrd.availableKernelModules = [
        "ata_piix"
        "uhci_hcd"
        "virtio_pci"
        "virtio_scsi"
        "virtio_blk"
        "sd_mod"
        "sr_mod"
      ];
      boot.initrd.kernelModules = [ ];
      boot.kernelModules = [ ];
      boot.extraModulePackages = [ ];
      services.qemuGuest.enable = true;
      boot.loader.grub.enable = true;
      boot.loader.grub.useOSProber = true;
      networking.defaultGateway = "192.168.3.1";
      networking.nameservers = [
        "192.168.3.201"
        "192.168.3.1"
      ];
    };
}
