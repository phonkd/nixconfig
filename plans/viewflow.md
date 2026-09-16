# viewflow — cross-device window sharing

**Repo(s):** nixconfig (this repo only — upstream is consumed as a pinned
`flake = false` input)   **Status:** Phase 1 done — the Linux half is packaged,
merged to `main`, and **deployed and verified on g14** (2026-09-16). blac picks
it up whenever it next boots NixOS. Phase 2 — the Windows half — is hand-work on
the Windows peer that cannot be done from nix; see "The Windows half" below.
**g14 is the Linux end of every pairing**; the Windows end can be blac *or* z14,
both of which are dual-boot.

## Goal

Share individual windows between two of our machines so that an app keeps
running on its own machine while its window appears as a real window on the
other one — with the pointer and keyboard crossing over to it. Not a remote
desktop: no full-screen mirror, no second session, the app never moves.

**The pairing is g14 ↔ blac-booted-into-Windows.** blac is dual-boot and the
Windows side is the one wanted here, so this is a Linux↔Windows pair, not the
Linux↔Linux one the previous revision of this plan settled on. That turns out
to be the *better-supported* pairing rather than a compromise: upstream
prioritised Linux → Windows, and the desktop-drag atlas launcher (deferred to
Phase 3, but the thing that eventually gives Win+drag-across-the-screen-edge)
is explicitly Linux↔Windows and has no macOS support at all.

Note this means blac's *NixOS* side is not the peer. The packages still land
there — the gate below catches it and the cost is zero — so a Linux↔Linux
g14 ↔ blac pairing stays available whenever blac is booted into NixOS instead.

**z14 booted into Windows is an equally valid peer**, and the better one for a
first test since it is to hand. That does not contradict the "z14 is blocked"
finding recorded below: what is blocked is z14 as the *Linux* half, which needs
CUDA. As the Windows half it is unconstrained. See "What that leaves".

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

**3b. The Windows side is unaffected by all of this** and is in fact the most
complete non-Linux target upstream has. `platform/` carries a full Windows
stack, and the naming is worth decoding because it is initially misleading:

| Directory | Role | How |
|---|---|---|
| `windows-reverse` | **source** | WGC window capture + Media Foundation / VPL hardware encode |
| `windows-window-capture` | (library) | Windows.Graphics.Capture contract, linked into the above |
| `windows-window-presenter` | **presenter** | `viewflow-windows-windows`, a layered window with per-pixel alpha (D3D11/D2D) |
| `windows-video-compositor` | (library) | composition, linked into the presenter |

"reverse" names the *reverse direction* (Windows → Linux), not a role: the
`windows-reverse` encoder is the counterpart of the `linux-reverse` decoder.
So the two directions are built from different halves of the tree, and both
exist.

### What that leaves

| Pairing | Source | Presenter | Verdict |
|---|---|---|---|
| blac-Windows → g14 | WGC + MFT/VPL | RTX (CUDA) | **the easy direction** — g14 needs only the packages below |
| g14 → blac-Windows | RTX (NVENC) | D3D11 layered window | works, but g14 additionally needs a capture plugin in its Hyprland (Phase 3) |
| **z14-Windows → g14** | WGC + MFT (AMD VCN) | RTX (CUDA) | **works, and is the cheapest test bench we own** — see below |
| g14 → z14-Windows | RTX (NVENC) | D3D11 layered window | works, same Phase 3 caveat as the blac row |
| g14 ↔ blac-NixOS | both RTX | both RTX | still available whenever blac boots NixOS |
| z14-**Linux** ↔ anything | — | — | **blocked** upstream — CUDA-only Linux path, AMD-only host |
| blac/g14 → Mac | RTX (NVENC) | VideoToolbox | works, needs the macOS phases + TCC pain |
| Mac → blac/g14 | ScreenCaptureKit | RTX (CUDA) | works, worst TCC pain |

g14 is an RTX 3050 Ti Laptop GPU (confirmed over ssh), blac is the RTX desktop.

**z14 is dual-boot too, and that reopens it as a peer.** An earlier revision of
this plan said flatly that z14 could not participate. That was wrong in scope:
it is true only of **z14 running Linux**, where `linux-reverse` needs CUDA and
the 840M cannot provide it. Booted into Windows, z14 has no such constraint,
because the Windows path never touches CUDA — see "The Windows side needs no
NVIDIA" below. The 840M's VCN block does have a hardware encoder; confirmed on
the box via VAAPI entrypoints, which is the same silicon Windows exposes through
AMF/Media Foundation:

