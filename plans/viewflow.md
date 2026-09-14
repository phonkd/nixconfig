# viewflow — cross-device window sharing between blac and the Mac

**Repo(s):** nixconfig (this repo only — upstream is consumed as a pinned
`flake = false` input)   **Status:** draft

## Goal

Share individual windows between **blac** (Hyprland, RTX, x86_64-linux) and
**Eliss-MacBook-Pro** (aarch64-darwin) so that an app keeps running on its own
machine while its window appears as a real window on the other one — with the
pointer and keyboard crossing over to it. Not a remote desktop: no full-screen
mirror, no second session, the app never moves.

Upstream is [gfhdhytghd/viewflow](https://github.com/gfhdhytghd/viewflow): a Rust
workspace (`viewflowd`) plus CMake/ObjC++ native backends per platform, GPL-3.0,
**no releases, no tags, no `flake.nix`**, and self-described as "an executable,
tested foundation rather than a finished three-platform product". `docs/project-status.md`
(written in Chinese) is candid that sessions still terminate on late frames and
that **macOS real-machine verification is deferred** (`macOS 实机验证暂缓`) —
upstream prioritised Linux → Windows. So the goal here is "installed, runnable by
hand, and we find out", not "a service we depend on".

## Approach

Two things drive the whole design:

**1. Use `vf-window-peer`, not the desktop-atlas launcher.** Upstream has two
separate paths and only one of them is sane to put in this config:

| | `vf-window-peer` (`docs/macos-window-sharing.md`) | desktop-drag launcher (`docs/desktop-start.md`) |
|---|---|---|
| Shape | one CLI + one JSON config per side | `prepare`/`start`/`stop` shell rig |
| Touches the live compositor | no (presenter side) | **yes** — creates a headless output and loads two plugins into the running Hyprland |
| macOS support | yes, documented both directions | Linux ↔ Windows only |
| Encoder | VideoToolbox on macOS, NVENC on the Hyprland source | NVENC, required |

The atlas launcher is the thing that does Win+drag-across-the-edge, and it is
also the thing that can wedge the desktop you are using. It is explicitly
Linux→Windows. We want Mac ↔ blac, so `vf-window-peer` is the path. Phase 3
below keeps the door open.

**2. Nothing runs at login.** Upstream's own words: "Nothing runs at login or
changes the main desktop persistently." Pairing is a per-session ephemeral CA
(7-day leaf certs in a `0700` dir), not long-lived credentials, so there is
**no sops secret to add** and nothing for a systemd unit to hold. The nix
deliverable is therefore *packages on PATH*, not `services.viewflow.enable`.
That also keeps a pre-alpha thing structurally incapable of breaking a boot.

**3. Direction asymmetry decides how much pain macOS is.** From
`docs/macos-window-sharing.md`: *"The receiver needs no Screen Recording or
Accessibility authorization. The source needs Screen Recording; return input
additionally needs Accessibility/event-post authorization for the actual
executable and its launch context."*

macOS TCC grants are keyed to the executable's identity and path. A nix store
path changes on every single rebuild, so a Screen Recording grant given to
`/nix/store/<hash>-viewflow-macos/bin/viewflow-macos-windows` is void the next
time the package is rebuilt. This repo has already been bitten by exactly this
class of problem — see the `kitty` cask comment in
`modules/hosts/types/gui/default.nix`, where the nixpkgs build could not hold a
TCC Microphone grant for cava and a signed cask had to take over.

Conclusion: **blac → Mac (Mac as presenter) is nix-native and clean. Mac → blac
(Mac as source) fights TCC** and needs a stable-path install, which is an open
decision below. Ship the clean direction first.

### Phases

- **Phase 1 — Linux (blac).** Package the Rust daemon + the two Linux native
  helpers. blac can present Mac windows and source its own.
- **Phase 2a — Mac as presenter.** Package `vf-window-peer` for darwin. Mac shows
  blac's windows. No TCC grants needed at all, so this works from nix as-is.
- **Phase 2b — Mac as source.** Build `platform/macos` (ScreenCaptureKit /
  VideoToolbox / Metal). Needs a TCC-stable install path — see open decisions.
- **Phase 3 — deferred.** The Hyprland metadata/capture plugins + atlas
  launcher. ABI-locked to the running compositor; not worth it yet.

## Steps

All of it lands in **one new file, `modules/viewflow.nix`** — `import-tree` picks
it up automatically, and it is the same single-file shape `modules/deploy.nix`
uses for `perSystem.packages.deploy-cli`. No `pkgs/` directory exists in this
repo and this change does not need to invent one.

### Phase 1 — Linux

1. **Pin the input** in `flake.nix`:
   ```nix
   viewflow = {
     url = "github:gfhdhytghd/viewflow";
     flake = false;
   };
   ```
   Pinned to a rev, deliberately *not* following HEAD — same reasoning as the
   `aerothemeplasma` pin. This repo is pre-alpha and rewrites its own runtime
   weekly; an implicit `nix flake update` that drags in a new protocol version
   would break both halves of a pair at once.

2. **`modules/viewflow.nix` → `perSystem.packages.viewflow`**:
   `rustPlatform.buildRustPackage` over `inputs.viewflow`, with
   `cargoLock.lockFile = "${inputs.viewflow}/Cargo.lock"` (the lock is committed).
   Edition 2024 / `rust-version = "1.85"` / `resolver = "3"` — fine on nixpkgs
   26.05. `cargoBuildFlags` limited to `-p viewflowd`. Needs `protobuf` (prost),
   `pkg-config`, and for `arboard`'s `wayland-data-control` feature the Wayland
   libs. Binaries wanted: `vf-window-peer`, `vf-hyprland-windows`, `vf-media-peer`.

3. **NVENC as an optional feature.** `--features native-gpu-nvenc` gates the
   Hyprland *source* encoder. Expose a `withNvenc` argument; enable it only
   where `config.noughty.host.gpu.hasNvidia` is true. This is what keeps z14
   (Radeon 840M, no NVENC) from building a CUDA closure it can never use, while
   blac gets the encoder. Unfree CUDA needs the scoped
   `nixpkgs.config.allowUnfreePredicate` pattern, not a blanket `allowUnfree` —
   see `modules/arr-slime.nix`, the only other CUDA consumer here.

4. **Two CMake native helpers**, as a second package `viewflow-linux-native`:
   - `platform/linux-reverse` → `viewflow_linux_reverse` (the presenter — this
     is what draws Mac windows on blac)
   - `platform/linux-window-input` → `viewflow-linux-window-input` (return
     input; uses the Wayland virtual keyboard/pointer protocols)

   Deps per upstream: FFmpeg, Wayland, xkbcommon, and CUDA/NVENC for the source
   side. Note every CMake target is built `-Wall -Wextra -Werror`, so a nixpkgs
   compiler newer than upstream tests against will fail the build on a warning;
   expect to need `-Wno-error` or a small patch.

5. **Put it on blac.** `modules/desktop.nix` is shared by blac/g14/z14, so add
   the packages behind the NVIDIA/Hyprland condition rather than into the flat
   `users.users.phonkd.packages` list — otherwise z14 pulls a CUDA build and
   g14 gains a tool for a pairing that does not exist. Simplest correct shape:
   a self-gating `config` block in `modules/viewflow.nix` keyed on
   `hostHasTag "hyprland" && gpu.hasNvidia`, added to `alwaysImport` in
   `modules/builder.nix`. That follows the `nvidia-desktop` precedent exactly.

6. **Firewall.** QUIC is UDP and the port is chosen per session (`bind` in the
   JSON config; upstream's examples use 44220). blac has no restrictive
   nftables ruleset like 203's, but confirm before the first run rather than
   debugging a silent QUIC handshake. Both machines are on the tailnet, so
   prefer pairing over `100.64.0.x` and skip LAN exposure entirely.

### Phase 2a — Mac as presenter

7. `perSystem.packages.viewflow` already covers aarch64-darwin for the Rust
   half — `vf-window-peer` is portable (the `cfg(windows)`/`cfg(linux)` deps in
   `crates/viewflowd/Cargo.toml` are target-gated; unix gets only `libc`).
   Add it to `environment.systemPackages` in `modules/hosts/mac.nix`, next to
   `deploy-cli`.

8. Write the presenter config (`role: "presenter"`, `backend.native` pointing at
   the Mac native binary with `["present", ...]`). Paths must be absolute per
   upstream. Keep it in `~/viewflow/` by hand — it carries per-session cert
   paths and is not config-as-code.

9. **The Mac rebuild is user-run.** `deploy` only covers the five NixOS hosts;
   the Mac needs
   `sudo nix run nix-darwin/nix-darwin-26.05#darwin-rebuild -- switch --flake ~/git/nixconfig --impure`
   (see `nixconfig-ops`). So Phase 1 gets deployed autonomously, Phase 2 gets
   handed over with that one line.

### Phase 2b — Mac as source

10. `perSystem.packages.viewflow-macos`: `cmake -S platform/macos`, building
    `viewflow-macos-windows` and `viewflow-macos-probe`. Needs `apple-sdk_15`
    (ScreenCaptureKit, VideoToolbox, AppKit, Metal, MetalPerformanceShaders,
    CoreImage/CoreMedia/CoreVideo, QuartzCore) and
    `CMAKE_OSX_DEPLOYMENT_TARGET=13.0`. Build `arm64` only — the CI's
    `arm64;x86_64` fat build is pointless for an M4. Same `-Werror` caveat as
    step 4, more likely to bite here since upstream tests against Xcode's clang
    and the SDK version will differ. (Checked against the locked nixpkgs rev:
    `apple-sdk_14`/`_15`/`_26` all exist. Start at `_15` — the Mac runs Tahoe so
    `_26` matches the OS, but a newer SDK means more new clang warnings, and
    every target here is `-Werror`.)

11. Grant Screen Recording (and Accessibility, if return input is wanted) to
    whatever stable path the open decision below picks. Launch from the GUI
    session, not ssh — upstream notes an ssh session has a different permission
    identity. Then `viewflow-macos-probe --list-windows` to get window IDs for
    the `--window` args.

### Phase 3 — deferred

12. Not now. For the record, the route is `hyprlandPlugins.mkHyprlandPlugin`
    against `inputs.hyprland.packages.${system}.hyprland` (this repo already
    tracks the Hyprland flake with submodules, and `programs.hyprland` is the
    NixOS half while HM gets `package = null`). The blocker is that the plugin
    "compares the full Hyprland/dependency ABI hash at load time and refuses to
    load if it was not built against the running compositor" — so every
    Hyprland bump becomes a paired rebuild, which is the same tax
    `plans/hy3.md` already weighs, for a much less proven plugin.

## Open decisions

1. **Mac source TCC path.** *Recommended:* ship Phase 2a only at first, and
   drive Mac→blac later. When it is wanted, the least-bad option is an
   `activationScript`/HM step that copies the built binary to a fixed path
   (`~/Applications/Viewflow/` or `/usr/local/libexec/viewflow/`) and grant TCC
   there, accepting that the copy is outside the store. *Alternative:* build
   upstream's unified `.app` out of band with `tools/build-macos-app.py` and
   treat it like the hand-built Yubico Authenticator already documented in
   `gui/default.nix` — self-signed, unmanaged, but it holds its grants. There is
   no cask.
2. **Which Linux hosts.** *Recommended:* blac only (NVENC + it is the desktop
   that pairs with the Mac). *Alternative:* all three hyprland hosts without the
   NVENC feature, so z14/g14 can at least *present*. Cheap to add later.
3. **Pin vs. follow HEAD.** *Recommended:* pin a rev, bump deliberately, and
   bump **both** machines in the same change — the QUIC protocol version
   ("Protocol 2.1") is negotiated between peers and a half-updated pair will
   simply refuse each other.
4. **Whether to build at all before committing.** The repo rule is "never verify
   with full evals", aimed at `nixosConfigurations.<x>` toplevel builds. A
   `nix build .#viewflow` is a *package* build, not a host closure, and it is
   unavoidable here: `buildRustPackage` needs a real vendor hash and four
   CMake projects need their `-Werror` surprises found. Recommended to build the
   packages, and still not build any host toplevel.

## Risks / rollout

- **Upstream maturity is the main risk.** `docs/project-status.md` reports
  session-terminating bugs as *current*: NVENC timeouts ending runs, atlas
  capacity overflow killing a whole group, "呈现确认超时" (presentation-ack
  timeout) unresolved, and clipboard/file-drag/per-app-audio explicitly *not*
  deliverable yet despite the protocol existing. The `deploy/` directory is 40+
  scripts named things like `check-failed-v21-post-force-pre-linux-stage-rollback-schema7-abort-c9b05e9-recovery-v2.sh`,
  which is its own signal about process. Mitigation is structural: packages
  only, no unit, no login hook, nothing in the boot path. Worst case is a CLI
  that exits.
- **Build fragility.** Four CMake projects at `-Werror` plus a Rust workspace
  at `clippy::pedantic`, none of it ever built under nix. Expect patches. If
  the native helpers resist, Phase 1 still has standalone value: `vf-window-peer`
  alone gives view-only sharing (upstream: "Omit `--input-native` for view-only
  Hyprland sharing").
- **Rollout.** Phase 1: commit to `main`, `deploy blac`. Phase 2: same commit,
  then hand the user the `darwin-rebuild` line. Nothing is enabled by either
  rebuild — the packages just appear on PATH.
- **Back out.** Drop the `alwaysImport` entry (or the Mac `systemPackages`
  line) and redeploy; there is no state, no service, no secret and no migration.
  The flake input can stay or go independently.
