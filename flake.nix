{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    # Sole consumer: modules/secretspec.nix, which needs secretspec >= 0.18 --
    # that is the release that added the `bw://` (Bitwarden) provider, and
    # nixos-26.05 is still on 0.10.1. Note the *locked rev* is what matters,
    # not the branch name: this input sat on a 2026-08-01 rev carrying 0.17.0,
    # which fails at runtime with "Provider backend 'bw' not found". Keep it
    # ahead of that, and re-check `secretspec --version` if you ever re-pin.
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-fork.url = "github:phonkd/nixpkgs/master";
    # Pinned ahead of nixpkgs-unstable purely to get Immich 3.0.2 (not yet
    # on nixpkgs-unstable's locked rev); used only for services.immich.package.
    nixpkgs-immich.url = "github:nixos/nixpkgs/e7a3ca8092b61ff85b6a45bf863ea2b2d6a661b3";
    # nix-on-droid (modules/hosts/android.nix). PINNED as a pair, and both pins
    # are load-bearing -- current nixpkgs/home-manager do not work on Android.
    #
    # The rev below is the one that was verified working on the phone in April
    # 2026 (nixpkgs-unstable of 2026-01-21). It must be the *full* 40-char hash:
    # a truncated 39-char rev is not a valid github ref and the flake will not
    # even lock.
    #
    # home-manager is pinned to the rev this repo was locked to at that time,
    # so the two stay the same era. Do NOT move either one on its own:
    #  - a newer home-manager reads `${pkgs.path}/lib/services/lib.nix`, a file
    #    the nixpkgs pin predates, and eval dies with
    #    "path .../lib/services/lib.nix does not exist";
    #  - an older home-manager (release-25.11 is older than this nixpkgs, not
    #    newer) lacks options the shared homeModules use, e.g.
    #    `programs.fzf.enableNushellIntegration`.
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
    # Makes nix-installed .app bundles launchable on the Mac. home-manager's
    # `targets.darwin.linkApps` symlinks each bundle into ~/Applications/Home
    # Manager Apps, but the symlink target lives on the /nix volume, which the
    # nix installer mounts `nobrowse` -- the flag that tells Spotlight and
    # Finder to skip a volume entirely. So the apps install correctly and are
    # simply never indexed, and on Tahoe (where the Applications view is
    # Spotlight-driven) they are unreachable. mac-app-util generates a
    # "trampoline" -- a small real .app on the boot volume that launches the
    # store one -- which Spotlight does index. Upstream is explicit that
    # copying, symlinking and macOS aliases all fail here; the trampoline is
    # the thing that works.
    #
    # Deliberately NOT following our nixpkgs: it is a Common Lisp program and
    # its pinned nixpkgs gives a cached sbcl + ASDF closure (~20s to build).
    # Repointing it at nixos-26.05 rebuilds that whole stack for no gain.
    mac-app-util.url = "github:hraban/mac-app-util";
    # AeroThemePlasma -- the Windows 7 shell for Plasma 6 -- packaged for
    # NixOS. Sole consumer: modules/aerothemeplasma.nix.
    #
    # PINNED, and the pin is load-bearing. This flake rebuilds libplasma and
    # plasma-workspace from *our* nixpkgs with the aeroshell patches applied,
    # so its revision has to match our Plasma. Upstream HEAD moved to Plasma
    # 6.7 in 6198329; against nixos-26.05's libplasma 6.6.6 that patch loses
    # 4 of 7 hunks in tooltiparea.h and the build dies. 2d80b38 is the last
    # revision on the 6.6 series. Unpin it when nixpkgs reaches Plasma 6.7,
    # and not before -- a flake update that silently follows HEAD breaks the
    # desktop build, not just the theme.
    aerothemeplasma = {
      url = "github:nyakase/aerothemeplasma-nix/2d80b3832bdc28b413a1b259e0d7223e357309f7";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
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
