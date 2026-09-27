# viewflow -- cross-device window sharing between a Hyprland host and a
# Windows peer. See plans/viewflow.md for the full design and pairing decision.
#
# STRANDED since g14 was retired: g14 was the Linux end of every pairing, and
# the gate below (hyprland tag AND NVIDIA) now matches blac alone -- which is
# also the Windows end of the pair, so there is no second machine left to pair
# with. Kept rather than deleted because the packages still build and blac is
# dual-boot; drop this file plus the `viewflow` line in modules/builder.nix if
# it stays unused.
#
# Ships *packages on PATH*, not a service: pairing uses a per-session ephemeral
# CA (7-day leaf certs), so there's no sops secret and nothing for a systemd
# unit to hold -- deliberate, since upstream is pre-alpha with
# session-terminating bugs still open. NVIDIA-only on Linux in *both* roles
# (not a degraded fallback): the source bails without `--features
# native-gpu-nvenc`, and the presenter's CMake requires CUDAToolkit with no
# VAAPI/software path -- hence the hasNvidia gate below, and hence z14 can't
# participate.
#
# The Windows half of the pair (blac booted into Windows) is NOT built here --
# needs MSVC/WGC/Media Foundation, see plans/viewflow.md.
{
  self,
  inputs,
  lib,
  ...
}:
let
  # Upstream has no releases and no tags; version tracks the pinned rev in
  # flake.nix. Keep the two in step when bumping -- and read the note on that
  # input first: the QUIC protocol version is negotiated between peers, so the
  # Windows side has to be rebuilt in the same change.
  version = "0.1.0-unstable-2026-09-13";
