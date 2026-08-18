# s3manager -- a browsable web index for the Garage `public` bucket.
#
# Why this exists: `s3.phonkd.net` is Garage's *website* endpoint, which serves
# objects by exact key only. Its root returns `404 NoSuchKey` -- Garage has no
# directory listing -- so there is no way to see what is in the bucket short of
# already knowing an object's name.
#
# Why it holds a key even though the bucket is "public": listing is an S3 API
# call, and Garage 2.3 answers unsigned API requests with
# `403 AccessDenied: Garage does not support anonymous access yet`. There is no
# anonymous/public-policy mode (`garage bucket allow` only takes `--key`). So a
# key must sign the ListObjectsV2 calls -- but it lives here on 201, and
# visitors authenticate with nothing. The key is `s3-browser`, created with
# `garage key create` and granted R (not RW) on `public` alone, so it can do
# no more than the website endpoint already does for the whole internet.
#
# Container rather than a NixOS service because s3manager is not in nixpkgs.
# podman for the same reason as affine.nix: 201 does NAT for wg0 and is the
# tailscale exit node, and `--network=host` adds neither iptables chains nor a
# bridge to that. Host networking also means :3904 binds all interfaces, which
# is fine -- 201's firewall opens only 22/80/443, so traefik reaches it on
# loopback and nothing off-box can.
{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules."homelab-s3-browser" =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    lib.mkIf (noughtyLib.hostHasTag "homelab-server") {
      phonkds.modules = {
        s3-browser = {
          ip = "127.0.0.1";
          port = 3904;
          dashboard = {
            enable = true;
            icon = "minio";
          };
          traefik = {
            enable = true;
            auth = false;
            # Internal by default: the bucket's *contents* are public, but a
            # listing of every key in it is new information. Flip to a
            # `*.w.phonkd.net` domain with ipfilter = false to make the index
            # itself public.
            domain = "s3.home.phonkd.net";
            ipfilter = true;
          };
        };
      };

      sops.secrets."s3-browser-key-id" = { };
      sops.secrets."s3-browser-secret-key" = { };

      sops.templates."s3-browser.env".content = ''
        ACCESS_KEY_ID=${config.sops.placeholder."s3-browser-key-id"}
        SECRET_ACCESS_KEY=${config.sops.placeholder."s3-browser-secret-key"}
      '';

      virtualisation.podman.enable = true;
      virtualisation.oci-containers.backend = "podman";

      virtualisation.oci-containers.containers.s3-browser = {
        # Pinned by digest, not `latest`: an unattended restart should not
        # change the app. Bumping = new tag AND new digest
        # (skopeo inspect docker://docker.io/cloudlena/s3manager:<tag>).
        image = "docker.io/cloudlena/s3manager:v0.8.0@sha256:9ed3a8ecf10381031b19afa4e5ff863efddb81aeac2f84b142a2190d7973e68b";
        environment = {
          # minio-go wants host:port with no scheme. Garage's S3 API is
          # loopback-only on 201, reachable because of --network=host.
          ENDPOINT = "127.0.0.1:3900";
          USE_SSL = "false";
          REGION = "us-east-1";
          PORT = "3904";

          # Pin the UI to the one bucket. Without this the app would offer
          # every bucket the key can see -- which is only `public`, but this
          # also drops the pointless bucket-picker screen.
          BUCKET_NAME = "public";

          # Belt and braces: the key is read-only, so deletes and uploads fail
          # at Garage anyway. This hides the buttons instead of offering
          # actions that always 403.
          ALLOW_DELETE = "false";

          TZ = "Europe/Zurich";
        };
        environmentFiles = [ config.sops.templates."s3-browser.env".path ];
        extraOptions = [ "--network=host" ];
        autoStart = true;
      };
    };
}
