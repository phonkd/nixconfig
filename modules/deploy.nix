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
#      Node keys are the registry name with any leading "<digits>-" stripped
#      ("201-mono" -> "mono"): deploy-rs parses the node as a Nix attr path, and
#      a bare identifier can't start with a digit ("Unrecognized node or token").
#      The profile still points at the real nixosConfigurations."201-mono".
#
#   2. perSystem packages.deploy-cli — the CLI (binary name `deploy`). `deploy
#      201` deploys 201-mono from the current checkout; `deploy 201 somebranch`
#      builds+deploys that git branch; `deploy --all` does every node;
#      `deploy <host> --remote-build` builds on the target itself instead of
#      offloading to 205 (fallback when the builder VM is offline). Wired onto
#      the Mac in modules/hosts/mac.nix. The package attr is deploy-cli, NOT
#      deploy, so it doesn't collide with the flake.deploy output (deploy-rs
#      evaluates `<flake>#deploy` and must get the schema, not this derivation).
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

  # deploy-rs node key: strip a leading "<digits>-" so it never starts with a
  # digit ("201-mono" -> "mono", "observability" -> "observability").
  nodeNameOf =
    name:
    let
      m = builtins.match "[0-9]+-(.*)" name;
    in
    if m != null then builtins.head m else name;

  # Short numeric alias ("201-mono" -> "201"), else the name itself.
  shortOf =
    name:
    let
      m = builtins.match "([0-9]+)-.*" name;
    in
    if m != null then builtins.head m else name;

  # Applied to every node; a node can add more via `deploy.sshOpts` in the
  # registry (observability's sshd is on :5432 and wants the id_rsa key, so it
  # can't be reached on the default :22).
  commonSshOpts = [
    "-o"
    "ConnectTimeout=10"
  ];

  mkNode = name: entry: {
    hostname = entry.deploy.hostname;
    sshOpts = commonSshOpts ++ (entry.deploy.sshOpts or [ ]);
    profiles.system.path =
      inputs.deploy-rs.lib.${entry.platform or "x86_64-linux"}.activate.nixos
        self.nixosConfigurations.${name};
  };

  # CLI resolves any of: short alias (201), full registry name (201-mono), or
  # node key (mono) -> the node key deploy-rs expects.
  aliasPairs = lib.concatStringsSep " " (
    lib.concatMap (
      n:
      let
        node = nodeNameOf n;
      in
      [
        "[${shortOf n}]=${node}"
        "[${n}]=${node}"
        "[${node}]=${node}"
      ]
    ) (lib.attrNames deployEntries)
  );
in
{
  flake.deploy = {
    sshUser = "phonkd"; # root login is disabled; activate via sudo
    user = "root";
    magicRollback = true;
    autoRollback = true;
    sshOpts = commonSshOpts;
    nodes = lib.mapAttrs' (name: entry: lib.nameValuePair (nodeNameOf name) (mkNode name entry)) deployEntries;
  };

  perSystem =
    { pkgs, system, ... }:
    {
      packages.deploy-cli = pkgs.writeShellApplication {
        name = "deploy";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          # Repo the flake is read from. Override with NIXCONFIG_DIR.
          repo="''${NIXCONFIG_DIR:-$HOME/git/nixconfig}"
          deploybin="${inputs.deploy-rs.packages.${system}.default}/bin/deploy"

          declare -A nodes=( ${aliasPairs} )

          usage() {
            cat >&2 <<EOF
          usage: deploy <host> [branch] [--remote-build]
                                             deploy one host (branch optional)
                 deploy --all [branch]       deploy every node
                 deploy --list               list deployable hosts

          host is a short alias (201), full name (201-mono), or node key (mono).
          With a branch, builds+deploys that git branch instead of the checkout.
          Builds offload to 205-builder; activation uses magic rollback.
          --remote-build (-r): build on the target host instead of offloading
          to 205 -- use when the builder is down (the target is x86_64-linux and
          can build its own closure natively).
          EOF
          }

          # Pull the --remote-build/-r flag out of the args; the rest are
          # positional (host, branch).
          remote_build=0
          positional=()
          for arg in "$@"; do
            case "$arg" in
              -r | --remote-build) remote_build=1 ;;
              *) positional+=("$arg") ;;
            esac
          done
          if [ "''${#positional[@]}" -gt 0 ]; then
            set -- "''${positional[@]}"
          else
            set --
          fi

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

          args=( --skip-checks )
          if [ "$remote_build" = 1 ]; then
            args+=( --remote-build )
            where="on the target host"
          else
            where="offloaded to 205-builder"
          fi
          args+=( "$ref" )

          echo ">> deploy: ''${node:-ALL nodes} from ''${branch:-current checkout} (build $where)" >&2
          exec "$deploybin" "''${args[@]}"
        '';
      };
    };
}
