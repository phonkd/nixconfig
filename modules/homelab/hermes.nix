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
            domain = "hermes.w.phonkd.net";
            auth = false;
            ipfilter = true;
          };
        };
      })

      # ── Dashboard service + auth + firewall (runs on 204-agent) ──────────
      (lib.mkIf (config.noughty.host.name == "204-agent") {
        # Username lives in config.yaml (not sensitive).
        services.hermes-agent.settings.dashboard.basic_auth.username = "phonkd";

        # Password hash from sops — decrypted at activation, injected into
        # config.yaml by the activation script below (never hits the nix store).
        sops.secrets."hermes-dashboard-pw-hash" = {
          owner = config.services.hermes-agent.user;
        };

        # Runs after sops decryption and after the hermes-agent-setup script
        # that writes config.yaml. Uses jq to upsert the password_hash field.
        system.activationScripts."hermes-dashboard-auth" =
          lib.stringAfter [ "hermes-agent-setup" "setupSecrets" ] ''
            _cfg="${config.services.hermes-agent.stateDir}/.hermes/config.yaml"
            _hash_file="${config.sops.secrets."hermes-dashboard-pw-hash".path}"
            if [ -f "$_hash_file" ] && [ -f "$_cfg" ]; then
              _hash="$(cat "$_hash_file")"
              ${pkgs.jq}/bin/jq --arg h "$_hash" \
                '.dashboard.basic_auth.password_hash = $h' \
                "$_cfg" > "$_cfg.tmp" && mv "$_cfg.tmp" "$_cfg"
              chown ${config.services.hermes-agent.user}:${config.services.hermes-agent.group} "$_cfg"
            fi
          '';

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
            ExecStart = "${config.services.hermes-agent.package}/bin/hermes dashboard --host 0.0.0.0 --port 9119 --no-open";
            Restart = "on-failure";
            RestartSec = 5;
          };
        };

        # nftables (extraInputRules) — allow 9119 from 201-mono only.
        networking.firewall.extraInputRules = ''
          ip saddr 192.168.3.201 tcp dport 9119 accept
        '';
      })
    ];
}
