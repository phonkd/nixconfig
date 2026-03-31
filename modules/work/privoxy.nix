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
}
