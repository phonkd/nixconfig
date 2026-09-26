# The repo's development shell: `nix develop` in this directory. Carries the
# secret-management tooling -- `sops set` needs the exact file, a JSON-quoted
# value and a matching .sops.yaml rule, and fails unhelpfully if any is off.
#
#   sops-secret <app>.<key>     add/update one secret in a per-app sops file
#   sso-secret  <app> -r <uri>  mint an Authelia OIDC client for an app
#   task --list                 the same two, through go-task
#
# See plans/authelia-sso.md.
{
  self,
  inputs,
  ...
}:
{
  perSystem =
    { pkgs, ... }:
    let
      sops-secret = pkgs.writeShellApplication {
        name = "sops-secret";
        runtimeInputs = with pkgs; [
          sops
          age
          git
          jq
          openssl
          coreutils
        ];
        text = builtins.readFile ../scripts/sops-secret.sh;
      };

      sso-secret = pkgs.writeShellApplication {
        name = "sso-secret";
        runtimeInputs = with pkgs; [
          sops-secret
          openssl
          coreutils
          gnused
          openssh
        ];
        text = builtins.readFile ../scripts/sso-secret.sh;
      };
    in
    {
      packages = { inherit sops-secret sso-secret; };

      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          sops-secret
          sso-secret
          go-task
          sops
          age
          jq
          yq-go
          openssl
          nixfmt
        ];

        shellHook = ''
          echo "nixconfig devshell — sops-secret, sso-secret, task. See plans/authelia-sso.md."
        '';
      };
    };
}
