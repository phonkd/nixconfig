{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-fork.url = "github:phonkd/nixpkgs/master";
    # Pinned ahead of nixpkgs-unstable purely to get Immich 3.0.2 (not yet
    # on nixpkgs-unstable's locked rev); used only for services.immich.package.
    nixpkgs-immich.url = "github:nixos/nixpkgs/e7a3ca8092b61ff85b6a45bf863ea2b2d6a661b3";

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
    sops-nix.url = "github:Mic92/sops-nix";
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
    nixpkgs-unstable-droid.url = "github:nixos/nixpkgs/88d3861";
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
    # Claude Code CLI, tracked at the latest npm release (rebuilt daily upstream)
    # instead of nixpkgs' claude-code, which lags well behind. This is the NixOS
    # analogue of the Mac's `claude-code@latest` Homebrew cask. Wired into the
    # NixOS-desktop HM module in modules/desktop.nix.
    claude-code-nix = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
    # slop-trove: personal-data embedding/search platform (own repo, "the thing").
    slop-trove = {
      url = "github:phonkd/slop-trove";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # llm-noobservability: NL -> LogQL/PromQL querier against Loki/Mimir (own repo).
    llm-noobservability = {
      url = "github:phonkd/llm-NOOBservability";
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
        (import-tree ./modules)
      ];
    };
}
