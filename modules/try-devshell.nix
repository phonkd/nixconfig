{ ... }:

let
  template = ../templates/devshell;
in
{
  # Also usable by hand: nix flake init -t ~/git/nixconfig#devshell
  flake.templates.devshell = {
    path = template;
    description = "numtide devshell (nixpkgs follows, no packages)";
  };

  # New try-rs experiments start as an empty numtide devshell project.
  # try-rs has no create hook, so this wraps its zsh function: when it cd's
  # into a directory that is empty (a fresh `try-rs <name>`; clones and
  # worktrees never are), devshell-init seeds it.
  flake.homeModules.try-devshell =
    { pkgs, lib, ... }:
    let
      devshell-init = pkgs.writeShellApplication {
        name = "devshell-init";
        runtimeInputs = [ pkgs.git pkgs.coreutils ];
        text = ''
          cd "''${1:-.}"
          for f in flake.nix devshell.toml; do
            if [[ -e $f ]]; then
              echo "devshell-init: $PWD/$f already exists" >&2
              exit 1
            fi
          done
          install -m 644 ${template}/flake.nix ${template}/devshell.toml .

          # The dir name becomes the shell's prompt name, TOML-escaped.
          shopt -u patsub_replacement 2>/dev/null || true
          name=$(basename "$PWD")
          name=''${name//\\/\\\\}
          name=''${name//\"/\\\"}
          toml=$(<devshell.toml)
          printf '%s\n' "''${toml/name = \"devshell\"/name = \"$name\"}" > devshell.toml

          # Flakes only see git-tracked files.
          [[ -e .git ]] || git init -q
          git add flake.nix devshell.toml
          echo "devshell-init: seeded $PWD -- run: nix develop" >&2
        '';
      };
    in
    {
      home.packages = [ devshell-init ];
      # After try-rs's own `source <init script>` (default order 1000).
      programs.zsh.initContent = lib.mkOrder 1100 ''
        if (( $+functions[try-rs] )); then
          functions[_try_rs_plain]=$functions[try-rs]
          try-rs() {
            local before=$PWD
            _try_rs_plain "$@" || return
            [[ $PWD != "$before" ]] || return 0
            local -a entries=( *(DN) )
            (( ''${#entries} )) || devshell-init
          }
        fi
      '';
    };
}