in
{
  perSystem =
    { system, ... }:
    let
      # perSystem's default `pkgs` carries no unfree allowance, and the NVENC/
      # CUDA builds need one. The host-wide `nixpkgs.config.allowUnfree = true`
      # doesn't reach these (built with the flake's own nixpkgs, not the
      # host's), so scope the allowance to CUDA/NVIDIA packages here instead of
      # turning unfree on wholesale for every perSystem package in the repo.
      pkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfreePredicate =
          p:
          let
            n = lib.getName p;
          in
          lib.hasPrefix "cuda" n || lib.hasPrefix "libcu" n || lib.hasPrefix "libn" n;
      };

      inherit (pkgs) cudaPackages;

      # build.rs reaches for a *vendored prebuilt* protoc
      # (protoc_bin_vendored::protoc_bin_path), a foreign ELF that can't run in
      # the sandbox. Point it at nixpkgs' protoc instead, re-wrapping the
      # surrounding `.expect(...)` in a Result so this stays a one-token
      # substitution rather than a patch that rots on the next rev bump.
      protocPatch = ''
        substituteInPlace crates/viewflow-protocol/build.rs \
          --replace-fail 'protoc_bin_vendored::protoc_bin_path()' \
            'Ok::<std::path::PathBuf, std::io::Error>(std::path::PathBuf::from(std::env::var("PROTOC").expect("PROTOC must be set")))'
      '';

      # The Rust workspace. `withNvenc` turns on the CUDA/EGL encoder that
      # crates/viewflowd/build.rs compiles out of platform/nvenc-encoder via
      # CMake -- required for the Hyprland *source* role, dead weight for a
      # pure presenter.
      mkViewflow =
        { withNvenc }:
        pkgs.rustPlatform.buildRustPackage {
          pname = if withNvenc then "viewflow-nvenc" else "viewflow";
          inherit version;
          src = inputs.viewflow;
          cargoLock.lockFile = "${inputs.viewflow}/Cargo.lock";

          postPatch = protocPatch;

          # Only the daemon crate -- the rest of the workspace is libraries.
          cargoBuildFlags = [
            "-p"
            "viewflowd"
          ];
          buildFeatures = lib.optionals withNvenc [ "native-gpu-nvenc" ];

          # Upstream's tests want a compositor, a GPU and loopback QUIC peers.
          doCheck = false;

          nativeBuildInputs =
            with pkgs;
            [
              pkg-config
              protobuf
            ]
            ++ lib.optionals withNvenc [
              cmake
              cudaPackages.cuda_nvcc
              # libcuda.so comes from the running driver, not the toolkit, so
              # the binary is linked against a stub and needs the driver's
              # directory added to its runpath to resolve at runtime.
              autoAddDriverRunpath
            ];

          buildInputs =
            with pkgs;
            [
              # arboard's wayland-data-control feature links libwayland-client.
              wayland
              libxkbcommon
            ]
            ++ lib.optionals withNvenc [
              ffmpeg
              libGL
              cudaPackages.cuda_cudart
              cudaPackages.cuda_cccl
            ];

          # cargo's build.rs drives CMake itself; the cmake setup hook must not
          # try to configure the (non-existent) top-level CMakeLists.
          dontUseCmakeConfigure = true;

          env.PROTOC = "${pkgs.protobuf}/bin/protoc";

          # crates/viewflowd/build.rs runs `cmake` itself with a fixed argument
          # list, so there's no place to pass -DCUDAToolkit_ROOT -- CMAKE_LIBRARY_PATH
          # / CMAKE_INCLUDE_PATH from the environment is the only lever.
          # Needs libcuda.so (`find_library(NAMES cuda)`), which ships with the
          # *driver* rather than the toolkit; nixpkgs' build-time stub lives in
          # lib/stubs, not on any default search path, hence spelling it out.
          # getOutput "stubs" falls back to `out` when there's no separate
          # stubs output, so all layouts are covered.
          preBuild = lib.optionalString withNvenc (
            let
              cudart = cudaPackages.cuda_cudart;
              stubDirs = lib.concatStringsSep ":" [
                "${lib.getLib cudart}/lib"
                "${lib.getLib cudart}/lib/stubs"
                "${lib.getOutput "stubs" cudart}/lib"
              ];
            in
            ''
              export CMAKE_LIBRARY_PATH="${stubDirs}''${CMAKE_LIBRARY_PATH:+:$CMAKE_LIBRARY_PATH}"
              export CMAKE_INCLUDE_PATH="${lib.getDev cudart}/include''${CMAKE_INCLUDE_PATH:+:$CMAKE_INCLUDE_PATH}"
              export NIX_LDFLAGS="$NIX_LDFLAGS -L${lib.getLib cudart}/lib/stubs -L${lib.getOutput "stubs" cudart}/lib"
            ''
          );

          meta = {
            description = "Cross-device window sharing daemon (viewflow)";
            homepage = "https://github.com/gfhdhytghd/viewflow";
            license = lib.licenses.gpl3Only;
            platforms = lib.platforms.linux ++ lib.platforms.darwin;
            mainProgram = "vf-window-peer";
          };
        };
    in
    {
      # Portable half: the QUIC orchestrator and friends. Builds anywhere,
      # including on an AMD host -- but note that on Linux it is only a
      # supervisor that launches a native backend, so on a host with no CUDA
      # backend to launch it has nothing to do. See plans/viewflow.md.
      packages.viewflow = mkViewflow { withNvenc = false; };

      # Source-capable build for the NVIDIA hosts.
      packages.viewflow-nvenc = mkViewflow { withNvenc = true; };

      # The two Linux native backends:
      #   viewflow_linux_reverse       -- the presenter (CUDA/FFmpeg decode +
      #                                   EGL/GLES draw into a Wayland surface)
      #   viewflow-linux-window-input  -- return input, via the wlr virtual
      #                                   pointer / virtual keyboard protocols
      packages.viewflow-linux-native = pkgs.stdenv.mkDerivation {
        pname = "viewflow-linux-native";
        inherit version;
        src = inputs.viewflow;

        nativeBuildInputs = with pkgs; [
          cmake
          pkg-config
          wayland-scanner
          cudaPackages.cuda_nvcc
          # As in mkViewflow: the presenter links libcuda.so via a build-time
          # stub, and without this the runtime lookup of the *driver's* copy
          # (/run/opengl-driver/lib on NixOS) is not in the binary's runpath.
          autoAddDriverRunpath
        ];

        buildInputs = with pkgs; [
          ffmpeg
          libGL
          wayland
          wayland-protocols
          libxkbcommon
          libpng
          # Undeclared upstream: platform/linux-reverse/main.cpp includes
          # <nlohmann/json.hpp> but no CMakeLists mentions it -- upstream
          # builds against a distro-wide install. Header-only, so being on the
          # include path is all it needs.
          nlohmann_json
          cudaPackages.cuda_cudart
          cudaPackages.cuda_cccl
        ];

        # Two separate CMake projects under platform/, neither at the source
        # root, so drive them by hand rather than via the cmake setup hook.
        dontUseCmakeConfigure = true;

        buildPhase = ''
          runHook preBuild
          export NIX_LDFLAGS="$NIX_LDFLAGS -L${lib.getLib cudaPackages.cuda_cudart}/lib/stubs -L${lib.getOutput "stubs" cudaPackages.cuda_cudart}/lib"
          for proj in linux-reverse linux-window-input; do
            cmake -S platform/$proj -B build/$proj \
              -DCMAKE_BUILD_TYPE=Release \
              -DBUILD_TESTING=OFF \
              -DCMAKE_LIBRARY_PATH="${lib.getLib cudaPackages.cuda_cudart}/lib/stubs;${lib.getOutput "stubs" cudaPackages.cuda_cudart}/lib"
            cmake --build build/$proj --parallel $NIX_BUILD_CORES
          done
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out/bin
          install -Dm755 build/linux-reverse/viewflow_linux_reverse $out/bin/
          install -Dm755 build/linux-reverse/viewflow_reverse_decoder_probe $out/bin/
          install -Dm755 build/linux-window-input/viewflow-linux-window-input $out/bin/
          runHook postInstall
        '';

        meta = {
          description = "viewflow Linux native backends (presenter + return input)";
          homepage = "https://github.com/gfhdhytghd/viewflow";
          license = lib.licenses.gpl3Only;
          platforms = lib.platforms.linux;
        };
      };
    };

  # Self-gating, so it is safe to sit in builder.nix's alwaysImport list.
  #
  # `hyprland` tag AND hasNvidia == blac, and nothing else. The tag
  # matters beyond taste: the *source* role talks Hyprland IPC and needs a
  # capture plugin in the running compositor. z14 has the tag but is AMD, so
  # the GPU half of the gate is what keeps a CUDA closure off a laptop that
  # could never run it.
  flake.nixosModules.viewflow =
    {
      pkgs,
      lib,
      config,
      noughtyLib,
      ...
    }:
    lib.mkIf (noughtyLib.hostHasTag "hyprland" && config.noughty.host.gpu.hasNvidia) {
      environment.systemPackages = [
        self.packages.${pkgs.system}.viewflow-nvenc
        self.packages.${pkgs.system}.viewflow-linux-native
      ];

      # QUIC is UDP on a port chosen per session; 44220 is upstream's example
      # and what plans/viewflow.md's configs use. Must be opened explicitly:
      # `services.tailscale.openFirewall` opens only udp/41641, so the NixOS
      # firewall filters `tailscale0` like any other interface, and a blocked
      # QUIC handshake is silent rather than an error. Opened on all interfaces
      # rather than scoped to one, since the LAN interface name differs per
      # host (enp9s0 on blac, wlp2s0 on a laptop); exposure is one UDP port on the
      # home LAN, behind mTLS (a peer without a cert signed by the session's
      # pair CA gets nowhere). Narrow with
      # `networking.firewall.interfaces.<name>.allowedUDPPorts` if this ever
      # leaves the house.
      networking.firewall.allowedUDPPorts = [ 44220 ];
    };
}
