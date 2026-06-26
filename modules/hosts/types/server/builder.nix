# Distributed-build role modules (imported by name, not auto-applied).
#
#   builder-client  -- offload x86_64-linux builds to 205-builder. Holds the
#                      nixremote PRIVATE key (via sops). oldblac-vm imports it,
#                      so every homelab VM is a build client.
#   builder-server  -- accept offloaded builds: the nixremote account + its
#                      AUTHORIZED (public) key + trusted-users. Imported only
#                      by 205-builder.
#
# 205-builder inherits builder-client transitively via oldblac-vm, so it
# mkForce-disables the client wiring (it must not offload to itself) and
# imports builder-server instead.
{ ... }:
{
  flake.nixosModules.builder-client =
    { config, lib, ... }:
    {
      # nixremote PRIVATE key, delivered by sops-nix. server-sops supplies the
      # default sops file + age key. Add the key under `nixremote_key:` in
      # modules/homelab/global-secrets/secret.yaml (edit with `sops`) before
      # deploying, or activation fails on every oldblac VM.
      sops.secrets."nixremote_key" = { };

      nix.distributedBuilds = true;
      nix.settings.builders-use-substitutes = true;
      nix.buildMachines = [
        {
          hostName = "192.168.3.205";
          sshUser = "nixremote";
          sshKey = config.sops.secrets."nixremote_key".path;
          system = "x86_64-linux";
          maxJobs = 8;
          speedFactor = 2;
          supportedFeatures = [
            "nixos-test"
            "benchmark"
            "big-parallel"
            "kvm"
          ];
        }
      ];
      # Capture after first boot with: ssh-keyscan -t ed25519 192.168.3.205
      programs.ssh.knownHosts."192.168.3.205".publicKey =
        "ssh-ed25519 AAAA...REPLACE_ME..."; # >>> replace after first boot <<<
    };

  flake.nixosModules.builder-server =
    { ... }:
    {
      # Unprivileged account clients SSH in as. Authorize the PUBLIC half of
      # the nixremote keypair (private half lives in sops on the clients).
      users.users.nixremote = {
        isNormalUser = true;
        description = "Nix distributed-build account";
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDpYHN3c31izz5UxacR/23bT2YkZv34Wib4S71J66mVN nixremote@clients"
        ];
      };

      # A remote builder's SSH user must be trusted to push closures to the
      # local daemon (default trusted-users is just "root").
      nix.settings.trusted-users = [
        "root"
        "nixremote"
      ];

      # Build throughput (nix.gc is handled by server-globalconfig).
      nix.settings.max-jobs = 8;
      nix.optimise.automatic = true;
    };
}
