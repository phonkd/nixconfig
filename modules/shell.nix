{ inputs, ... }:

{
  flake.homeModules.shell =
    { pkgs, config, ... }:
    {
      programs.zsh = {
        enable = true;

        shellAliases = {
          stealmusic = "yt-dlp -x --audio-format mp3 --embed-thumbnail --embed-metadata";
        };
        siteFunctions = {
          cpp = ''
            cat "$1" | pbcopy
          '';
        };
        enableCompletion = true;
        completionInit = ''
          autoload -U compinit && compinit
          zstyle ':completion:*' menu select
        '';
        autosuggestion.enable = true;
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
        #enableAlias = true;
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
      ];
      programs.fzf = {
        enable = true;
        enableZshIntegration = true;
        enableFishIntegration = false;
      };
      programs.btop = {
        enable = true;
      };
      programs.bat = {
        enable = true;
      };
      programs.obsidian = {
        enable = true;
      };
    };
}
