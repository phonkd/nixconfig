{ inputs, self, ... }:

{
  flake.homeModules.notes =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    {
      programs.obsidian = {
        enable = true;
      };
    };
  flake.nixosModules."homelab-notes" =
    { config, pkgs, lib, ...}:
    {
      services.memos = {
        enable = true;
      };
      phonkds.modules = {
        paperless = {
          ip = "127.0.0.1";
          port = 5230;
          dashboard = {
            enable = true;
            icon = "memos";
          };
          traefik = {
            enable = true;
            auth = false;
            domain = "memos.int.w.phonkd.net";
            ipfilter = true;
          };
          teleport = {
            enable = true;
            name = "memos";
            rewriteHeaders = [
              "Host: memos.teleport.phonkd.net"
            ];
          };
        };
    };
}