```
VAProfileH264Main : VAEntrypointEncSlice
VAProfileHEVCMain : VAEntrypointEncSlice
VAProfileAV1Profile0 : VAEntrypointEncSlice
```

So **g14-Linux ↔ z14-Windows is a real pairing**, and it is the most convenient
one to prove the stack with: both machines are laptops that are actually to hand,
whereas blac's NixOS side has been offline for weeks and its Windows side has to
be booted specially. g14 is already deployed and verified, so the only work left
for that test is building the Windows binaries on z14 — the same checklist as
blac, in "The Windows half".

**The asymmetry in the direction rows is the thing to plan around.**
Windows → g14 (from either blac or z14) works with nothing but the packages this
plan ships, because the Linux presenter (`linux-reverse`) is a plain Wayland
client plus CUDA. The Linux → Windows direction needs point 4 below satisfied on
g14 first. **Test the Windows → g14 direction first**; it is the one that needs
no deferred work.

### The Windows side needs no NVIDIA

Worth stating explicitly, because the Linux half's hard CUDA requirement invites
the assumption that the whole project is NVIDIA-only. It is not — there is not a
single CUDA/NVENC/NVIDIA reference anywhere under `platform/windows-*`.

`platform/windows-reverse/hardware_encoder.cpp:13-29` picks its backend from the
DXGI adapter at runtime: oneVPL when the vendor ID is `0x8086` (Intel) and the
codec is 2, Media Foundation otherwise, with VPL falling back to MFT on a failed
start unless forced. MFT then uses whatever hardware encoder the GPU driver
exposes — NVENC on NVIDIA, VCN/VCE on AMD, QSV on Intel. `VIEWFLOW_REVERSE_ENCODER=vpl|mft`
forces the choice. The presenter is plain D3D11/D2D1/DXGI and equally neutral.

The vendor lock is therefore a property of upstream's *Linux* GPU path, not of
the protocol: on Windows they got neutrality for free by going through Media
Foundation, and on Linux they wrote straight to CUDA and never abstracted it.

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

- **Phase 1 — Linux packaging. DONE.** The Rust daemon + the two Linux native
  helpers, gated to NVIDIA Hyprland hosts (blac, g14). As-built notes below.
- **Phase 2 — the Windows half on blac.** Hand-work, cannot be done from nix.
  See "The Windows half".
- **Phase 3 — deferred.** Hyprland metadata/capture plugins + atlas launcher.
  ABI-locked to the running compositor. Needed only for the g14-as-*source*
  direction; blac-Windows → g14 does not touch it.

## Steps

All of it lands in **one new file, `modules/viewflow.nix`** — `import-tree`
picks it up automatically, the same single-file shape `modules/deploy.nix` uses.

### Phase 1 — Linux (as built)

Landed in `modules/viewflow.nix` + the `viewflow` input in `flake.nix`. Three
`perSystem` packages: `viewflow` (no CUDA, portable), `viewflow-nvenc` (the
source-capable build) and `viewflow-linux-native` (the two CMake backends).
All three build. Four corrections to the predictions below, recorded because
each one cost a build cycle:

- **`protobuf` *is* needed after all** — see the correction in step 2, which was
  itself wrong. `protoc_bin_vendored` ships a prebuilt ELF whose interpreter
  does not exist in the nix sandbox, and `build.rs` calls
  `protoc_bin_vendored::protoc_bin_path()` directly without consulting `$PROTOC`.
  Rather than patchelf a vendored binary inside the cargo vendor dir, the
  package substitutes that one call for `std::env::var("PROTOC")` and supplies
  nixpkgs' protoc. Kept to a single token so a rev bump does not rot it.
- **`nlohmann_json` is an undeclared dependency.** `platform/linux-reverse/main.cpp`
  includes `<nlohmann/json.hpp>`; no `CMakeLists.txt` in the tree mentions it.
  Upstream builds against a distro-wide install.
