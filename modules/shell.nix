{ inputs, self, ... }:

{
  flake.darwinModules.shell = { pkgs, lib, config, ...}:
    {
      environment.systemPackages = with pkgs; [
        uutils-coreutils-noprefix
      ];
    };
  flake.homeModules.shell =
    { pkgs, lib, config, ... }:
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
        };
        siteFunctions = {
          cpp = ''
            cat "$1" | pbcopy
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
        }
        // lib.optionalAttrs pkgs.stdenv.isDarwin {
          # cava reads system audio via BlackHole, which is an *input* device,
          # so macOS gates it behind Microphone (TCC) permission granted to the
          # launching app. kitty is ad-hoc signed and run from /nix/store, so it
          # can't hold a stable TCC grant -- the prompt never fires. Relaunch
          # cava under Terminal.app (Apple-signed, TCC-native) via LaunchServices
          # (`open`, not AppleScript, to avoid needing Automation permission too).
          # First run pops the mic prompt for Terminal.app; Allow once and it
          # sticks. Bare `cava` only; args aren't forwarded through `open`.
          cava = ''
            open -a Terminal.app ${pkgs.cava}/bin/cava
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
      ];
      programs.fzf = {
        enable = true;
        enableZshIntegration = true;
        enableFishIntegration = false;
        # HM master asserts fzf >= 0.73 for this; 26.05 ships 0.72 and nushell is unused
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
      programs.obsidian = {
        enable = true;
      };
    };
}
