# Central type declaration for `phonkds.modules.*` — the homelab app
# registry that producers (homelab-*) write into and consumers (traefik,
# dashboard, teleport) read from.
#
# Always-imported because:
#   * Producers may eventually run on hosts other than the reverse proxy;
#     they need the option type in scope to set `phonkds.modules.<x>`.
#   * The consumers (gated on `reverse-proxy`) also need the option in
#     scope. Declaring it everywhere is cheap (empty default) and
#     decouples producer/consumer placement.
#
# Also declares `label.labels`, a freeform host-classification list used
# by a few legacy sites (e.g. 201-mono sets `label.labels = ["vm"]`).
{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules.phonkds-options =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      t = lib.types;
    in
    {
      options.label = {
        labels = lib.mkOption {
          type = t.listOf t.str;
          default = [ ];
          description = "Labels to categorize machines.";
        };
      };
      options.phonkds.modules = lib.mkOption {
        description = "Central definition for all my homelab apps";
        default = { };
        type = t.attrsOf (
          t.submodule (
            { config, ... }:
            {
              options = {
                ip = lib.mkOption { type = t.str; };
                port = lib.mkOption { type = t.int; };
                traefik = {
                  enable = lib.mkOption {
                    type = t.bool;
                    default = false;
                    description = "Enable Traefik Integration";
                  };
                  domain = lib.mkOption {
                    type = t.nullOr t.str;
                    default = null;
                  };
                  auth = lib.mkOption {
                    type = t.bool;
                    default = false;
                  };
                  ipfilter = lib.mkOption {
                    type = t.bool;
                    default = false;
                  };
                  extraMiddlewares = lib.mkOption {
                    type = t.listOf t.str;
                    default = [ ];
                    description = "List of extra middleware names to attach to this router";
                  };
                  scheme = lib.mkOption {
                    type = t.str;
                    default = "http";
                    description = "Protocol scheme (http, https, h2c)";
                  };
                  transport = lib.mkOption {
                    type = t.nullOr t.str;
                    default = null;
                    description = "Custom server transport to use";
                  };
                };
                path = lib.mkOption {
                  type = t.nullOr t.str;
                  default = null;
                  description = "Http path";
                };
                teleport = {
                  enable = lib.mkOption {
                    type = t.bool;
                    default = false;
                    description = "Enable teleport app service for this app";
                  };
                  name = lib.mkOption {
                    type = t.nullOr t.str;
                    default = null;
                    description = "Name for the app that will spawn in teleport";
                  };
                  rewriteHeaders = lib.mkOption {
                    type = t.listOf t.str;
                    default = [ ];
                    description = "List of rewrite headers for the teleport app";
                  };
                  insecure = lib.mkOption {
                    type = t.bool;
                    default = false;
                    description = "Enables insecure";
                  };
                  scheme = lib.mkOption {
                    type = t.str;
                    default = "http";
                    description = "Protocol scheme (http, https)";
                  };
                };
                dashboard = {
                  enable = lib.mkOption {
                    type = t.bool;
                    default = false;
                    description = "Whether to show this service on the dashboard";
                  };
                  icon = lib.mkOption {
                    type = t.nullOr t.str;
                    default = null;
                    description = "Custom icon for the dashboard. Defaults to '<app-name>.png'.";
                  };
                  link = lib.mkOption {
                    type = t.nullOr t.str;
                    default = null;
                    description = "Custom link for the dashboard. Defaults to 'https://<traefik.domain>'.";
                  };
                };
              };
            }
          )
        );
      };
    };
}
