{
  inputs,
  lib,
  self,
  ...
}:
{
  flake.nixosModules.oldblac-server = {
    imports = [
      #(modulesPath + "/profiles/qemu-guest.nix")
    ];
    fileSystems."/" = lib.mkDefault {
      device = "/dev/disk/by-path/pci-0000:01:01.0-scsi-0:0:0:0-part/by-partnum/1";
      fsType = "ext4";
      autoResize = true;
    };
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
    boot.loader.grub.device = lib.mkDefault "/dev/sda";
    boot.loader.grub.useOSProber = true;
  };
}
