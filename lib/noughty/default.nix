# Noughty: centralised, typed system-attribute module.
# Safe to import verbatim into NixOS, nix-darwin and Home Manager.
# Adapted from wimpysworld/nix-config.
{
  config,
  lib,
  ...
}:
let
  helpers = import ../noughty-helpers.nix { inherit lib; };
in
{
  options.noughty = {

    host = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "Hostname of the managed system.";
      };

      kind = lib.mkOption {
        type = lib.types.enum [
          "computer"
          "server"
          "vm"
          "container"
        ];
        default = "computer";
        description = "Class of host system, independent of OS or use-case.";
      };

      platform = lib.mkOption {
        type = lib.types.str;
        default = "x86_64-linux";
        description = "Architecture string (e.g. \"x86_64-linux\", \"aarch64-darwin\").";
      };

      desktop = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Desktop environment name, or null for headless systems.";
      };

      formFactor = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "laptop"
            "desktop"
            "handheld"
            "tablet"
            "phone"
          ]
        );
        default = null;
        description = "Physical form factor of the host.";
      };

      tags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Freeform tags for host classification.";
      };

      os = lib.mkOption {
        type = lib.types.enum [
          "linux"
          "darwin"
        ];
        default = if lib.hasSuffix "-linux" config.noughty.host.platform then "linux" else "darwin";
        description = "OS derived from platform. Never set manually.";
        readOnly = true;
      };

      is = {
        # Catch-all: any host with a desktop environment, including Macs.
        workstation = lib.mkOption {
          type = lib.types.bool;
          default = config.noughty.host.desktop != null;
          description = "Whether this host has a desktop environment (any OS).";
        };
        # Platform-specific desktop predicates. Use these to gate modules
        # that depend on NixOS- or Darwin-specific option namespaces.
        # A Mac is is.workstation but not is.nixosDesktop, so it won't
        # accidentally activate NixOS-only modules like Hyprland-via-NixOS.
        nixosDesktop = lib.mkOption {
          type = lib.types.bool;
          default = config.noughty.host.desktop != null && config.noughty.host.os == "linux";
          description = "Whether this host has a desktop AND runs NixOS.";
          readOnly = true;
        };
        darwinDesktop = lib.mkOption {
          type = lib.types.bool;
          default = config.noughty.host.desktop != null && config.noughty.host.os == "darwin";
          description = "Whether this host has a desktop AND runs nix-darwin.";
          readOnly = true;
        };
        server = lib.mkOption {
          type = lib.types.bool;
          default = config.noughty.host.kind == "server";
          description = "Whether this host is a server.";
        };
        laptop = lib.mkOption {
          type = lib.types.bool;
          default = config.noughty.host.formFactor == "laptop";
          description = "Whether this host is a laptop.";
        };
        vm = lib.mkOption {
          type = lib.types.bool;
          default = config.noughty.host.kind == "vm";
          description = "Whether this host is a virtual machine.";
        };
        darwin = lib.mkOption {
          type = lib.types.bool;
          default = config.noughty.host.os == "darwin";
          description = "Whether this host runs macOS.";
        };
        linux = lib.mkOption {
          type = lib.types.bool;
          default = config.noughty.host.os == "linux";
          description = "Whether this host runs Linux.";
        };
      };

      gpu = {
        vendors = lib.mkOption {
          type = lib.types.listOf (
            lib.types.enum [
              "nvidia"
              "amd"
              "intel"
              "apple"
            ]
          );
          default = [ ];
          description = "GPU vendors present in this host.";
        };

        compute = {
          vendor = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.enum [
                "nvidia"
                "amd"
                "intel"
                "apple"
              ]
            );
            default = null;
            description = "GPU vendor used for compute workloads.";
          };
          vram = lib.mkOption {
            type = lib.types.int;
            default = 0;
            description = "VRAM available on the compute GPU, in GB.";
          };
          unified = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether the compute GPU uses unified memory.";
          };
          acceleration = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.enum [
                "cuda"
                "rocm"
                "vulkan"
                "metal"
              ]
            );
            default =
              if config.noughty.host.gpu.compute.vendor == "nvidia" then
                "cuda"
              else if config.noughty.host.gpu.compute.vendor == "amd" then
                "rocm"
              else if config.noughty.host.gpu.compute.vendor == "apple" then
                "metal"
              else
                null;
            description = "GPU acceleration framework for compute workloads.";
          };
        };

        hasNvidia = lib.mkOption {
          type = lib.types.bool;
          default = lib.elem "nvidia" config.noughty.host.gpu.vendors;
          readOnly = true;
          description = "Whether this host has an NVIDIA GPU.";
        };
        hasAmd = lib.mkOption {
          type = lib.types.bool;
          default = lib.elem "amd" config.noughty.host.gpu.vendors;
          readOnly = true;
          description = "Whether this host has an AMD GPU.";
        };
        hasIntel = lib.mkOption {
          type = lib.types.bool;
          default = lib.elem "intel" config.noughty.host.gpu.vendors;
          readOnly = true;
          description = "Whether this host has an Intel GPU.";
        };
        hasAny = lib.mkOption {
          type = lib.types.bool;
          default = config.noughty.host.gpu.vendors != [ ];
          readOnly = true;
          description = "Whether this host has any GPU.";
        };
        hasCuda = lib.mkOption {
          type = lib.types.bool;
          default = config.noughty.host.gpu.compute.acceleration == "cuda";
          readOnly = true;
          description = "Whether this host has CUDA capability.";
        };
        hasROCm = lib.mkOption {
          type = lib.types.bool;
          default = config.noughty.host.gpu.compute.acceleration == "rocm";
          readOnly = true;
          description = "Whether this host has ROCm capability.";
        };
      };
    };

    user = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "nobody";
        description = "Primary username of the managed system.";
      };
      tags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Freeform tags for user role classification.";
      };
    };
  };

  # Inject noughtyLib as a module argument so any module can use:
  #   { noughtyLib, ... }: lib.mkIf (noughtyLib.isHost ["blac"]) { ... }
  config = {
    _module.args.noughtyLib = helpers {
      hostName = config.noughty.host.name;
      userName = config.noughty.user.name;
      hostTags = config.noughty.host.tags;
      userTags = config.noughty.user.tags;
    };
  };
}
