# Immich -- self-hosted photo/video backup, living on the media-server VM
# (203-media) alongside oCIS. Split the same way as ocis.nix: routing/
# dashboard config lives on the reverse-proxy host (201), the actual
# service lives on 203-media.
{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-immich" =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    let
      # Upstream's prebuilt CUDA machine-learning image, pinned tag@digest the
      # same way affine.nix pins its own -- a floating tag would move version
      # under us on any container restart. Bumping = new tag AND new digest:
      #   skopeo inspect --override-os linux --override-arch amd64 \
      #     docker://ghcr.io/immich-app/immich-machine-learning:<tag>-cuda
      # Keep the version in lockstep with services.immich.package below: the
      # server and the ML service speak a versioned internal API.
      mlImage =
        "ghcr.io/immich-app/immich-machine-learning:v3.0.2-cuda"
        + "@sha256:cad0c6c38c60bd6a5a1929cbed01eecc105bcb58775682c137497632f8db5adc";

      # Deliberately NOT /var/cache/immich: that is the nix service's
      # CacheDirectory, mode 0700 owned by the `immich` uid, and the image's
      # own user does not map onto it. A separate dir also leaves the CPU
      # service's already-downloaded models intact if this is ever reverted.
      mlCacheDir = "/var/cache/immich-ml-cuda";
    in
    lib.mkMerge [
      (lib.mkIf (noughtyLib.hostHasTag "reverse-proxy") {
        phonkds.modules.immich = {
          ip = "192.168.3.203";
          port = 2283;
          dashboard.enable = true;
          traefik = {
            enable = true;
            domain = "immich.w.phonkd.net";
            auth = false;
            ipfilter = false;
          };
        };
      })

      (lib.mkIf (noughtyLib.hostHasTag "media-server") {
        # mediaLocation defaults to /var/lib/immich; put the photo/video
        # library on the same solo-sata disk as the rest of the media
        # stack instead of the system disk. The upstream module's own
        # tmpfiles rule (type "e") only adjusts an existing path, so
        # create it ourselves first.
        systemd.tmpfiles.rules = [
          "d /mnt/solo-sata/immich 0700 immich immich -"
          # Model cache for the CUDA ML container below. Root-owned because
          # the image runs as root; nothing on the host side reads it.
          "d ${mlCacheDir} 0755 root root -"
        ];

        services.immich = {
          enable = true;
          # nixpkgs-26.05/unstable are both still on Immich 2.7.5; pull just
          # this package from a newer pin to get 3.0.2.
          package = inputs.nixpkgs-immich.legacyPackages.${pkgs.system}.immich;
          host = "0.0.0.0";
          mediaLocation = "/mnt/solo-sata/immich";
        };

        # --- machine learning on the passed-through RTX 3060 Ti -------------
        #
        # nixpkgs' immich-machine-learning is CPU-only and no option changes
        # that. Its onnxruntime comes from python3Packages, where
        # `cudaSupport ? config.cudaSupport` defaults to false -- and false is
        # the only variant in the binary cache -- so the built package ships
        # libonnxruntime_providers_{openvino,shared}.so and NO
        # ..._providers_cuda.so. An execution provider is a compile-time
        # artifact: CUDA merely being present on the host (ollama-cuda carries
        # cudart + cuBLAS, in its own closure) cannot load a provider that was
        # never built. Measured on this host, before this block:
        # `ort.get_available_providers()` returned
        # ['OpenVINOExecutionProvider', 'CPUExecutionProvider'], and OpenVINO
        # falls back to device_type=CPU because the VM has no Intel GPU.
        #
        # The nix-native alternative is nixpkgs.config.cudaSupport, which
        # source-builds onnxruntime (wants cuDNN and `big-parallel`; 205 has
        # 12 cores but only 15 GB RAM, so nvcc needs core-capping to not OOM)
        # AND opencv, which immich-machine-learning itself depends on -- again
        # on every nixpkgs bump touching either. Upstream's image is prebuilt,
        # which turns that recurring cost into a fixed one.
        services.immich.machine-learning.enable = false;

        # Podman and the oci-containers backend are already enabled on this
        # host by homelab-affine. Both options merge with mergeEqualOption, so
        # restating them is legal and keeps this module standalone rather than
        # silently depending on affine sticking around.
        virtualisation.podman.enable = true;
        virtualisation.oci-containers.backend = "podman";

        # Generates the CDI spec at boot so podman can hand the GPU to a
        # container. Needs the nvidia driver, which arr-slime.nix already sets
        # up on this host for Jellyfin NVENC.
        hardware.nvidia-container-toolkit.enable = true;

        virtualisation.oci-containers.containers.immich-machine-learning = {
          image = mlImage;
          autoStart = true;

          environment = {
            # The upstream nixos module writes
            # IMMICH_MACHINE_LEARNING_URL = "http://localhost:3003" into the
            # SERVER's environment unconditionally -- it is not gated on
            # machine-learning.enable (checked in the module source). Binding
            # the container to that same host:port is therefore the entire
            # integration: the server needs no extra config, and the admin
            # UI's ML URL stays on its default.
            IMMICH_HOST = "127.0.0.1";
            IMMICH_PORT = "3003";

            # Mirrors what the module set on the CPU service it replaces.
            MACHINE_LEARNING_WORKERS = "1";
            MACHINE_LEARNING_WORKER_TIMEOUT = "120";
            MACHINE_LEARNING_CACHE_FOLDER = "/cache";
          };

          volumes = [ "${mlCacheDir}:/cache" ];

          extraOptions = [
            # --network=host for affine.nix's reason, which applies to any
            # container on 203: this host is routing-sensitive (ProtonVPN full
            # tunnel whose ip rules must stay below Tailscale's), and podman's
            # bridge would add its own NAT chains. Host networking adds none,
            # and IMMICH_HOST above keeps the listener on loopback.
            "--network=host"
            # CDI device from the toolkit above. device-name-strategy defaults
            # to "index", so both `0` and `all` exist; `all` survives the GPU
            # being renumbered.
            "--device=nvidia.com/gpu=all"
          ];
        };
      })
    ];
}
