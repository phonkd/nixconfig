{ withSystem, inputs, lib, pkgs, ... }:

{
  flake.modules.darwin.work-privoxy =
    { pkgs, config, ... }:
    {
      launchd.user.agents.privoxy.command = lib.mkForce ''
          ${config.services.privoxy.package}/bin/privoxy --no-daemon /etc/privoxy-config
        '';

        services.privoxy = {
          enable = true;
          config = let shared = import "/Users/${config.system.primaryUser}/git/bedag-setup/shared/privoxy-config.nix"; in shared.settingsToConfig shared.settings;
          listenAddress = "0.0.0.0:8888";
        };
    };
  flake.nixosModules.work-privoxy = { pkgs, lib, config, ... }:
    let
      shared = import "/home/${config.system.primaryUser}/git/bedag-setup/shared/privoxy-config.nix";
    in
    {
      services.privoxy = {
        enable = true;
        settings = shared.settings;
        listen-address = "0.0.0.0:8888";
      };
      services.pcscd.enable = lib.mkForce true;
      programs.yubikey-manager.enable = lib.mkForce true;
      services.udev.packages = [ pkgs.yubikey-personalization ];
      environment.systemPackages = with pkgs; [
        yubioath-flutter
        distrobox
        distrobox-tui
      ];
    };

}
