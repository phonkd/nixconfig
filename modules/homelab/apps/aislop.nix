{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-aislop" = { config, pkgs, lib, noughtyLib, ... }:
    lib.mkIf (noughtyLib.hostHasTag "homelab-server") {
      phonkds.modules.aislop = {
        ip = "127.0.0.1";
        port = 11111;
        dashboard.enable = true;
        dashboard.icon = "sh-open-webui";
        traefik = {
          enable = true;
          domain = "openwebui.int.w.phonkd.net";
          auth = false;
          ipfilter = true;
        };
      };
      services.open-webui = {
        enable = true;
        package = inputs.nixpkgs-unstable.legacyPackages.${pkgs.system}.open-webui;
        port = 11111;
        host = "0.0.0.0";
      };
      nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
        "open-webui"
      ];
    };
}
