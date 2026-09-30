# Registry-driven configuration builder.
#
# For each entry in lib/registry.nix this module emits either
# flake.nixosConfigurations.<name> or flake.darwinConfigurations.<name>,
# routed by the entry's platform suffix -- NixOS hosts in `clanHosts` via a
# clan-core machine, the rest via nixosSystem directly. Each built config gets:
#
#   1. The noughty options module (always)
#   2. A generated module setting noughty.host.* / noughty.user.* from the
#      registry entry
#   3. The platform Home Manager loader (hmNixosBase / hmDarwinBase) --
#      harmless with no `home-manager.users.*` configured (e.g. servers)
#   4. `alwaysImport` / `alwaysImportDarwin`: modules that self-gate on
#      noughty.* and are safe everywhere
#   5. `extraModules` from the entry: per-host escape hatch, typically just
#      hardware-configuration.nix paths
{
  self,
  inputs,
  lib,
  ...
}:
let
  registry = import ../lib/registry.nix;

  isDarwin = entry: lib.hasSuffix "-darwin" (entry.platform or "x86_64-linux");

  # NixOS-side: cross-host feature modules, each self-gating and safe
  # everywhere. Host-specific modules belong in extraModules, not here.
  alwaysImport = with self.nixosModules; [
    # Foundation (no gate -- safe on every NixOS host).
    # IMPORTANT: only import each function module via ONE path. Function
    # modules can't be deduplicated (Nix function equality is always
    # false), so importing the same one via multiple paths creates
    # duplicate definitions of unique options.
    system-minimal
    phonkds-options # declares `phonkds.modules.*` type everywhere

    # Hardware / GPU.
    nvidia-desktop # gated on host.gpu.hasNvidia

    # Misc feature modules.
    gigaplayer-client # gated on hostHasTag "gigaplayer-client"
    gigaplayer-server # gated on hostHasTag "gigaplayer-server"
    gigaplayer-server-proxy # gated on hostHasTag "reverse-proxy"
    gui # gated on host.is.nixosDesktop
    fosi-mc331 # gated on hostHasTag "fosi-mc331"
    work # work setup (private repo); gated on hostHasTag "work"
    proxy # sing-box system proxy; gated on noughty.proxy.enable (set by `work`)
    containers # rootless podman for distrobox; gated on host.is.nixosDesktop

    # Server baseline (gated on host.is.server).
    server-globalconfig
    server-sops # long-form: imports sops-nix unconditionally

    mailserver

    # Matrix homeserver + the mautrix bridges (gated on "chat-server" — ext-mail).
    chat-server

    # Reverse-proxy stack (gated on hostHasTag "reverse-proxy").
    homelab-traefik
    homelab-dashboard
    homelab-ddns
    homelab-authelia
    homelab-orphans

    # Homelab service producers (gated on hostHasTag "homelab-server").
    homelab-syncthing
    homelab-vaultwarden
    homelab-paperless
    homelab-crowdsec
    homelab-arr-slime
    homelab-ocis
    homelab-immich
    homelab-garage
    homelab-affine
    homelab-hermes

    # Observability stack (server + VPN gated on "observability-server",
    # sender gated on "observability-sender").
    observability-server
    observability-sender

    # Headscale mesh control plane (gated on "observability-server") + the
    # Tailscale client on every server (host.is.server), which self-registers
    # with the sops pre-auth key (headscale_authkey) minted after headscale
    # comes up. See plans/headscale-mesh.md.
    headscale-server
    tailnet
  ];

  # Darwin-side: cross-host feature modules.
  alwaysImportDarwin =
    (with self.darwinModules; [
      gui-darwin # gated on host.is.darwinDesktop
      aerospace # gated on host.is.darwinDesktop
      dns # scoped /etc/resolver for *.w.phonkd.net → 201 over the tailnet
    ])
    ++ [
      # Trampolines for /Applications/Nix Apps (Spotlight-reachable); the
      # home-manager half lives in modules/hosts/types/gui/default.nix. See
      # flake.nix's mac-app-util comment for why linkApps alone leaves apps
      # unindexed.
      inputs.mac-app-util.darwinModules.default
    ];

  # Always-on Home Manager wiring, harmless with no HM users (empty
  # user-import list; activation is a no-op).
  hmNixosBase = [
    inputs.home-manager.nixosModules.home-manager
    { home-manager.backupFileExtension = "hm-backup"; }
  ];
  hmDarwinBase = [
    inputs.home-manager.darwinModules.home-manager
    { home-manager.backupFileExtension = "hm-backup"; }
  ];

  # Translate a registry entry into noughty.host / noughty.user values.
  noughtyHostModule = name: entry: {
    noughty.host = {
      inherit name;
      kind = entry.kind or "computer";
      platform = entry.platform or "x86_64-linux";
      desktop = entry.desktop or null;
      formFactor = entry.formFactor or null;
      tags = entry.tags or [ ];
      gpu = {
        vendors = entry.gpu.vendors or [ ];
        compute = {
          vendor = entry.gpu.compute.vendor or null;
          vram = entry.gpu.compute.vram or 0;
          unified = entry.gpu.compute.unified or false;
        };
      };
    };
    noughty.user = {
      name = entry.username or "phonkd";
      tags = entry.userTags or [ ];
    };
  };

  extraOf = entry: if entry ? extraModules then entry.extraModules { inherit self inputs; } else [ ];

  # Hosts built by clan-core instead of nixosSystem. The migration in
  # plans/clan-lol-migration.md moves them over one at a time; both paths get
  # the identical module list from nixosModulesFor.
  clanHosts = [
    "205-builder"
    "204-agent"
    "203-media"
    "ext-mail"
    "observability"
  ];
  isClan = name: lib.elem name clanHosts;

  nixosModulesFor =
    name: entry:
    [
      ../lib/noughty
      (noughtyHostModule name entry)
      # Records the git revision this config was built from -- via
      # `nixos-version --configuration-revision` and the observability
      # textfile metric into Mimir, so a merged-but-undeployed host is
      # visible without ssh. Dirty trees get "<rev>-dirty" (or null).
      { system.configurationRevision = self.rev or self.dirtyRev or null; }
    ]
    ++ hmNixosBase
    ++ [ inputs.nix-flatpak.nixosModules.nix-flatpak ]
    ++ alwaysImport
    ++ (extraOf entry);

  mkNixos =
    name: entry:
    inputs.nixpkgs.lib.nixosSystem {
      system = entry.platform;
      specialArgs = { inherit inputs self; };
      modules = nixosModulesFor name entry;
    };

  # clan passes no `system` to nixosSystem, so the platform goes in as
  # nixpkgs.hostPlatform. Recommended defaults stay off: they switch the host
  # to systemd-networkd and default networking.domain to "clan", which makes
  # targetHost root@<host>.clan -- a name that resolves nowhere here.
  mkClanMachine = name: entry: {
    imports = nixosModulesFor name entry;
    nixpkgs.hostPlatform = entry.platform;
    clan.core.enableRecommendedDefaults = false;
  };

  mkDarwin =
    name: entry:
    inputs.nix-darwin.lib.darwinSystem {
      specialArgs = { inherit inputs self; };
      modules = [
        ../lib/noughty
        (noughtyHostModule name entry)
        # Builder owns nixpkgs.hostPlatform so individual modules don't.
        { nixpkgs.hostPlatform = entry.platform; }
      ]
      ++ hmDarwinBase
      ++ alwaysImportDarwin
      ++ (extraOf entry);
    };

  nixosEntries = lib.filterAttrs (_: e: !isDarwin e) registry;
  darwinEntries = lib.filterAttrs (_: e: isDarwin e) registry;
  clanEntries = lib.filterAttrs (n: _: isClan n) nixosEntries;
  plainEntries = lib.filterAttrs (n: _: !isClan n) nixosEntries;
in
{
  # clan emits flake.nixosConfigurations for its machines; the two sets merge
  # because the names never overlap. deploy-rs reads the merged set unchanged.
  clan = {
    meta.name = "phonkd";
    # clan adds `self` and `clan-core` on its own.
    specialArgs = { inherit inputs; };
    # null => each machine keeps honouring its own nixpkgs.* options (the
    # per-host allowUnfreePredicate blocks). Also avoids clan looking up a
    # riscv64-linux perSystem that `systems` doesn't define.
    pkgsForSystem = _: null;
    machines = lib.mapAttrs mkClanMachine clanEntries;
    inventory.machines = lib.mapAttrs (_: e: {
      tags = e.tags or [ ];
      # root login is disabled everywhere; clan sudo's from phonkd like deploy-rs.
      deploy.targetHost = if e ? deploy.hostname then "phonkd@${e.deploy.hostname}" else null;
    }) clanEntries;
  };

  flake.nixosConfigurations = lib.mapAttrs mkNixos plainEntries;
  flake.darwinConfigurations = lib.mapAttrs mkDarwin darwinEntries;
}
