# viewflow — cross-device window sharing

**Repo(s):** nixconfig (this repo only — upstream is consumed as a pinned
`flake = false` input)   **Status:** in progress — pairing target blocked, see
"Hardware reality" below

## Goal

Share individual windows between two of our machines so that an app keeps
running on its own machine while its window appears as a real window on the
other one — with the pointer and keyboard crossing over to it. Not a remote
desktop: no full-screen mirror, no second session, the app never moves.

Upstream is [gfhdhytghd/viewflow](https://github.com/gfhdhytghd/viewflow): a Rust
workspace (`viewflowd`) plus CMake/ObjC++ native backends per platform, GPL-3.0,
**no releases, no tags, no `flake.nix`**, and self-described as "an executable,
tested foundation rather than a finished three-platform product".

## Hardware reality — read this before choosing a pairing

The original draft of this plan assumed NVENC was an *optional* feature that
only affected the Hyprland **source** encoder, and floated "all three hyprland
hosts without the NVENC feature, so z14/g14 can at least present" as a cheap
option. **That is not possible.** Verified by reading upstream rev
`767739c1037eab84e7b5ba235056ec6b09b0e692`:

**1. The Linux source hard-requires NVENC.** Not a degraded path — a refusal:

```rust
// crates/viewflowd/src/bin/vf-hyprland-windows.rs:16-18
#[cfg(not(all(target_os = "linux", feature = "native-gpu-nvenc")))]
    anyhow::bail!("Hyprland window source requires Linux and --features native-gpu-nvenc")
```

**2. The Linux _presenter_ also hard-requires CUDA.** This is the surprise —
the receiving side is just as NVIDIA-locked as the sending side:

- `platform/linux-reverse/CMakeLists.txt:5` — `find_package(CUDAToolkit REQUIRED)`,
  linking `CUDA::cuda_driver`.
- `platform/linux-reverse/gpu_decoder.cpp:58-59` — `cuGLGetDevices(...)`, and if
  it finds nothing: `throw std::runtime_error("EGL renderer has no CUDA device")`.
- `platform/linux-reverse/gpu_decoder.cpp:61` — the only hwdevice ever created is
  `AV_HWDEVICE_TYPE_CUDA`. A grep for `vaapi`/`VAAPI`/software fallback across
  all of `platform/linux-reverse/` returns **nothing**.
- `platform/linux-reverse/gpu_decoder.cpp:93` — `"reverse color must stay on GPU"`.
  There is no CPU frame path to fall back to.

**3. Therefore z14 cannot run either role.** z14 is a Radeon 840M and nothing
else — confirmed on the box, a single display controller and no `/dev/nvidia*`:

```
63:00.0 Display controller: AMD/ATI Krackan2 [1002:1902]
```

`vf-window-peer` itself (the QUIC orchestrator) builds fine on z14 without CUDA
— but it is only a supervisor that launches a native backend, and z14 has no
backend it can launch. A **z14 ↔ g14 pairing is not implementable** without
writing a VAAPI or software decode backend for `platform/linux-reverse`, which
is an upstream port, not a packaging job.

### What that leaves

| Pairing | Source | Presenter | Verdict |
|---|---|---|---|
| g14 ↔ blac | both RTX | both RTX | **works** — the only Linux↔Linux pairing we own |
| z14 ↔ anything | — | — | **blocked** upstream, AMD-only host |
| blac/g14 → Mac | RTX (NVENC) | VideoToolbox | works, needs the macOS phases + TCC pain |
| Mac → blac/g14 | ScreenCaptureKit | RTX (CUDA) | works, worst TCC pain |

g14 is an RTX 3050 Ti Laptop GPU (confirmed over ssh), blac is the RTX desktop.

**4. The source additionally needs the HyprCapture plugin loaded** in the
running compositor on the *source* host — `docs/hyprcapture-integration.md`
inspects HyprCapture's `src/plugin/artifact_capture.cpp` and notes the live
compositor "lists HyprCapture 0.2.7". So being a *source* is not just a package
install; it re-opens the deferred Phase 3 plugin tax. Being a *presenter* does
not — `linux-reverse` is a plain Wayland client (plus CUDA).

## Approach

Unchanged from the draft in the two things that still hold:

**1. Use `vf-window-peer`, not the desktop-atlas launcher.** The atlas launcher
creates a headless output and loads two plugins into the running Hyprland — it
can wedge the desktop you are using, and it is explicitly Linux→Windows.

**2. Nothing runs at login.** Upstream: "Nothing runs at login or changes the
main desktop persistently." Pairing is a per-session ephemeral CA (7-day leaf
certs in a `0700` dir), so there is **no sops secret to add** and nothing for a
systemd unit to hold. The nix deliverable is *packages on PATH*, not
`services.viewflow.enable`. That keeps a pre-alpha thing structurally incapable
of breaking a boot.

### Phases

- **Phase 1 — Linux packaging.** Package the Rust daemon + the two Linux native
  helpers, gated to NVIDIA Hyprland hosts (blac, g14).
- **Phase 2 — pick a pairing and pair it by hand.** Needs the decision below.
- **Phase 3 — deferred.** Hyprland metadata/capture plugins + atlas launcher.
  ABI-locked to the running compositor.

## Steps

All of it lands in **one new file, `modules/viewflow.nix`** — `import-tree`
picks it up automatically, the same single-file shape `modules/deploy.nix` uses.

### Phase 1 — Linux

1. **Pin the input** in `flake.nix`, `flake = false`, pinned to a rev and
   deliberately not following HEAD — same reasoning as the `aerothemeplasma`
   pin. Upstream rewrites its own runtime weekly and the QUIC protocol version
   is negotiated between peers, so a half-updated pair refuses each other.
   Bump **both** machines in the same change.