- **There is nowhere to pass CMake flags to the NVENC encoder.**
  `crates/viewflowd/build.rs` invokes `cmake` itself with a hardcoded argument
  list, so `-DCUDAToolkit_ROOT` is not an option. `CMAKE_LIBRARY_PATH` and
  `CMAKE_INCLUDE_PATH` *from the environment* are the only lever. `libcuda.so`
  additionally needs `lib/stubs` named explicitly, since it ships with the
  driver rather than the toolkit — and both CUDA-linking derivations then need
  `autoAddDriverRunpath` so the driver's real copy resolves at runtime.
- **`-Werror` did not bite.** Step 4 predicted it would; at this rev, with
  nixpkgs 26.05's gcc 15.2, every CMake target compiled clean. No `-Wno-error`
  was needed. Do re-check on the next rev bump rather than assuming.

The scoped `allowUnfreePredicate` in step 3 turned out to be needed for a
different reason than stated: hosts already set `allowUnfree = true` globally
(`modules/hosts/types/minimal/default.nix:20`), but a host consumes these as
`self.packages.<system>.*`, which is built with the *flake's* nixpkgs instance
and not the host's — so the host-level allowance never applies and the
predicate has to live in the `perSystem` block.

The original step list follows, as the record of what was planned.

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

## The Windows half (Phase 2) — hand-work on the Windows peer

**This cannot come from nix and no amount of effort here will change that.** The
Windows targets need MSVC, the Windows SDK, WGC (`Windows.Graphics.Capture`) and
Media Foundation. There is no cross-build, and upstream publishes no binaries —
no releases, no tags, and `tools/package-windows-msi.py` is a packaging script
for artefacts you have already built yourself, not a download.

So the Linux side is deployed and the Windows side is a checklist. Run all of it
from whichever machine is booted into Windows — **blac or z14; the steps are
identical and none of them depend on the GPU vendor**, so the 840M needs nothing
extra. Paths below say `C:\Viewflow` on either.

For a first test, z14 is the easier peer: it is to hand, whereas blac's Windows
side has to be booted specially. Do the **Windows → g14** direction, which needs
nothing on g14 beyond what is already installed.

**The one rule that matters: build from the same rev.** `767739c1037eab84e7b5ba235056ec6b09b0e692`,
exactly what the `viewflow` input in `flake.nix` is pinned to. The QUIC control
protocol version is negotiated between peers; a mismatched pair does not
degrade, it refuses each other.

1. **Prerequisites.** Visual Studio 2022 with the "Desktop development with C++"
   workload (this is what supplies both the MSVC toolchain and CMake), and Rust
   via `rustup` on the **MSVC** toolchain (`x86_64-pc-windows-msvc`, the default
   — do not use the GNU one). No CUDA is needed on this side: Windows encodes
   through Media Foundation / VPL, not NVENC.

2. **Clone at the pinned rev.**

   ```powershell
   git clone https://github.com/gfhdhytghd/viewflow C:\Viewflow\src
   git -C C:\Viewflow\src checkout 767739c1037eab84e7b5ba235056ec6b09b0e692
   ```

3. **Build the orchestrator** (the Windows counterpart of the `viewflow`
   package, and the only Rust piece needed):

   ```powershell
   cd C:\Viewflow\src
   cargo build --release --locked -p viewflowd --bin vf-window-peer
   ```

4. **Build the native backend for the role you want.** Presenter shows g14's
   windows on Windows; source sends Windows' windows to g14. Both is fine.

   ```powershell
   # presenter -> viewflow-windows-windows.exe
   cmake -S platform/windows-window-presenter -B build/window-presenter -A x64
   cmake --build build/window-presenter --config Release

   # source -> viewflow_windows_reverse.exe
   cmake -S platform/windows-reverse -B build/window-source -A x64
   cmake --build build/window-source --config Release
   ```

5. **Generate the pairing identities.** Upstream ships no helper for this and is
   explicit that the repository's test TLS fixtures must not be used as real
   identities. Plain openssl is enough; the leaf's SAN has to match the
   `server_name` the other side connects with, and rustls wants the EKUs spelled
   out. Verified to produce a chain that `openssl verify` accepts:

   ```sh
   openssl req -x509 -newkey ed25519 -nodes -days 7 \
     -keyout pair-ca.key -out pair-ca.pem -subj "/CN=viewflow-pair-ca"

   # repeat for each of: g14-peer, windows-peer
   openssl req -newkey ed25519 -nodes -keyout NAME.key -out NAME.csr -subj "/CN=NAME"
   openssl x509 -req -in NAME.csr -CA pair-ca.pem -CAkey pair-ca.key \
     -CAcreateserial -days 7 -out NAME.pem \
     -extfile <(printf 'subjectAltName=DNS:NAME\nextendedKeyUsage=serverAuth,clientAuth\nkeyUsage=critical,digitalSignature\nbasicConstraints=critical,CA:FALSE\n')
   ```

   Copy `pair-ca.pem` + that side's `.pem`/`.key` to each machine; the CA key
   stays wherever you made it and never needs to travel. `0700` on the
   directory. These are 7-day certs by design — regenerating is the expected
   workflow, not an error state.

