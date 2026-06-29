{ inputs, ... }:
{
  # Always-imported cross-host module (see modules/builder.nix alwaysImport).
  #
  # reverse-proxy section: registers hermes-dashboard in phonkds.modules so
  #   Traefik on 201-mono routes hermes.w.phonkd.net → 192.168.3.204:9119.
  #
  # 204-agent section: runs the dashboard process + restricts port 9119 in
  #   the firewall to traffic from 201-mono (192.168.3.201) only.
  #   Auth: username in settings; bcrypt password hash read from
  #   sops secret "hermes-dashboard-pw-hash" and injected into config.yaml
  #   at activation time (keeps plaintext password out of the nix store).
  flake.nixosModules.homelab-hermes =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    lib.mkMerge [
      # ── Traefik registration (runs on 201-mono) ───────────────────────────
      (lib.mkIf (noughtyLib.hostHasTag "reverse-proxy") {
        phonkds.modules.hermes-dashboard = {
          ip = "192.168.3.204";
          port = 9119;
          dashboard.enable = true;
          traefik = {
            enable = true;
            domain = "hermes-dashboard.int.w.phonkd.net";
            auth = false;
            ipfilter = true;
          };
        };
      })

      # ── Dashboard service + auth + firewall (runs on 204-agent) ──────────
      (lib.mkIf (config.noughty.host.name == "204-agent") {
        # Bind to 0.0.0.0 so Traefik on 201 can reach it; the firewall rule
        # below restricts access to 201-mono only at the network level.
        systemd.services.hermes-dashboard = {
          description = "Hermes Agent Dashboard";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" "hermes-agent.service" ];
          wants = [ "network-online.target" "hermes-agent.service" ];

          environment = {
            HOME = config.services.hermes-agent.stateDir;
            HERMES_HOME = "${config.services.hermes-agent.stateDir}/.hermes";
          };

          serviceConfig = {
            User = config.services.hermes-agent.user;
            Group = config.services.hermes-agent.group;
            ExecStart =
              let
                svc = config.services.hermes-agent;
                pkg = if svc.extraDependencyGroups == [] && svc.extraPythonPackages == []
                  then svc.package
                  else svc.package.override {
                    inherit (svc) extraDependencyGroups extraPythonPackages;
                  };
              in "${pkg}/bin/hermes dashboard --host 0.0.0.0 --port 9119 --no-open";
            Restart = "on-failure";
            RestartSec = 5;
          };
        };

        # ── Apple TV control (atvremote / pyatv) ──────────────────────────────
        # Lets Hermes drive the living-room Apple TV ("Wohnzimmer").
        # atvremote runs headless and can't multicast-scan across subnets, so the
        # agent addresses the device by IP (-s "$ATV_IP") and passes the Companion
        # credentials directly (--companion-credentials "$ATV_COMPANION_CREDENTIALS").
        # The credentials grant control of the device, so they come from sops as an
        # env-file (ATV_COMPANION_CREDENTIALS=...) and never hit the nix store.
        # Typical call:
        #   atvremote --storage none -s "$ATV_IP" \
        #     --companion-credentials "$ATV_COMPANION_CREDENTIALS" launch_app=com.spotify.client
        services.hermes-agent.extraPackages = [ pkgs.python313Packages.pyatv ];
        systemd.services.hermes-agent.environment = {
          ATV_ID = "42E23540-E5EA-4C05-A5EC-FB0E1F23F820";
          ATV_IP = "192.168.1.135";
        };
        sops.secrets."hermes-pyatv" = {
          owner = config.services.hermes-agent.user;
        };
        services.hermes-agent.environmentFiles = [
          config.sops.secrets."hermes-pyatv".path
        ];

        networking.nftables.enable = true;
        # Allow hermes dashboard port from 201-mono only.
        networking.firewall.extraInputRules = ''
          ip saddr 192.168.3.201 tcp dport 9119 accept
        '';
      })
    ];
}
