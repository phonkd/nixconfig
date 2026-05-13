{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-aislop" = { config, pkgs, lib, ... }:
    {
      phonkds.modules.aislop = {
        ip = "127.0.0.1";
        port = 11111;
        dashboard.enable = true;
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
        host = "openwebui.int.w.phonkd.net";
      };
      nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
        "open-webui"
      ];
    };
}
