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

      # Address the builder by its TAILNET ip, not the LAN 192.168.3.205 this
      # used to carry. The homelab VMs sit on the same LAN as 205 so either
      # worked for them (tailscale picks a direct path between same-subnet
      # peers anyway, so nothing is lost there) -- but g14 is a *roaming*
      # laptop, and off-LAN the 192.168.3.205 entry is simply unreachable:
      # nix waits for it to answer, gives up, and compiles the whole closure on
      # the laptop instead. The tailnet ip is reachable from wherever g14 is,
      # which is the whole point of the mesh. The Mac already did it this way
      # (modules/hosts/mac.nix).
      #
      # Port 22 here is Tailscale SSH (each host's real sshd is on :5432), so
      # the connection is authorised by tailnet identity + the headscale ACL.
      # The sshKey below is therefore belt-and-braces rather than load-bearing
      # over this path -- keep it, it is what makes the account work if the
      # ACL/Tailscale-SSH path ever goes away.
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
        # 205-builder.nix). A build machine is only offered derivations whose
        # system it *declares*, so without this second entry nothing ever
        # reaches 205's emulation -- clients just fail with "platform mismatch".
        #
        # Emulated, so it advertises less than the native entry: no "kvm" (an
        # aarch64 guest needs an aarch64 host CPU) and no "nixos-test"
        # (qemu-user can't boot a VM), and a lower speedFactor/maxJobs so this
        # never out-ranks a real aarch64 machine if one ever joins.
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

      # Same key on both addresses -- Tailscale SSH on :22 presents 205's
      # ed25519 host key, so the LAN pin stays valid for anyone ssh-ing over
      # 192.168.3.205 by hand while the tailnet pin is what nix now uses.
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
      # Builder disks fill quickly with nix store garbage; override global
      # weekly+30d GC to daily+7d to keep / from filling up.
      nix.gc = {
        automatic = true;
        dates = "daily";
        options = "--delete-older-than 7d";
      };
      nix.settings.max-jobs = 8;
      nix.optimise.automatic = true;
    };
}
