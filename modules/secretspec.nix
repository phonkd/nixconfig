{ inputs, ... }:
let
  # The homelab Vaultwarden (modules/homelab/apps/vaultwarden.nix, on 201).
  bwServer = "https://vw.w.phonkd.net";
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
    { pkgs, ... }:
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
        inputs.nixpkgs-unstable.legacyPackages.${pkgs.system}.secretspec
        pkgs.bitwarden-cli
      ];

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
