{ ... }:
{
  flake.nixosModules."207-iot" =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    lib.mkIf (config.noughty.host.name == "207-iot") {
      label.labels = [ "vm" ];
      networking.hostName = "207-iot";
      networking.interfaces.ens18.ipv4.addresses = [
        {
          address = "192.168.1.207";
          prefixLength = 24;
        }
      ];
      networking.defaultGateway = lib.mkForce "192.168.1.1";
      networking.nameservers = lib.mkForce [ "192.168.1.1" ];
      security.sudo.wheelNeedsPassword = false;
      networking.firewall.allowedTCPPorts = [
        22
        8123
      ];
      networking.firewall.allowedUDPPorts = [ 5353 ];

      services.home-assistant = {
        enable = true;
        extraComponents = [
          "default_config"
          "apple_tv"
          "yamaha"
          "yamaha_musiccast"
          "wake_on_lan"
          "jellyfin"
          "spotify"
          "met"
          "google_translate"
          "radio_browser"
          "mystrom"
        ];
      };
    };
}
