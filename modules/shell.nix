{ inputs, self, ... }:

{
  flake.darwinModules.shell = { pkgs, lib, config, ...}:
    {
      environment.systemPackages = with pkgs; [
        uutils-coreutils-noprefix
      ];
    };
  flake.homeModules.shell =
    { pkgs, lib, config, options, ... }:
    {
      imports = [
        inputs.kubectl-aliases.homeManagerModules.default
        inputs.try-rs.homeModules.default
      ];
      home.sessionPath = [
        "$HOME/.local/bin"
      ];
      programs.try-rs = {
        enable = true;
      };
      programs.nix-your-shell.enable = true;
      programs.kubectl-aliases.enable = true;
      programs.zsh = {
        enable = true;

        shellAliases = {
          stealmusic = "yt-dlp -x --audio-format mp3 --embed-thumbnail --embed-metadata";
          k = lib.mkDefault "kubecolor";
          mystrom = "curl http://192.168.1.19/toggle";
          nix-shell = "NIXPKGS_ALLOW_UNFREE=1 nix shell --impure";
          kn = "kubens";
          kgp = "kubectl get pods";
          kgpw = "watch kubectl get pods";
          zed = "zeditor";
        };
        siteFunctions = {
          cpp = ''
            cat "$1" | pbcopy
          '';
          clip = ''
            "$@" 2>&1 | tee /dev/tty | pbcopy
          '';
          clipp = ''
            tee /dev/tty | pbcopy
          '';
          kgi = ''
            kubectl get ingress "$@" -o custom-columns="NAME:.metadata.name,HOST:.spec.rules[*].host,PATH:.spec.rules[*].http.paths[*].path,BACKEND:.spec.rules[*].http.paths[*].backend.service.name"
          '';
          jj = ''
            if git rev-parse --is-inside-work-tree &>/dev/null; then
              local email name
              email=$(git config user.email 2>/dev/null)
              name=$(git config user.name 2>/dev/null)
              if [[ -n "$email" && -n "$name" ]]; then
                command jj --config "user.email=\"$email\"" --config "user.name=\"$name\"" "$@"
                return
              fi
            fi
            command jj "$@"
          '';
        };
        enableCompletion = true;
        completionInit = ''
          autoload -U compinit && compinit
          zstyle ':completion:*' menu select
        '';
        autosuggestion.enable = true;
        plugins = [
          {
            name = "fzf-tab";
            src = pkgs.zsh-fzf-tab;
            file = "share/fzf-tab/fzf-tab.plugin.zsh";
          }
        ];
        initContent = ''
          bindkey -e
          bindkey '^I' expand-or-complete
          bindkey '^K' fzf-tab-complete
          bindkey '^[[1;5C' forward-word
          bindkey '^[[1;5D' backward-word
          bindkey '^[[H' beginning-of-line
          bindkey '^[[F' end-of-line

          # Ctrl-R: fzf's picker over atuin's history, which (unlike zsh's)
          # remembers the directory each command ran in. ctrl-d narrows to
          # the current dir -- e.g. a try-rs scratch dir's tunnels and dumps.
          # --reverse is newest-first, despite atuin's help calling it oldest-first.
          _atuin_fzf_history() {
            local selected
            selected=$(atuin search --cmd-only --print0 --reverse --filter-mode global |
              fzf --read0 --scheme=history --highlight-line --query="$LBUFFER" \
                --prompt='all> ' --header='ctrl-d: this dir · ctrl-g: everywhere' \
                --bind='ctrl-d:reload(atuin search --cmd-only --print0 --reverse --filter-mode directory)+change-prompt(dir> )' \
                --bind='ctrl-g:reload(atuin search --cmd-only --print0 --reverse --filter-mode global)+change-prompt(all> )'
            ) && LBUFFER=$selected
            zle reset-prompt
          }
          zle -N _atuin_fzf_history
          bindkey '^R' _atuin_fzf_history
        '';
        history = {
          size = 1000000;
          path = "${config.home.homeDirectory}/.zsh_history";
        };
      };
      programs.starship = {
        enable = true;
        enableZshIntegration = true;
        enableFishIntegration = true;
        presets = [ "nerd-font-symbols" ];
        settings = {
          kubernetes = {
            disabled = false;
          };
          git_branch = {
            style = "bold green";
          };
        };
      };
      programs.zoxide = {
        enable = true;
        enableZshIntegration = true;
        enableFishIntegration = true;
      };
      programs.kubecolor = {
        enable = true;
        enableZshIntegration = true;
        enableAlias = true;
      };
      home.packages = with pkgs; [
        nerd-fonts.symbols-only
        jq
        ffmpeg
        sshpass
        wget
        kubectl
        kubectx
        kubectl-view-secret
        kube-capacity
        kubernetes-helm
        clusterctl
        kubectx
        kconf
        kustomize
        kustomize-sops
        k9s
        stern
        tree
        minio-client
        yq
        sops
        prek
        curl
        fd
        ripgrep
        gh
        iftop
        gnused
      ];
      # atuin only records history; Ctrl-R stays an fzf picker (initContent).
      programs.atuin = {
        enable = true;
        flags = [
          "--disable-ctrl-r"
          "--disable-up-arrow"
        ];
        settings.update_check = false;
      };
      programs.fzf = {
        enable = true;
        enableZshIntegration = true;
        enableFishIntegration = false;
      }
      # "" drops fzf's own ^R binding in favour of _atuin_fzf_history. Guarded
      # like the option below: android's pinned home-manager only has the older
      # historyWidgetCommand spelling.
      // lib.optionalAttrs (options.programs.fzf ? historyWidget) {
        historyWidget.command = "";
      }
      # HM master asserts fzf >= 0.73 for this; 26.05 ships 0.72 and nushell is
      # unused. Guarded on the option existing because the android host pins a
      # pre-May-2026 home-manager (see nixpkgs-android in flake.nix) that
      # predates the option -- there, false is already the behaviour.
      // lib.optionalAttrs (options.programs.fzf ? enableNushellIntegration) {
        enableNushellIntegration = false;
      };
      programs.btop = {
        enable = true;
      };
      programs.bat = {
        enable = true;
      };
      programs.eza = {
        enable = true;
        enableZshIntegration = true;
      };
    };
}
