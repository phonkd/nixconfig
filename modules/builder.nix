# Registry-driven configuration builder.
#
# For each entry in lib/registry.nix this module emits either
# flake.nixosConfigurations.<name> or flake.darwinConfigurations.<name>,
# routed by the entry's platform suffix. Each built config gets:
#
#   1. The noughty options module (always)
#   2. A generated module that sets noughty.host.* / noughty.user.*
#      from the registry entry
#   3. The platform-appropriate Home Manager loader (hmNixosBase /
#      hmDarwinBase). HM is wired into every host -- it's harmless when
#      no `home-manager.users.*` are configured (e.g. on servers).
#   4. `alwaysImport` (NixOS) / `alwaysImportDarwin` (Darwin): modules
#      that self-gate on noughty.* and are safe to import everywhere.
#   5. `extraModules` from the entry: per-host escape hatch (typically
#      just hardware-configuration.nix paths).
{
  self,
  inputs,
  lib,
  ...
}:
let
  registry = import ../lib/registry.nix;

  isDarwin = entry: lib.hasSuffix "-darwin" (entry.platform or "x86_64-linux");

  # NixOS-side: cross-host feature modules. Each self-gates and is
  # safe to import everywhere. Host-specific modules belong in the
  # registry entry's extraModules, not here.
  alwaysImport = with self.nixosModules; [
    # Foundation (no gate -- safe on every NixOS host).
    # IMPORTANT: only import each function module via ONE path. Function
    # modules can't be deduplicated (Nix function equality is always
    # false), so importing the same one via multiple paths creates
    # duplicate definitions of unique options. `nixosModules.base` is
    # just a wrapper for system-minimal -- skip it here.
    system-minimal
    phonkds-options # declares `phonkds.modules.*` type everywhere

    # Hardware / GPU.
    nvidia-desktop # gated on host.gpu.hasNvidia

    # Misc feature modules.
    gigaplayer-client # gated on hostHasTag "gigaplayer-client"
    gigaplayer-server # gated on hostHasTag "gigaplayer-server"
    gui # gated on host.is.nixosDesktop

    # Server baseline (gated on host.is.server).
    server-globalconfig
    server-sops # long-form: imports sops-nix unconditionally

    mailserver

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
    homelab-arr-slime
    homelab-aislop
    homelab-garage
    homelab-notes
    homelab-hermes

    # Observability stack (server + VPN gated on "observability-server",
    # sender gated on "observability-sender").
    observability-server
    observability-vpn
    observability-sender
  ];

  # Darwin-side: cross-host feature modules.
  alwaysImportDarwin = with self.darwinModules; [
    gui-darwin # gated on host.is.darwinDesktop
  ];

  # Always-on Home Manager wiring. Safe on hosts with no HM users
  # (the user-import list stays empty and HM activation is a no-op).
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

  mkNixos =
    name: entry:
    inputs.nixpkgs.lib.nixosSystem {
      system = entry.platform;
      specialArgs = { inherit inputs self; };
      modules = [
        ../lib/noughty
        (noughtyHostModule name entry)
      ]
      ++ hmNixosBase
      ++ alwaysImport
      ++ (extraOf entry);
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
in
{
  flake.nixosConfigurations = lib.mapAttrs mkNixos nixosEntries;
  flake.darwinConfigurations = lib.mapAttrs mkDarwin darwinEntries;
}
