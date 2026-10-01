{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    # Sole consumer: modules/secretspec.nix, which needs secretspec >= 0.18 for
    # the `bw://` (Bitwarden) provider -- nixos-26.05 ships 0.10.1. The locked
    # *rev* is what matters, not the branch name: this input once sat on a
    # 2026-08-01 rev carrying 0.17.0, which fails at runtime with "Provider
    # backend 'bw' not found". Re-check `secretspec --version` if you re-pin.
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-fork.url = "github:phonkd/nixpkgs/master";
    # Pinned ahead of nixpkgs-unstable purely to get Immich 3.0.2 (not yet
    # on nixpkgs-unstable's locked rev); used only for services.immich.package.
    nixpkgs-immich.url = "github:nixos/nixpkgs/e7a3ca8092b61ff85b6a45bf863ea2b2d6a661b3";
    # nix-on-droid (modules/hosts/android.nix). PINNED as a pair, load-bearing
    # -- current nixpkgs/home-manager don't work on Android. Verified working
    # on the phone in April 2026 (nixpkgs-unstable 2026-01-21); must be the
    # *full* 40-char hash (a 39-char rev isn't a valid github ref and won't
    # lock). home-manager is pinned to the same era. Don't move either alone:
    # a newer home-manager reads `${pkgs.path}/lib/services/lib.nix`, which
    # this nixpkgs predates (eval dies: "path .../lib/services/lib.nix does
    # not exist"); an older one (release-25.11) lacks
    # `programs.fzf.enableNushellIntegration`.
    nixpkgs-android.url = "github:nixos/nixpkgs/88d3861acdd3d2f0e361767018218e51810df8a1";
    home-manager-android.url = "github:nix-community/home-manager/0adb9993274f27168ec0d6c13ec292f03dc328d0";

    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";

    wrapper-modules.url = "github:BirdeeHub/nix-wrapper-modules";
    wrapper-modules.inputs.nixpkgs.follows = "nixpkgs";
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hyprland.url = "git+https://github.com/hyprwm/Hyprland?submodules=1";
    monique = {
      url = "github:ToRvaLDz/monique";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Makes nix-installed .app bundles launchable on the Mac: home-manager's
    # `targets.darwin.linkApps` symlinks bundles into ~/Applications/Home
    # Manager Apps, but that target lives on the /nix volume (mounted
    # `nobrowse`, invisible to Spotlight/Finder) -- apps install but are never
    # indexed, unreachable on Tahoe's Spotlight-driven Applications view.
    # mac-app-util's "trampoline" (a real, indexed .app on the boot volume
    # that launches the store one) is upstream's only working fix; copying,
    # symlinking and macOS aliases all fail.
    #
    # Pointed at nixpkgs-unstable, NOT nixos-26.05 or its own pin: both give
    # sbcl 2.6.4, and sbcl < 2.6.6 can't start under macOS 27 -- its ~52 GB
    # "GPU Carveout" region (past the dyld shared cache, up to 0xfc0000000)
    # overlaps sbcl's fixed low spaces, so its first MAP_FIXED hits EACCES
    # ("failed to allocate 1048576 bytes at 0x300100000"). That aborts
    # `mac-app-util sync-trampolines` and the whole home-manager activation.
    # sbcl 2.6.6 moved the addresses; 2.6.7 (unstable) works. Revert to plain
    # `.url` once nixos-26.xx ships sbcl >= 2.6.6.
    mac-app-util = {
      url = "github:hraban/mac-app-util";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    # Caelestia -- the Quickshell desktop shell for the Hyprland session
    # (modules/hyprland.nix), sole consumer. Deliberately NOT following our
    # nixpkgs (same reasoning as mac-app-util, bigger numbers): needs
    # quickshell from git, not the 0.3.0 in nixos-26.05, costing 7
    # derivations against its own pin (quickshell 0.3.1 tagged release,
    # cpptrace, m3shapes, three caelestia C++ bits) with the other 654 paths,
    # Qt6 included, substituting from cache.nixos.org. Following nixos-26.05
    # would rebuild all of that against an untested Qt6 -- a second nixpkgs
    # and Qt6 in the closure is the honest cost of borrowing someone else's
    # shell. Build offloads to 205-builder like everything else.
    # Track the latest tested upstream release; the package's own Nix version
    # remains hardcoded to 1.0.0 even for the 2.x releases.
    caelestia.url = "github:caelestia-dots/shell/v2.5.0";
    sops-nix.url = "github:Mic92/sops-nix";
    # clan-core builds the hosts listed in modules/builder.nix's `clanHosts`
    # (plans/clan-lol-migration.md). The 26.05 branch pins nixos-26.05, same as
    # ours; it lives on git.clan.lol only -- the GitHub mirror has no 26.05.
    # sops-nix.follows is mandatory: clanCore imports sops-nix itself, and two
    # sops-nix store paths abort eval with "option sops.* already declared".
    clan-core = {
      url = "https://git.clan.lol/clan/clan-core/archive/26.05.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.sops-nix.follows = "sops-nix";
      inputs.nix-darwin.follows = "nix-darwin";
    };
    # deploy-rs: `deploy <host>` builds (offloaded to 205 via nix.buildMachines)
    # and activates a NixOS host with magic rollback. Nodes are generated from
    # lib/registry.nix in modules/deploy.nix.
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-on-droid = {
      url = "github:nix-community/nix-on-droid/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-flatpak.url = "github:gmodena/nix-flatpak/v0.7.0";
    kubectl-aliases = {
      url = "github:phonkd/kubectl-aliases";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Zen Browser (Firefox fork). Follows our nixpkgs so the desktops get
    # native GPU acceleration -- nixGL is only needed off NixOS.
    zen-browser = {
      url = "github:youwen5/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    try-rs = {
      url = "github:phonkd/try-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Daily-updated AI agent packages for NixOS desktops. Keep upstream's
    # nixpkgs pin so its prebuilt packages use the Numtide cache.
    llm-agents.url = "github:numtide/llm-agents.nix";
    nixflix = {
      url = "github:kiriwalawren/nixflix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    simple-nixos-mailserver = {
      url = "gitlab:simple-nixos-mailserver/nixos-mailserver/nixos-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Hermes Agent (Nous Research). Intentionally NOT following our nixpkgs:
    # the package is built with uv2nix against the upstream-pinned
    # nixos-unstable, and forcing it onto nixos-26.05 can break the venv.
    hermes-agent.url = "github:NousResearch/hermes-agent";
    # claude-codex: local Anthropic-API router that lets the ordinary `claude`
    # CLI run inference on the ChatGPT/Codex subscription instead of the
    # Anthropic one (modules/claude-codex.nix). Source-only -- upstream ships
    # no flake -- so it's built with rustPlatform off its own Cargo.lock.
    # Pinned to a tag, not a branch: the proxy tracks two private wire
    # protocols (Anthropic Messages in, the Codex Responses backend out), and
    # an unattended bump is how you find out one of them moved.
    claude-codex = {
      url = "github:fcakyon/claude-code-with-codex/v0.3.1";
      flake = false;
    };
    # slop-trove: personal-data embedding/search platform (own repo, "the thing").
    # TEMPORARILY on discord-dce-ingest for the DiscordChatExporter ingester
    # 204's sources.discord now needs. Flip back to the bare URL once
    # phonkd/slop-trove#2 merges -- nothing else here wants the branch.
    slop-trove = {
      url = "github:phonkd/slop-trove/discord-dce-ingest";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-parts,
      import-tree,
      wrapper-modules,
      kubectl-aliases,
      nixflix,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        wrapper-modules.flakeModules.default
        inputs.clan-core.flakeModules.default
        (import-tree ./modules)
      ];
    };
}
