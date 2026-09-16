# viewflow -- cross-device window sharing between g14 (Hyprland) and blac.
#
# See plans/viewflow.md for the full design, the hardware constraints and the
# pairing decision. The short version of what this file is and is not:
#
#   * It ships *packages on PATH*, not a service. Upstream is explicit that
#     "nothing runs at login or changes the main desktop persistently", and
#     pairing uses a per-session ephemeral CA (7-day leaf certs in a 0700 dir)
#     rather than long-lived credentials -- so there is no sops secret to add
#     and nothing for a systemd unit to hold. That is deliberate: upstream is
#     pre-alpha with session-terminating bugs still open, and a package that is
#     structurally incapable of running unattended cannot break a boot.
#
#   * It is NVIDIA-only on Linux, in *both* roles. Not a degraded fallback -- a
#     refusal. The source bails without `--features native-gpu-nvenc`
#     (crates/viewflowd/src/bin/vf-hyprland-windows.rs), and the presenter's
#     CMake does `find_package(CUDAToolkit REQUIRED)` and creates only
#     AV_HWDEVICE_TYPE_CUDA with no VAAPI or software path
#     (platform/linux-reverse/gpu_decoder.cpp). Hence the hasNvidia gate below,
#     and hence z14 cannot participate at all.
#
# The Windows half of the pair (blac booted into Windows) is NOT built here and
# cannot be -- it needs MSVC, the Windows SDK and WGC/Media Foundation. Its
# build and install steps are written up in plans/viewflow.md.
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
      # perSystem's default `pkgs` carries no unfree allowance, and the NVENC /
      # CUDA builds need one. The host-wide `nixpkgs.config.allowUnfree = true`
      # in modules/hosts/types/minimal/default.nix does NOT reach these: a host
      # consumes them as `self.packages.<system>.*`, which is built with the
      # flake's own nixpkgs instance rather than the host's. So scope the
      # allowance to the CUDA/NVIDIA packages here instead of turning unfree on
      # wholesale for every perSystem package in the repo.
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
      # (protoc_bin_vendored::protoc_bin_path). That binary is a foreign ELF
      # with an interpreter that does not exist in the sandbox, so it cannot
      # run here. Point it at nixpkgs' protoc instead. The surrounding
      # `.expect(...)` is kept by re-wrapping in a Result, so this stays a
      # one-token substitution rather than a patch that will rot on the next
      # rev bump.
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

          # The GPU encoder is configured by crates/viewflowd/build.rs, which
          # runs `cmake` itself with a fixed argument list -- so there is no
          # place to pass -DCUDAToolkit_ROOT or any other -D flag. CMake does
          # honour CMAKE_LIBRARY_PATH / CMAKE_INCLUDE_PATH from the
          # environment, and that is the only lever available here.
          #
          # It needs libcuda.so (`find_library(NAMES cuda)`), which ships with
          # the *driver* rather than the toolkit. nixpkgs provides a build-time
          # stub for it; the lib/stubs directory is not on any default search
          # path, hence spelling it out. getOutput "stubs" falls back to `out`
          # when there is no separate stubs output, so all layouts are covered.
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
  # `hyprland` tag AND hasNvidia == blac and g14, and nothing else. The tag is
  # load-bearing beyond taste: the *source* role talks Hyprland IPC and needs a
  # capture plugin in the running compositor. z14 has the tag but is AMD, so
  # the GPU half of the gate is what keeps a CUDA closure off a laptop that
  # could never run it. (Every desktop carries the tag now that KDE is gone;
  # it used to mark the hosts running Hyprland *as well as* Plasma.)
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

      # QUIC is UDP on a port chosen per session (upstream's examples use
      # 44220). Nothing is opened here on purpose: both machines are on the
      # tailnet, so pair over 100.64.0.x and keep this off the LAN.
    };
}