2. **`perSystem.packages.viewflow`**: `rustPlatform.buildRustPackage` over
   `inputs.viewflow`, `cargoLock.lockFile` (the lock is committed).
   Edition 2024 / `rust-version = "1.85"` / `resolver = "3"`.
   *Correction to the draft:* it does **not** need a `protobuf` build input —
   `crates/viewflow-protocol/build.rs:3` uses `protoc_bin_vendored`, a vendored
   protoc binary. That binary is a prebuilt ELF, so it needs the usual
   patchelf/interpreter handling in the sandbox rather than a system protoc.

3. **NVENC as an optional argument.** `--features native-gpu-nvenc` turns on the
   CUDA encoder, compiled by `crates/viewflowd/build.rs` out of
   `platform/nvenc-encoder/`. Expose `withNvenc`; enable only where
   `config.noughty.host.gpu.hasNvidia`. Unfree CUDA needs the scoped
   `nixpkgs.config.allowUnfreePredicate` pattern (the one prior art in this repo
   is `modules/homelab/apps/ocis.nix:40`), not a blanket `allowUnfree`.

4. **Two CMake native helpers** as `viewflow-linux-native`:
   - `platform/linux-reverse` → `viewflow_linux_reverse` (presenter)
     — FFmpeg (`libavcodec libavutil`), `egl`, `glesv2`, `wayland-client`,
     `wayland-egl`, `xkbcommon`, `PNG`, **CUDAToolkit**.
   - `platform/linux-window-input` → `viewflow-linux-window-input` (return
     input) — `wayland-client`, `xkbcommon`, and `wayland-scanner` as a
     *build* tool, generating client headers for
     `wlr-virtual-pointer-unstable-v1` and `virtual-keyboard-unstable-v1`.

   Every CMake target is `-Wall -Wextra -Werror`, so a nixpkgs compiler newer
   than upstream tests against fails the build on a warning; expect `-Wno-error`.

5. **Host gating.** A self-gating `config` block in `modules/viewflow.nix` keyed
   on `hostHasTag "hyprland" && gpu.hasNvidia`, added to `alwaysImport` in
   `modules/builder.nix` — the `nvidia-desktop` precedent exactly. That lands it
   on blac and g14 and keeps a CUDA closure off z14, which could not use it.

6. **Firewall.** QUIC is UDP, port chosen per session (upstream examples use
   44220). Both machines are on the tailnet, so pair over `100.64.0.x` and skip
   LAN exposure entirely.

### Phase 2 — pairing (needs the decision below)

7. Generate the ephemeral CA and per-side leaf certs, write the two JSON configs
   (`role: "source"` / `role: "presenter"`, absolute paths, `backend.native`
   pointing at the store binary). Keep them in `~/viewflow/` by hand — they
   carry per-session cert paths and are not config-as-code.
8. Source side additionally needs HyprCapture loaded in its Hyprland. Presenter
   side needs nothing but the binary.

## Open decisions

1. **Which pairing.** *Recommended:* **g14 ↔ blac**, the only Linux↔Linux
   pairing our hardware supports. *Alternative:* g14/blac → Mac, which needs the
   macOS phases and the TCC-stable-path problem (a nix store path changes every
   rebuild and voids a Screen Recording grant; this repo has been bitten by that
   class of problem before — see the `kitty` cask comment in
   `modules/hosts/types/gui/default.nix`). *Not an option:* anything with z14.
2. **z14 participation.** *Recommended:* drop it. The only route is porting
   `platform/linux-reverse` to VAAPI, which means replacing the whole
   CUDA/GL-interop decode path — `av_hwdevice_ctx_create` is the small part; the
   `cuGraphicsGLRegisterImage` → `cuMemcpy2D` → GL texture interop in
   `gpu_decoder.cpp:115-130` is the real work. Upstream shows no interest in a
   non-NVIDIA Linux path.
3. **Whether to build at all before committing.** The repo rule "never verify
   with full evals" targets `nixosConfigurations.<x>` toplevel builds. A
   `nix build .#viewflow` is a *package* build and is unavoidable here:
   `buildRustPackage` needs a real vendor hash and the CMake projects need their
   `-Werror` surprises found. Build the packages, never a host toplevel.

## Risks / rollout

- **Upstream maturity is the main risk.** `docs/project-status.md` reports
  session-terminating bugs as *current*: NVENC timeouts ending runs, atlas
  capacity overflow killing a group, an unresolved presentation-ack timeout, and
  clipboard/file-drag/per-app-audio explicitly not deliverable yet. The
  `deploy/` directory is 40+ scripts named things like
  `check-failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2.sh`,
  which is its own signal about process. Mitigation is structural: packages
  only, no unit, no login hook, nothing in the boot path. Worst case is a CLI
  that exits.
- **Build fragility.** Two CMake projects at `-Werror` plus a Rust workspace at
  `clippy::pedantic`, none of it ever built under nix. Expect patches. If the
  native helpers resist, `vf-window-peer` alone still gives view-only sharing
  (upstream: "Omit `--input-native` for view-only Hyprland sharing").
- **Rollout.** g14 is not a deploy-rs target (laptops are deploy *clients*, no
  `deploy.hostname` in the registry), so it rebuilds locally on the box:
  `sudo nixos-rebuild switch --flake ~/git/nixconfig#g14`. Nothing is enabled by
  the rebuild — the packages just appear on PATH.
- **Back out.** Drop the `alwaysImport` entry and rebuild; there is no state, no
  service, no secret and no migration. The flake input can stay or go
  independently.
