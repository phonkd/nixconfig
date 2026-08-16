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
#      offloading to 205 (fallback when the builder VM is offline); any other
#      -flag (e.g. `--hostname`, `--ssh-opts`) is handed to deploy-rs. Wired
#      onto the Mac in modules/hosts/mac.nix and onto every NixOS desktop in
#      modules/desktop.nix (nixosDesktop gate). The package attr is deploy-cli, NOT
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

  mkNode = name: entry: {
    hostname = entry.deploy.hostname;
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
    sshOpts = [
      "-o"
      "ConnectTimeout=10"
      # deploy-rs replaces NIX_SSHOPTS with exactly this list for its
      # `nix copy --to ssh://...` push, so any per-host `IdentitiesOnly yes`
      # in ~/.ssh/config would otherwise force ONLY the configured key. The
      # observability host's block pins a passphrase-locked id_rsa that isn't
      # in the agent, which blocked `deploy observability` even though the
      # agent's ed25519 key is authorized there. IdentitiesOnly=no lets the
      # agent keys be offered alongside the configured one — it never breaks
      # hosts that already authenticate (only widens which keys are tried).
      "-o"
      "IdentitiesOnly=no"
    ];
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
          usage: deploy <host> [branch] [--remote-build] [--hostname <addr>]
                                             deploy one host (branch optional)
                 deploy --all [branch]       deploy every node
                 deploy --list               list deployable hosts

          host is a short alias (201), full name (201-mono), or node key (mono).
          With a branch, builds+deploys that git branch instead of the checkout.
          Builds offload to 205-builder; activation uses magic rollback.
          --remote-build (-r): build on the target host instead of offloading
          to 205 -- use when the builder is down (the target is x86_64-linux and
          can build its own closure natively).
          --hostname <addr>: connect over <addr> instead of the node's registry
          hostname (a tailnet IP). Needed when the deploy carries a tailscale
          update: activation restarts tailscaled and kills the deploy's own ssh
          session mid-activation. E.g. deploy 203 --hostname 192.168.1.203.
          --ssh-opts "<opts>": replace the ssh options, for a rescue path on a
          non-default port/key. Any other -flag is passed on to deploy-rs.
          EOF
          }

          # Pull our own --remote-build/-r out of the args; --hostname and
          # --ssh-opts each swallow a value and go to deploy-rs, as does any
          # other -flag we don't know. The rest are positional (host, branch),
          # so flags may sit anywhere on the line.
          remote_build=0
          passthru=()
          positional=()
          while [ "$#" -gt 0 ]; do
            case "$1" in
              -r | --remote-build) remote_build=1 ;;
              --hostname | --ssh-opts)
                if [ "$#" -lt 2 ]; then
                  echo "deploy: $1 needs a value" >&2
                  exit 1
                fi
                passthru+=( "$1" "$2" )
                shift
                ;;
              -h | --help | -l | --list | --all) positional+=("$1") ;;
              -*) passthru+=("$1") ;;
              *) positional+=("$1") ;;
            esac
            shift
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
          extra=""
          if [ "''${#passthru[@]}" -gt 0 ]; then
            args+=( "''${passthru[@]}" )
            extra=" [deploy-rs: ''${passthru[*]}]"
          fi
          args+=( "$ref" )

          echo ">> deploy: ''${node:-ALL nodes} from ''${branch:-current checkout} (build $where)$extra" >&2
          exec "$deploybin" "''${args[@]}"
        '';
      };
    };
}
