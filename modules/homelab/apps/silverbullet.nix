# SilverBullet -- server-authoritative markdown notes + tasks, co-managed
# with Hermes (see plans/hermes-task-calendar.md). Split the same way as
# hermes.nix: traefik/dashboard registration on the reverse-proxy host (201),
# the actual service on 204-agent, colocated with Hermes so it can edit the
# space (plain .md files) with its terminal toolset -- no API, no replica.
{ inputs, ... }:
{
  flake.nixosModules.homelab-silverbullet =
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
        phonkds.modules.silverbullet = {
          ip = "192.168.3.204";
          port = 9121;
          dashboard.enable = true;
          dashboard.icon = "sh-silverbullet";
          traefik = {
            enable = true;
            domain = "silverbullet.w.phonkd.net";
            auth = false;
            ipfilter = true;
          };
        };
      })

      # ── Service + space permissions + firewall (runs on 204-agent) ────────
      (lib.mkIf (config.noughty.host.name == "204-agent") {
        # SB_USER=<user>:<password> basic-auth line, read by systemd as root.
        sops.secrets."silverbullet-auth" = { };

        services.silverbullet = {
          enable = true;
          # Bind on all interfaces so traefik on 201 can reach it; the
          # firewall rule below limits the port to 201-mono, like the
          # hermes dashboard.
          listenAddress = "0.0.0.0";
          listenPort = 9121;
          # Keep the space at the module default. The nixpkgs module derives
          # systemd's StateDirectory from the LAST path segment of spaceDir,
          # so a nested dir like /var/lib/silverbullet/space would make
          # systemd create /var/lib/space and never the real spaceDir.
          spaceDir = "/var/lib/silverbullet";
          # The permissions bridge to Hermes: run silverbullet with hermes as
          # its primary group so every page it writes is group-owned by
          # hermes, and (with the umask below) group-writable.
          group = "hermes";
          envFile = config.sops.secrets."silverbullet-auth".path;
        };

        systemd.services.silverbullet.serviceConfig = {
          # StateDirectory defaults to 0755 -- hermes couldn't write. No
          # setgid needed: both services' primary group is already hermes.
          StateDirectoryMode = "0770";
          UMask = "0002";
        };
        # Mirror image: pages Hermes creates must stay writable for the
        # silverbullet user (in group hermes), or saving them in the web UI
        # would fail. Group-writable state files are contained: only
        # silverbullet and phonkd are also in the hermes group.
        systemd.services.hermes-agent.serviceConfig.UMask = "0002";

        networking.nftables.enable = true;
        # Allow the silverbullet port from 201-mono only.
        networking.firewall.extraInputRules = ''
          ip saddr 192.168.3.201 tcp dport 9121 accept
        '';
      })
    ];
}
