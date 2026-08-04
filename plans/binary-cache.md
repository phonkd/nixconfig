# Self-hosted binary cache on 205-builder

**Repo(s):** nixconfig   **Status:** draft

## Goal

Serve the outputs 205-builder produces as a **signed binary cache** so any host
can *substitute* a prebuilt path instead of recompiling it. Motivating case:
deploy-rs is a Rust program that no public cache ships for our pinned rev
(verified 404 on both `cache.nixos.org` and serokell's `deploy-rs.cachix.org`),
so every host that lacks it in its local store compiles it from source
(~690 MiB toolchain download + `checkPhase` tests). More broadly, this decouples
"get a prebuilt closure" from the live SSH build-offload path, so substitution
also works when a client isn't actively offloading (e.g. the `deploy
--remote-build` fallback, a client whose store was GC'd, or a fresh machine).

## What this does and does NOT fix

- **Fixes:** x86_64-linux paths (deploy-rs activation binary, and everything else
  built on 205) become a plain HTTP substitution for the Mac and every VM.
- **Does NOT fix the Mac's darwin deploy-rs compile.** The Mac's `deploy` CLI
  needs deploy-rs for `aarch64-darwin`, which can't be built on the x86_64-linux
  builder and can't be served by an x86_64-linux cache. That one-time local
  compile on the Mac remains unless we later also push the Mac's own darwin
  builds into a cache (optional Phase 2). This is the build most likely seen when
  `deploy <host>` was interrupted — worth being explicit that Phase 1 leaves it.
- Note the existing setup already gives clients prebuilt x86_64-linux closures
  when they offload interactively to 205 (205 builds, client copies back over
  ssh). The cache's value is making that substitution *ambient* rather than
  tied to an active offload, plus surviving client-side GC.

## Approach

Run **nix-serve-ng** on 205-builder, serving its local Nix store over HTTP on the
LAN, signed with a dedicated cache key. Add `http://192.168.3.205:5000` as a
substituter and the cache's public key as a `trusted-public-keys` entry on every
consumer (the Mac + all VMs). Keep `cache.nixos.org` first in the list so upstream
paths still come from upstream; 205 only supplies what upstream doesn't have.

Chosen over **attic** for Phase 1: nix-serve-ng just exposes the existing store
with one signing key — no separate DB, GC policy, or push step. attic (dedup,
multiple caches, retention) is a reasonable later upgrade if the store on 205
grows unmanageable, but it's more moving parts than this problem needs.

Signing: generate a keypair with `nix-store --generate-binary-cache-key
homelab-205 priv pub`. Private half → sops (global secrets, delivered to 205
only). Public half → committed in the client config as a `trusted-public-keys`
string (public keys are not secret).

## Steps

1. **Generate the cache keypair** (one-time, locally):
   `nix-store --generate-binary-cache-key homelab-205-1 cache-priv.pem cache-pub.pem`.
   Add the private key under a new `binary-cache-key:` entry in
   `modules/homelab/global-secrets/secret.yaml` (edit with `sops`). Record the
   public key string for step 3/4.

2. **Server module — new `builder-cache` NixOS module** (alongside
   `builder-server` in `modules/hosts/types/server/builder.nix`, imported by
   205-builder in `modules/hosts/205-builder.nix`):
   - `sops.secrets."binary-cache-key" = { };` (private signing key).
   - `services.nix-serve = { enable = true; package = pkgs.nix-serve-ng;
     secretKeyFile = config.sops.secrets."binary-cache-key".path; port = 5000; }`.
   - Open TCP 5000 in the firewall — currently 205 only allows 22
     (`modules/hosts/205-builder.nix:40`), so extend `allowedTCPPorts`. LAN-only;
     do **not** expose via traefik/`201-mono`.

3. **Client wiring — VMs.** In `builder-client`
   (`modules/hosts/types/server/builder.nix`), which every VM already imports via
   `oldblac-vm`, add:
   - `nix.settings.substituters = [ "https://cache.nixos.org" "http://192.168.3.205:5000" ];`
   - `nix.settings.trusted-public-keys = [ "<upstream key>" "homelab-205-1:<pub>" ]`.
   205-builder itself imports `builder-client` transitively but `mkForce`-disables
   the offload bits — confirm the substituter lines don't need the same treatment
   (a builder substituting from its own cache is harmless/redundant; leave as-is
   unless it causes an eval or self-reference issue).

4. **Client wiring — the Mac.** In `modules/hosts/mac.nix` (mirrors where
   `nix.buildMachines` is already duplicated for darwin), add the same
   `substituters` + `trusted-public-keys`. This lets the Mac fetch x86_64-linux
   paths from 205 by substitution (the darwin compile caveat above still stands).

5. **Deploy order:** `deploy 205-builder` first (stand up the cache + firewall
   port), verify it serves, then roll the client change to the Mac + VMs.

## Verify

- On 205 after deploy: `curl -s http://192.168.3.205:5000/nix-cache-info` returns
  `StoreDir: /nix/store` and a priority line.
- Build deploy-rs on 205 once (`nix build .#deploy-cli` from a linux checkout, or
  let a `deploy` run do it), then from a client with an empty match:
  `nix path-info --store http://192.168.3.205:5000 <deploy-rs-out-path>` resolves.
- From the Mac: `nix build --substituters http://192.168.3.205:5000 ...` a known
  205-built x86_64-linux path pulls it rather than building.

## Open decisions

- **nix-serve-ng vs attic** — recommend nix-serve-ng (Phase 1 simplicity);
  revisit attic only if 205's store needs managed retention/dedup.
- **Transport** — plain HTTP on the LAN (`:5000`). Signed paths mean integrity is
  covered by the cache key; HTTP is standard for a trusted LAN cache. Alternative:
  front it through traefik on 201-mono for TLS — rejected for Phase 1 as needless
  coupling to the reverse proxy.
- **Where the public key / substituter lines live** — put them in `builder-client`
  (all VMs) + `mac.nix` (Mac), matching the existing `buildMachines` duplication.
  Alternative: a single shared cross-platform module both import. Recommend the
  duplication for now to match the established pattern; factor out later if a
  third consumer appears.
- **Phase 2 (optional): cache the Mac's darwin outputs too** — run nix-serve on
  the Mac or `nix copy --to` a cache after builds, so a second darwin host (none
  today) could substitute deploy-rs instead of recompiling. Out of scope unless a
  second Mac appears.

## Risks / rollout

- **Low blast radius:** substituters are additive and signature-gated — a client
  only accepts 205's paths if the public key matches, and falls back to
  building/upstream if 205 is down. No effect on `201-mono` or networking beyond
  opening one LAN port on 205.
- **Firewall:** the only new exposure is TCP 5000 on 205, LAN-only.
- **Back out:** remove the substituter + public-key lines from the clients and
  `deploy` them; disable `services.nix-serve` + close 5000 on 205. Nothing else
  depends on the cache existing.
- **Key hygiene:** private signing key lives only in sops, delivered only to 205.
  Rotating = new keypair, update secret + the committed public key, redeploy.
