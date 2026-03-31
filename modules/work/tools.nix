{ inputs, ... }:

{
  flake.homeModules.work-tools =
    { pkgs, ... }:
    {
      home.packages = with pkgs; [
          # k8s
          kubectl
          kubectl-view-secret
          kubectx
          kubernetes-helm
          kconf
          kustomize
          kustomize-sops
          k9s
          stern
          # misc
          terraform
          minio-client
          yq
          prek
          remmina
          devbox
          (pkgs.buildGoModule rec {
              pname = "subst";
              version = "1.0.1";
              src = pkgs.fetchFromGitHub {
                owner = "bedag";
                repo = "subst";
                rev = "v${version}";
                hash = "sha256-jtcFzPE8QFqSw5mLU0sg38bJekB82lx9Wc2P6omnCSI=";
              };
              vendorHash = "sha256-Alp8CGehBb42uagFaqPhTew0W8cG4flWx+zQSYJQn3s=";
            })
        ];
        programs.go = {
          enable = true;
        };
    };
}
