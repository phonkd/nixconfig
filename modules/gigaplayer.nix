{
  self,
  inputs,
  ...
}:
{
  # Self-gates on the "gigaplayer-client" host tag.
  flake.nixosModules.gigaplayer-client =
    {
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    lib.mkIf (noughtyLib.hostHasTag "gigaplayer-client") {
      systemd.user.services.pipewire-network-sink = {
        description = "Load PipeWire Network Sink for 203-media";
        after = [ "pipewire-pulse.service" ];
        bindsTo = [ "pipewire-pulse.service" ];
        wants = [ "pipewire-pulse.service" ];
        wantedBy = [ "default.target" ];
        script = ''
          ${pkgs.pulseaudio}/bin/pactl load-module module-tunnel-sink server=tcp:192.168.3.201:4713 sink_name=spot-201
        '';
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = "10s";
          RemainAfterExit = true;
        };
      };
    };
  # Self-gates on the "gigaplayer-server" host tag.
  #
  # "beatnikl" -- a Snapcast multiroom server (the byrdsandbytes/beatnik-pi
  # stack, rebuilt declaratively). snapserver receives AirPlay and Spotify
  # and broadcasts the PCM to snapclients on the network; it does NOT play
  # audio locally. snapserver spawns shairport-sync / librespot itself in
  # pipe mode (each writes PCM to snapserver's stdin), so no local sink,
  # PipeWire, or sound card is involved -- this host is purely the server.
  flake.nixosModules.gigaplayer-server =
    {
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    lib.mkIf (noughtyLib.hostHasTag "gigaplayer-server") (
      let
        # Advertised name on AirPlay / Spotify Connect discovery.
        deviceName = "beatnikl";
        # Pinned so the Spotify Connect handshake port is firewall-knowable
        # (librespot's libmdns otherwise picks a random one).
        spotifyZeroconfPort = 5040;
      in
      {
        # Snapcast server. snapserver spawns the AirPlay / Spotify sources and
        # streams their audio to snapclients (port 1704). Control + web UI
        # (snapweb) live on 1705 / 1780.
        services.snapserver = {
          enable = true;
          openFirewall = true; # opens 1704 (audio), 1705 (control), 1780 (http)
          settings = {
            stream.source = [
              # AirPlay 1 -- snapserver runs shairport-sync with the stdout
              # backend; appears as "${deviceName}" on AirPlay discovery.
              "airplay://${pkgs.shairport-sync}/bin/shairport-sync?name=Airplay&devicename=${deviceName}&port=5000"
              # Spotify Connect -- snapserver runs librespot in zeroconf
              # discovery mode (no credentials needed); built with-libmdns.
              "librespot://${lib.getExe pkgs.librespot}?name=Spotify&devicename=${deviceName}&bitrate=320&volume=100&params=--zeroconf-port=${toString spotifyZeroconfPort}"
            ];
            http.enabled = true; # snapweb + JSON-RPC over HTTP on :1780
            tcp-control.enabled = true; # JSON-RPC over TCP on :1705
          };
        };

        # mDNS: lets AirPlay senders, Spotify, and snapclients discover the
        # server. mkDefault so it coexists with hosts that already enable
        # avahi (e.g. 203-shares on 203-media).
        services.avahi = {
          enable = lib.mkDefault true;
          publish = {
            enable = lib.mkDefault true;
            userServices = lib.mkDefault true;
          };
        };

        # Web UI: snapserver serves the built-in snapweb UI on :1780
        # (services.snapserver.settings.http) -- no separate container needed.

        # snapserver.openFirewall covers 1704/1705/1780. Open the rest of the
        # Snapcast/AirPlay/Spotify surface.
        networking.firewall = {
          allowedTCPPorts = [
            5000 # shairport-sync RTSP (AirPlay)
            spotifyZeroconfPort # librespot Spotify Connect handshake
          ];
          allowedUDPPorts = [
            5353 # mDNS (Avahi + librespot libmdns)
          ];
          allowedUDPPortRanges = [
            {
              from = 6000;
              to = 6009;
            } # shairport-sync timing / control / audio
          ];
        };
      }
    );

}