6. **Write the two JSON configs.** Absolute paths, no relative ones (upstream
   rejects them before it listens). Keep them by hand in `~/viewflow/` on g14
   and `C:\Viewflow\` on blac — they carry per-session cert paths and are not
   config-as-code. Pair over the tailnet: blac's Windows install is its own
   tailnet node, so use its `100.64.0.x`, not a LAN address.

   g14 as presenter (the easy direction — no Hyprland plugin needed):

   ```json
   {
     "bind": "0.0.0.0:44220",
     "certificate": "/home/phonkd/viewflow/g14-peer.pem",
     "private_key": "/home/phonkd/viewflow/g14-peer.key",
     "certificate_authority": "/home/phonkd/viewflow/pair-ca.pem",
     "role": "presenter",
     "backend": {
       "native": "/run/current-system/sw/bin/viewflow_linux_reverse",
       "args": ["--scale", "1", "--origin-x", "0", "--origin-y", "0"]
     }
   }
   ```

   blac-Windows as source:

   ```json
   {
     "bind": "0.0.0.0:0",
     "remote": "100.64.0.9:44220",
     "server_name": "g14-peer",
     "certificate": "C:/Viewflow/windows-peer.pem",
     "private_key": "C:/Viewflow/windows-peer.key",
     "certificate_authority": "C:/Viewflow/pair-ca.pem",
     "role": "source",
     "backend": {
       "native": "C:/Viewflow/src/build/window-source/Release/viewflow_windows_reverse.exe",
       "args": ["source", "--codec", "h264", "--scale", "1"]
     }
   }
   ```

   `100.64.0.9` is g14's tailnet address. Start the presenter first, then the
   source — upstream's own procedure everywhere is receiver-before-sender.

7. **For the other direction** (g14 as source), g14 additionally needs a capture
   plugin loaded in its running Hyprland — that is Phase 3 and is not done. See
   point 4 of "Hardware reality".

## Open decisions

1. ~~**Which pairing.**~~ **Resolved: g14 ↔ blac-booted-into-Windows.** Not the
   Linux↔Linux pairing the previous revision picked — blac is wanted on its
   Windows side. This is upstream's better-tested axis, so it is an improvement
   rather than a concession. blac's NixOS side keeps the packages anyway, so the
   Linux↔Linux pair remains available for free.
2. **z14 participation.** **Resolved, and the earlier "not implementable" was
   wrong in scope — it is an OS question, not a hardware one.**

   - **z14 running Linux: still blocked.** Verified again at the pinned rev
     while packaging — `platform/linux-reverse/CMakeLists.txt` opens with
     `find_package(CUDAToolkit REQUIRED)` and the decoder creates only
     `AV_HWDEVICE_TYPE_CUDA`, with no VAAPI or CPU path anywhere. The 840M
     cannot satisfy that in either role. The only route would be porting
     `platform/linux-reverse` to VAAPI, which means replacing the whole
     CUDA/GL-interop decode path — `av_hwdevice_ctx_create` is the small part;
     the `cuGraphicsGLRegisterImage` → `cuMemcpy2D` → GL texture interop in
     `gpu_decoder.cpp:115-130` is the real work. Upstream shows no interest in a
     non-NVIDIA Linux path.
   - **z14 running Windows: works, and is the recommended first test.** z14 is
     dual-boot. The Windows stack never touches CUDA, and the 840M's VCN block
     has a hardware H.264/HEVC/AV1 encoder (confirmed on the box). So
     z14-Windows → g14-Linux needs nothing that is not already built and
     deployed on the g14 side.

   What this does *not* do is make z14 a replacement for g14 as the **Linux**
   half of a pair — that is the CUDA-locked role, and it stays closed. So if the
   goal is "stop using g14 because it is loud and slow", this is a test bench,
   not a fix: it lets the stack be evaluated on hardware that is actually to
   hand, with g14 still doing the Linux job.
3. ~~**Whether to build at all before committing.**~~ **Resolved: built.** A
   `nix build .#viewflow` is a *package* build, not a `nixosConfigurations.<x>`
   toplevel, so it is inside the repo rule. All three packages were built before
   commit and the build found three real defects (vendored protoc, undeclared
   `nlohmann_json`, unreachable CMake flags) that no amount of reading would
   have caught. Worth the cycles; do it again on a rev bump.

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
- **Build fragility.** *Resolved better than feared.* All three packages build at
  the pinned rev with no `-Wno-error` and no source patching beyond the one
  protoc substitution. The three real defects are listed under "Phase 1 (as
  built)". Re-check on every rev bump: `-Werror` against a moving nixpkgs
  compiler is a latent failure, not an absent one. If the native helpers ever do
  resist, `vf-window-peer` alone still gives view-only sharing (upstream: "Omit
  `--input-native` for view-only Hyprland sharing").
- **Rollout.** g14 is not a deploy-rs target (laptops are deploy *clients*, no
  `deploy.hostname` in the registry), so it does not go through `deploy g14`.
  It also **cannot be rebuilt with `--target-host` from another machine**, which
  is worth writing down because it looks like it should work and fails in a way
  that would be actively harmful if forced:

  ```
  error: access to absolute path '/etc/nixos/hardware-configuration.nix'
         is forbidden in pure evaluation mode (use '--impure' to override)
  ```

  g14's registry entry (like blac's and z14's) imports
  `/etc/nixos/hardware-configuration.nix` by absolute path. Evaluating that from
  another machine reads *that machine's* hardware config — so `--impure` there
  would not fix it, it would bake the wrong hardware into g14's system. The
  absolute path is exactly why laptops are deploy *clients* and not deploy-rs
  nodes; the deploy nodes reference no absolute paths.

  So the evaluation has to happen on g14. Two routes:
  - from g14's own checkout, once the commit is on `main` there:
    `sudo nixos-rebuild switch --flake ~/git/nixconfig#g14 --impure`
  - or stage the committed tree on g14 without touching its git checkout —
    what was actually done here, since `main` is never pushed and g14's
    checkout therefore cannot see a fresh commit:

    ```sh
    git archive --format=tar HEAD \
      | ssh root@g14 'mkdir -p /tmp/nixconfig-vf && tar -x -C /tmp/nixconfig-vf'
    ssh root@g14 'cd /tmp/nixconfig-vf && nixos-rebuild switch --flake .#g14 --impure'
    ```

    `git archive HEAD` ships the *committed* tree, which matters when the main
    checkout is dirty with unrelated in-progress work (it usually is). Root over
    ssh works via Tailscale SSH; `phonkd` on g14 does **not** have passwordless
    sudo, unlike the servers.

  `--impure` is required either way, for the same absolute path.

  Nothing is enabled by the rebuild — the packages just appear on PATH.

  **Done on g14 on 2026-09-16.** All 12 binaries are on PATH,
  `libcuda.so.1` resolves to `/run/opengl-driver/lib/libcuda.so.1` in both the
  presenter and the NVENC source (so `autoAddDriverRunpath` did its job), and
  `viewflow_reverse_decoder_probe` initialises the GPU decode path for real:
  `renderer=NVIDIA GeForce RTX 3050 Ti Laptop GPU/PCIe/SSE2`. That is the
  presenter half of blac-Windows → g14 working end to end short of a live peer.

  Unrelated pre-existing breakage seen during that rebuild:
  `home-manager-phonkd.service` fails on g14 with
  "Existing file '~/.config/gtk-{3,4}.0/gtk.css.hm-backup' would be clobbered".
  It failed the same way at 21:47 on g14's own earlier rebuild that day, before
  viewflow was touched, so it is not from this change. Fix is to delete the two
  stale `.hm-backup` files (or set `home-manager.backupFileExtension`).

  blac cannot be rebuilt while it is booted into Windows (its NixOS side has
  been offline since roughly 2026-08-30). That costs nothing: the packages land
  there whenever it next boots NixOS, and the Windows peer does not come from
  nix anyway.
- **Back out.** Drop the `alwaysImport` entry and rebuild; there is no state, no
  service, no secret and no migration. The flake input can stay or go
  independently.
