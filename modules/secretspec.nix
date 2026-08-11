{ inputs, ... }:
let
  # The homelab Vaultwarden (modules/homelab/apps/vaultwarden.nix, on 201).
  bwServer = "https://vw.w.phonkd.net";
  # Garage's S3 API (modules/homelab/apps/s3-garage.nix -> phonkds.modules.s3-api,
  # and settings.s3_api.s3_region for the region).
  s3Endpoint = "https://api.s3.w.phonkd.net";
  s3Region = "us-east-1";
in
{
  # secretspec (github:cachix/secretspec) -- declarative secret *requirements*
  # in a checked-in secretspec.toml, resolved at runtime from a provider. Here
  # the provider is `bw://`, the Bitwarden Password Manager backend, pointed at
  # our own Vaultwarden.
  #
  # Imported from homeModules.gui, so it lands on every desktop: the NixOS
  # boxes (g14, blac) and the Mac alike.
  #
  # What is deliberately NOT declarative: the bw CLI's own state in
  # ~/.config/"Bitwarden CLI". `bw config server` + `bw login` are interactive
  # and one-time, and the vault has to be unlocked per shell regardless, so
  # there is nothing durable for nix to own. See the README section this
  # module's commit adds for the one-time setup.
  flake.homeModules.secretspec =
    { pkgs, config, ... }:
    let
      secretspec = inputs.nixpkgs-unstable.legacyPackages.${pkgs.system}.secretspec;

      # secretspec finds secretspec.toml by walking up from the *current*
      # directory. A credential_process is spawned by aws with whatever cwd the
      # user happened to be in, so it has to be told the manifest explicitly or
      # `aws s3 ls` would only work from inside this repo.
      manifest = "${config.home.homeDirectory}/git/nixconfig/secretspec.toml";

      # https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sourcing-external.html
      # -- awscli runs this and reads a JSON credential object off stdout.
      awsCredentialProcess = pkgs.writeShellScript "secretspec-aws-credentials" ''
        set -euo pipefail
        id=$(${secretspec}/bin/secretspec get --file ${manifest} S3_ACCESS_KEY_ID)
        key=$(${secretspec}/bin/secretspec get --file ${manifest} S3_SECRET_ACCESS_KEY)
        exec ${pkgs.jq}/bin/jq -n --arg id "$id" --arg key "$key" \
          '{Version: 1, AccessKeyId: $id, SecretAccessKey: $key}'
      '';
    in
    {
      home.packages = [
        # nixpkgs-26.05 pins secretspec 0.10.1, which predates the `bw://`
        # provider entirely -- Bitwarden Password Manager support landed in
        # 0.18. Pull just this one package from the unstable input, the same
        # single-package-newer-pin trick as Immich in homelab/apps/immich.nix.
        #
        # This needs >= 0.18 specifically. 0.17 builds and runs fine but has
        # no `bw` backend at all, so it fails only at *use* time with
        # "Provider backend 'bw' not found" -- see the flake.nix input comment.
        secretspec
        pkgs.bitwarden-cli
      ];

      # The declarative half of the S3 story. There is no home-manager module
      # for minio-client (`programs.mc` is Midnight Commander, a different
      # tool), and `programs.rclone`'s `secrets` option wants file paths read at
      # activation time -- the sops/agenix shape, which does not fit a vault
      # that is unlocked interactively. awscli is the one S3 client with an HM
      # module that can defer to a password manager at *runtime*.
      #
      # credential_process is what makes this work without putting the key on
      # disk: the credentials file holds a command, not a secret. Writing the
      # key itself here would bake it into a world-readable /nix/store file and
      # commit it to git -- strictly worse than ~/.mc/config.json, which is at
      # least mode 0600 in $HOME.
      #
      # Needs an unlocked vault, same as everything else here: run `bwu` first.
      programs.awscli = {
        enable = true;
        settings.default = {
          region = "${s3Region}";
          endpoint_url = "${s3Endpoint}";
        };
        credentials.default.credential_process = "${awsCredentialProcess}";
      };

      # secretspec locates its config through etcetera's XDG strategy, which is
      # ~/.config/secretspec on macOS as well as Linux, so this one path is
      # correct on both platforms.
      #
      # `?server=` does NOT configure the bw CLI -- the CLI reads its server
      # only from its own config file and refuses to change it while a session
      # is live. secretspec treats it as an assertion: it runs `bw status` and
      # fails with remediation steps if the CLI is pointed anywhere else. That
      # is the point of setting it here -- it makes reading these secrets off
      # bitwarden.com instead of our Vaultwarden a hard error rather than a
      # silent wrong answer.
      xdg.configFile."secretspec/config.toml".text = ''
        [defaults]
        provider = "bw://?server=${bwServer}"
      '';

      # Unlock the vault and export the session key for the current shell.
      # Every secretspec read needs BW_SESSION, and `bw unlock` only prints the
      # key -- it cannot export into the calling shell itself, which is why
      # this is a function and not an alias.
      programs.zsh.siteFunctions.bwu = ''
        local key
        key=$(command bw unlock --raw "$@") || return
        export BW_SESSION="$key"
        echo "BW_SESSION exported (${bwServer})"
      '';
    };
}
