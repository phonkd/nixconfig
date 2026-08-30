{
  withSystem,
  inputs,
  self,
  ...
}:

{
  flake.homeModules.work =
    { pkgs, ... }:
    {
      imports = [
        self.homeModules.work-tools
        self.homeModules.work-external-config
        #self.homeModules.proxy
      ];
    };
  # flake.module.darwin."work" = {pkgs, ...}: {
  #   imports = [
  #     self.modules.darwin.work-privoxy
  #   ];
  # };
  flake.module.nixos."work" = { pkgs, lib, ... }: {
    services.pcscd.enable = lib.mkForce true;
    programs.yubikey-manager.enable = lib.mkForce true;
    services.udev.packages = [ pkgs.yubikey-personalization ];
    environment.systemPackages = with pkgs; [
      yubioath-flutter
    ];
  };
}
