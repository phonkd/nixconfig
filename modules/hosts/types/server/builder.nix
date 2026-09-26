# Distributed-build role modules (imported by name, not auto-applied).
#
#   builder-client -- offload x86_64-linux builds to 205-builder. Holds the
#                     nixremote PRIVATE key (via sops). oldblac-vm imports it,
#                     so every homelab VM is a build client.
#   builder-server -- accept offloaded builds: the nixremote account + its
#                     AUTHORIZED (public) key + trusted-users. Imported only
#                     by 205-builder.
#
# 205-builder inherits builder-client transitively via oldblac-vm, so it
# mkForce-disables the client wiring and imports builder-server instead.
{ ... }:
{
  flake.nixosModules.builder-client =
    { config, lib, ... }:
    {
      # nixremote PRIVATE key via sops-nix; server-sops supplies the default
      # sops file + age key. Add it under `nixremote_key:` in
      # modules/homelab/global-secrets/secret.yaml before deploying, or
      # activation fails on every oldblac VM.
      sops.secrets."nixremote_key" = { };

      nix.distributedBuilds = true;
      nix.settings.builders-use-substitutes = true;

      # Tailnet IP, not the LAN 192.168.3.205 this used to carry: homelab VMs
      # share a LAN with 205 so either worked for them, but g14 is a roaming
      # laptop and off-LAN the LAN IP is simply unreachable -- nix waits,
      # gives up, and builds the whole closure on the laptop instead. The Mac
      # already did it this way (modules/hosts/mac.nix).
      #
      # Port 22 here is Tailscale SSH (each host's real sshd is on :5432), so
      # the connection is authorised by tailnet identity + the headscale
      # ACL; sshKey below is belt-and-braces for if that path ever goes away.
      nix.buildMachines = [
        {
          hostName = "100.64.0.2";
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
        # Same box, aarch64-linux via qemu-user binfmt (registered in
        # 205-builder.nix) -- a build machine is only offered derivations
        # whose system it *declares*, so without this entry nothing reaches
        # 205's emulation ("platform mismatch"). Emulated, so it advertises
        # less than the native entry: no "kvm" (needs an aarch64 host CPU),
        # no "nixos-test" (qemu-user can't boot a VM), lower
        # speedFactor/maxJobs so it never out-ranks a real aarch64 machine.
        {
          hostName = "100.64.0.2";
          sshUser = "nixremote";
          sshKey = config.sops.secrets."nixremote_key".path;
          system = "aarch64-linux";
          maxJobs = 4;
          speedFactor = 1;
          supportedFeatures = [ "big-parallel" ];
        }
      ];

      # Same key on both addresses: Tailscale SSH on :22 presents 205's
      # ed25519 host key, so the LAN pin stays valid for anyone ssh-ing over
      # 192.168.3.205 by hand.
      programs.ssh.knownHosts = {
        "100.64.0.2".publicKey =
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPRovQTSmDh+ooke5LdQK75qZeKvZCbcekwiaWK+WKeB";
        "192.168.3.205".publicKey =
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPRovQTSmDh+ooke5LdQK75qZeKvZCbcekwiaWK+WKeB";
      };
    };

  flake.nixosModules.builder-server =
    { ... }:
    {
      # Unprivileged account clients SSH in as; authorizes the PUBLIC half
      # of the nixremote keypair (private half lives in sops on the clients).
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
