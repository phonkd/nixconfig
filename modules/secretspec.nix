{ inputs, ... }:
let
  # The homelab Vaultwarden (modules/homelab/apps/vaultwarden.nix, on 201).
  bwServer = "https://vw.w.phonkd.net";
in
{
  # secretspec (github:cachix/secretspec) -- declarative secret *requirements*
  # resolved via a provider; here `bw://`, the Bitwarden Password Manager
  # backend, pointed at our own Vaultwarden. Imported from homeModules.gui,
  # so it lands on every desktop (NixOS and Mac).
  #
  # NOT declarative: the bw CLI's own state in ~/.config/"Bitwarden CLI" --
  # `bw config server`/`bw login` are interactive, one-time, and the vault
  # must be unlocked per shell regardless; see the README for setup.
  flake.homeModules.secretspec =
    { pkgs, ... }:
    {
      home.packages = [
        # nixpkgs-26.05 pins secretspec 0.10.1, predating `bw://` (added in
        # 0.18) -- same newer-pin trick as Immich in homelab/apps/immich.nix.
        # Needs >= 0.18: 0.17 has no `bw` backend, failing at *use* time with
        # "Provider backend 'bw' not found" (see flake.nix's input comment).
        inputs.nixpkgs-unstable.legacyPackages.${pkgs.system}.secretspec
        pkgs.bitwarden-cli
      ];

      # No S3 client here on purpose -- `mc`/`aws` keep their own state
      # (`mc alias set`, `aws configure`); see the README.

      # secretspec's XDG config path (~/.config/secretspec) is the same on
      # macOS and Linux. `?server=` does NOT configure the bw CLI -- it reads
      # its server only from its own config, unchangeable mid-session.
      # secretspec asserts instead: `bw status` fails with remediation steps
      # if the CLI points elsewhere, turning a read off bitwarden.com instead
      # of our Vaultwarden into a hard error, not a silent wrong answer.
      xdg.configFile."secretspec/config.toml".text = ''
        [defaults]
        provider = "bw://?server=${bwServer}"
      '';

      # Unlocks the vault and exports the session key. Every secretspec read
      # needs BW_SESSION, and `bw unlock` only prints the key -- it can't
      # export into the calling shell, hence a function, not an alias.
      programs.zsh.siteFunctions.bwu = ''
        local key
        key=$(command bw unlock --raw "$@") || return
        export BW_SESSION="$key"
        echo "BW_SESSION exported (${bwServer})"
      '';
    };
}
