{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules.gigaplayer-client =
    { pkgs, ... }:
    {
      systemd.user.services.pipewire-network-sink = {
        description = "Load PipeWire Network Sink for 203-spot";
        after = [ "pipewire-pulse.service" ];
        bindsTo = [ "pipewire-pulse.service" ];
        wants = [ "pipewire-pulse.service" ];
        wantedBy = [ "default.target" ];
        script = ''
          ${pkgs.pulseaudio}/bin/pactl load-module module-tunnel-sink server=tcp:192.168.1.203:4713 sink_name=spot-203
        '';
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = "10s";
          RemainAfterExit = true;
        };
      };
    };
  flake.nixosModules.gigaplayer-server =
    {
      pkgs,
      lib,
      ...
    }:
    {
      # 1. Audio Setup (PipeWire System-Wide)
      security.rtkit.enable = true;
      services.pipewire = {
        enable = lib.mkForce true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
        systemWide = true;
        raopOpenFirewall = true;
        extraConfig.pipewire-pulse."99-network" = {
          "pulse.cmd" = [
            {
              cmd = "load-module";
              args = "module-native-protocol-tcp port=4713 listen=0.0.0.0 auth-anonymous=1";
            }
          ];
        };

      };
      systemd.services.pipewire-pulse.wantedBy = [ "multi-user.target" ];

      services.spotifyd = {
        enable = true;
        settings = {
          global = {
            device_name = "nixos-headless";
            backend = "pulseaudio";
            use_mpris = false;
            bitrate = 320;
            cache_path = "/var/cache/spotifyd";
            volume_controller = "softvol";
            zeroconf_port = 57621;
            max_cache_size = 5000000000; # like 5gb for max cache size so disk doesnt fill up
          };
        };
      };

      # 4. Networking & Firewall
      networking = {
        nftables.enable = true;
        firewall = {
          enable = true;
          allowedTCPPorts = [
            57621 # Spotify Connect
            4713 # PulseAudio Network
            12345
            7000 # AirPlay
            7100 # AirPlay
            7011 # AirPlay
            #8085 # noVNC Web Interface
          ];
          allowedUDPPorts = [
            5353 # mDNS (Avahi)
            6000
            6001
            7011
          ];
          extraInputRules = ''
            # Allow noVNC (8085) only from the Traefik VM
            ip saddr 192.168.1.201 tcp dport 8085 accept
          '';
        };
      };

      # 5. User Permissions
      users.users.spotifyd = {
        extraGroups = [
          "audio"
          "pipewire"
        ];
        isSystemUser = true;
        group = "spotifyd";
      };
      users.groups.spotifyd = { };

      # 3. EasyEffects Web GUI (X11 + VNC + noVNC)
      # Broadway failed due to Qt dependencies in EasyEffects.
      # We switch to a robust Xvfb -> x11vnc -> noVNC stack.

      users.users.easyeffects = {
        isSystemUser = true;
        group = "easyeffects";
        extraGroups = [
          "audio"
          "pipewire"
        ];
        home = "/var/lib/easyeffects";
        createHome = true;
      };
      users.groups.easyeffects = { };

      systemd.services.headless-gui = {
        description = "EasyEffects Headless Session (noVNC)";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network.target"
          "pipewire.service"
        ];
        requires = [ "pipewire.service" ];

        environment = {
          "DISPLAY" = ":5";
          "PIPEWIRE_RUNTIME_DIR" = "/run/pipewire";
          "PULSE_SERVER" = "unix:/run/pulse/native";
          "PULSE_RUNTIME_PATH" = "/run/pulse";
          "XDG_RUNTIME_DIR" = "/run/easyeffects";
          "XDG_CONFIG_HOME" = "/var/lib/easyeffects/.config";
          "XDG_CACHE_HOME" = "/var/lib/easyeffects/.cache";
          "XDG_DATA_HOME" = "/var/lib/easyeffects/.local/share";
          "GDK_BACKEND" = "x11";
          "QT_QPA_PLATFORM" = "xcb";
          "LIBGL_ALWAYS_SOFTWARE" = "1";
          "QT_XCB_GL_INTEGRATION" = "none";
          "QT_QUICK_BACKEND" = "software";
          "QMLSCENE_DEVICE" = "softwarecontext";
        };

        path = with pkgs; [
          bash
          procps
          xorg.xorgserver
          xorg.xauth
          x11vnc
          python3Packages.websockify
          dbus
          easyeffects
          openbox
          bluez
          bluez-tools
        ];

        script = ''
          # Use a dbus session for the entire stack
          exec ${pkgs.dbus}/bin/dbus-run-session -- bash -c '
            cleanup() {
              echo "Cleaning up child processes..."
              kill $XVFB_PID $OPENBOX_PID $X11VNC_PID $WEBSOCKIFY_PID 2>/dev/null || true
              wait
            }
            trap cleanup EXIT

            # 1. Start Xvfb
            Xvfb :5 -screen 0 1920x1080x24 &
            XVFB_PID=$!
            sleep 2

            # 2. Start openbox window manager
            openbox &
            OPENBOX_PID=$!
            sleep 1

            # 3. Start VNC Server
            x11vnc -display :5 -forever -shared -nopw -q &
            X11VNC_PID=$!
            sleep 1

            # 4. Start WebSockify
            ${pkgs.python3Packages.websockify}/bin/websockify --web ${pkgs.novnc}/share/webapps/novnc 8085 localhost:5900 &
            WEBSOCKIFY_PID=$!
            sleep 1

            # 5. Start EasyEffects (blocking foreground process)
            easyeffects
          '
        '';

        serviceConfig = {
          User = "easyeffects";
          Group = "easyeffects";
          Restart = "always";
          RestartSec = "5s";
          RuntimeDirectory = "easyeffects";
          RuntimeDirectoryMode = "0700";
          KillMode = "control-group";
          TimeoutStopSec = "10s";
          # preStart needs root to kill orphaned Xvfb and clean /tmp
          ExecStartPre = [
            "+${pkgs.bash}/bin/bash -c '${pkgs.procps}/bin/pkill -9 -x Xvfb || true; sleep 1; rm -f /tmp/.X5-lock /tmp/.X11-unix/X5 /tmp/easyeffects.lock; mkdir -p /var/lib/easyeffects/.config /var/lib/easyeffects/.cache /var/lib/easyeffects/.local/share; chown -R easyeffects:easyeffects /var/lib/easyeffects'"
          ];
        };
      };
      ## AirPlay receiver (uxplay)
      services.avahi = {
        enable = true;
        nssmdns4 = true;
        publish = {
          enable = true;
          userServices = true;
        };
      };

      systemd.services.uxplay = {
        description = "UxPlay AirPlay Receiver";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network.target"
          "pipewire.service"
          "avahi-daemon.service"
        ];
        requires = [
          "pipewire.service"
          "avahi-daemon.service"
        ];

        environment = {
          "PIPEWIRE_RUNTIME_DIR" = "/run/pipewire";
        };

        serviceConfig = {
          ExecStart = "${pkgs.uxplay}/bin/uxplay -n nixos-headless -vs 0 -as pulsesink -p";
          User = "uxplay";
          Group = "uxplay";
          Restart = "always";
          SupplementaryGroups = [
            "audio"
            "pipewire"
          ];
        };
      };

      users.users.uxplay = {
        isSystemUser = true;
        group = "uxplay";
      };
      users.groups.uxplay = { };

      ## bluetooth receiver
      #
      hardware.bluetooth = {
        enable = true;
        powerOnBoot = true;
        settings = {
          General = {
            # Explicitly enable A2DP Sink (receiver) and Source (transmitter) roles
            Enable = "Source,Sink,Media,Socket";
            # Experimental enables battery percentage reporting and other features
            Experimental = false;
          };
        };
      };
    };

}
