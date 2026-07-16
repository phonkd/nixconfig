# `deploy <host> [branch]` — a short, agent-friendly wrapper over deploy-rs.
#
# Two things live here:
#
#   1. flake.deploy.nodes   — one deploy-rs node per registry entry that opts in
#      with `deploy.hostname = "<ip>"`. Each activates the host's system profile
#      as root (over ssh as phonkd + sudo; root login is disabled everywhere),
#      with magic rollback so a host that drops off the network after activation
#      reverts itself. Builds run on whatever machine invokes `deploy` — on the
#      Mac that offloads x86_64-linux to 205-builder via nix.buildMachines, so
#      "builds happen on the beefy builder" needs no extra wiring here.
#
#   2. perSystem packages.deploy — the CLI. `deploy 201` deploys 201-mono from
#      the current checkout; `deploy 201 somebranch` builds+deploys that git
#      branch; `deploy --all` does every node. Wired onto the Mac in
#      modules/hosts/mac.nix.
#
# Adding a host to `deploy` = adding `deploy.hostname` to its registry stanza.
# Nothing here is edited per-host.
{
  self,
  inputs,
  lib,
  ...
}:
let
  registry = import ../lib/registry.nix;

  # Opt-in: only entries carrying deploy.hostname become nodes.
  deployEntries = lib.filterAttrs (_: e: (e.deploy or { }) ? hostname) registry;

  mkNode = name: entry: {
    hostname = entry.deploy.hostname;
    profiles.system.path =
      inputs.deploy-rs.lib.${entry.platform or "x86_64-linux"}.activate.nixos
        self.nixosConfigurations.${name};
  };

  # Short alias per node: the numeric prefix ("201-mono" -> "201"), else the
  # full name. Both the alias and the full name resolve in the CLI.
  shortOf =
    name:
    let
      m = builtins.match "([0-9]+)-.*" name;
    in
    if m != null then builtins.head m else name;

  aliasPairs = lib.concatStringsSep " " (
    lib.concatMap (n: [
      "[${shortOf n}]=${n}"
      "[${n}]=${n}"
    ]) (lib.attrNames deployEntries)
  );
in
{
  flake.deploy = {
    sshUser = "phonkd"; # root login is disabled; activate via sudo
    user = "root";
    magicRollback = true;
    autoRollback = true;
    sshOpts = [
      "-o"
      "ConnectTimeout=10"
    ];
    nodes = lib.mapAttrs mkNode deployEntries;
  };

  perSystem =
    { pkgs, system, ... }:
    {
      packages.deploy = pkgs.writeShellApplication {
        name = "deploy";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          # Repo the flake is read from. Override with NIXCONFIG_DIR.
          repo="''${NIXCONFIG_DIR:-$HOME/git/nixconfig}"
          deploybin="${inputs.deploy-rs.packages.${system}.default}/bin/deploy"

          declare -A nodes=( ${aliasPairs} )

          usage() {
            cat >&2 <<EOF
          usage: deploy <host> [branch]     deploy one host (branch optional)
                 deploy --all [branch]       deploy every node
                 deploy --list               list deployable hosts

          host is a short alias (201) or full node name (201-mono).
          With a branch, builds+deploys that git branch instead of the checkout.
          Builds offload to 205-builder; activation uses magic rollback.
          EOF
          }

          case "''${1:-}" in
            "" | -h | --help)
              usage
              exit 0
              ;;
            --list | -l)
              printf '%s\n' "''${!nodes[@]}" | sort -u
              exit 0
              ;;
          esac

          if [ "$1" = "--all" ]; then
            node=""
            branch="''${2:-}"
          else
            node="''${nodes[$1]:-}"
            if [ -z "$node" ]; then
              echo "deploy: unknown host '$1' (try: deploy --list)" >&2
              exit 1
            fi
            branch="''${2:-}"
          fi

          if [ -n "$branch" ]; then
            flake="git+file://$repo?ref=$branch"
          else
            flake="$repo"
          fi
          if [ -n "$node" ]; then
            ref="$flake#$node"
          else
            ref="$flake"
          fi

          echo ">> deploy: ''${node:-ALL nodes} from ''${branch:-current checkout}" >&2
          exec "$deploybin" --skip-checks "$ref"
        '';
      };
    };
}
