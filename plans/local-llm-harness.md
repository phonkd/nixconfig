# local-llm-harness — small self-hosted model behind a good harness

**Repo(s):** `nixconfig` (`modules/hosts/mac.nix`, later `modules/hosts/204-agent.nix`),
plus possibly a small new harness repo for the benchmark set.
**Status:** draft — written 2026-08-24, execution deferred.

## Goal

Stand up a small model on hardware we already own — first the M4 Pro — and find
out how much routine local operations work it can carry when wrapped in a good
harness, instead of renting every agentic token from OpenRouter/Anthropic. If it
works, the same model backs hermes-agent for the cheap/mechanical half of its
traffic.

Today the only self-hosted inference here is *embeddings*: `bge-m3` on ollama on
`203-media` and `blac` (`modules/hosts/203-media.nix:103`,
`modules/hosts/blac.nix:68`). Nothing generative runs locally. hermes-agent on
`204-agent` runs `deepseek/deepseek-v4-flash` via OpenRouter
(`modules/hosts/204-agent.nix:133`), with Copilot and Anthropic keys alongside.

Two scars in this repo set the thesis. `plans/llm-noobservability.md` concluded a
7B-class model cannot free-associate correct LogQL and needs deterministic
scaffolding — grounding context, constrained decoding, a repair loop. And
`deepseek-v4-flash` proved unable to follow multi-step logic in hermes cron jobs,
which is why the mechanical ones were rewritten as `--no-agent` scripts. So:
**the harness is the deliverable, the model is a config string.** This plan is
the experiment that tests that claim.

## Hardware reality

| Host | Silicon | Usable for a model | Always on? |
|---|---|---|---|
| `Eliss-MacBook-Pro` | Apple M4 Pro, 24 GB unified | ~18 GB (default `iogpu.wired_limit_mb` ≈ 75%) | no — sleeps, roams |
| `blac` | RTX 5080, 16 GB VRAM | 16 GB, best local silicon | **no** (noted at `203-media.nix:99`) — but see WoL below |
| `blac` *(potential)* | 5080 16 GB **+ RTX 3080 10 GB** | **26 GB** — the only local box that clears 20 GB | on demand, via WoL |
| `203-media` | RTX 3060 Ti, 8 GB | 8 GB, shared with Jellyfin NVENC | yes |

That table is the whole tension: the two fast options are not always on, and the
always-on option is small and already busy. It decides phase 4, not phase 1.

### Wake-on-LAN to blac — the way out of that tension

"Always on" and "on demand" are not the same requirement, and this plan
conflated them. blac doesn't need to *stay* up; it needs to *come* up when a
request arrives. That reframes it from disqualified to the strongest candidate.

Two things make it interesting:

- **A second GPU is on the table.** An RTX 3080 (10 GB) exists but is **not
  installed — it doesn't fit the current small case.** With it, blac has
  **26 GB of VRAM**, the only local hardware that clears 20 GB. That is the
  difference between "14B is our ceiling" and "a 27B-class target plus a
  speculative drafter fits" — it directly un-parks the DFlash2 option below.
- **No WoL anywhere in this repo yet.** blac's NIC is `enp9s0`
  (`modules/hosts/blac.nix:37`); the NixOS side is one option,
  `networking.interfaces.enp9s0.wakeOnLan.enable = true`, plus enabling WoL in
  firmware. The magic packet wants an always-on sender on the same LAN —
  `203-media` is the natural one (`pkgs.wakeonlan`), and it already talks to
  `204-agent` over `192.168.3.0/24`.

Costs to weigh honestly before building on this:

- **Physical work, not just config.** A bigger case (or a riser), PSU headroom
  for two cards (~680 W of GPU alone, roughly), and slot spacing/thermals with
  two cards sandwiched. None of that is a `deploy` — and the case is the reason
  the 3080 isn't already in.
- **PCIe lanes are a non-issue here, despite appearances.** AM5 (Ryzen X3D)
  gives 24 usable CPU lanes — x16 PEG + 4 for a CPU-fed M.2 + 4 more — plus a
  Gen4 x4 chipset uplink. Realistically the 5080 drops to Gen5 x8 (bifurcated)
  and the 3080 lands on a chipset-fed x4, sharing that uplink with USB/SATA.
  For **layer-split** inference that barely matters: weights are transferred
  once at load, and per-token inter-GPU traffic is a few KB of activations.
  Expect a slightly slower model load and essentially unchanged tokens/s. It
  *would* matter for tensor parallelism (all-reduce every layer), which is
  another reason the mismatched-card layer-split path is the right one. A Gen5
  NVMe normally has its own CPU lanes, but on many boards populating the second
  CPU-fed M.2 forces the PEG to x8 — check that board's shared-slot table
  rather than assuming.
- **Mismatched cards.** Blackwell + Ampere means two CUDA arches. llama.cpp /
  ollama layer-splitting across unlike GPUs is fine; vLLM-style tensor
  parallelism really wants matched pairs. Assume layer-split, and expect the
  3080's layers to run at the 3080's pace.
- **Cold-start latency is the real UX cost.** Wake (~30–60 s) *plus* paging
  ~20 GB of weights into VRAM. For a Discord agent that answers in seconds
  today, a cold first token is a visible regression — so pair WoL with tiered
  routing (small always-on model on `203` for trivial turns, wake blac for the
  heavy ones, cloud as the instant escape hatch) rather than treating it as a
  drop-in replacement.
- **Keeping it awake.** Whatever wakes blac also needs an idle-suspend policy,
  or the "on demand" saving evaporates.

Useful precedent: home-manager's `services.ollama` has a `launchd.agents.ollama`
branch, so the Mac can serve **declaratively** — the same launchd-user-agent
pattern `mac.nix` already uses for syncthing (`modules/hosts/mac.nix:33`).

## Approach

Five phases, smallest useful slice first.

**0. Benchmark before serving.** ~20 real, recorded ops tasks with mechanical
pass/fail checks: nix option lookup (pairs with the `inix` tool), journal triage,
"what changed / what's broken on 201", commit-message drafting, and LogQL/PromQL
generation reusing the `llm-NOOBservability` question set. Baseline the current
`deepseek-v4-flash` first so local numbers have a reference line. Without this
the whole effort is taste, and model swaps stay unarguable.

**1. Serving on the Mac.** home-manager `services.ollama` in `mac.nix` — launchd
agent, declarative, and uniform with 203/blac so a model name is portable across
all three. Bind `127.0.0.1:11434` only: the Mac roams, and nothing on the LAN
should ever be allowed to depend on it.

**2. Harness.** Reuse **hermes-agent** as the harness, pointed at the local
OpenAI-compatible endpoint. It is already a flake input (`flake.nix:128`),
already packaged, and already carries toolsets, skills and MCP — one integration
serves both halves of this plan.

**3. Local operations — read-only first.** Log/journal triage, "what changed",
nix option lookup, commit-message drafts, PromQL/LogQL drafting. Nothing that
deploys, writes secrets, or mutates a host until the phase-0 hit-rate is proven.

**4. Hermes on a local model — hybrid, and probably not on the Mac.** A laptop
that sleeps and roams cannot be a dependency of an always-on Discord agent. If
0–3 succeed, the model for hermes moves to `blac` or `203` (see the table), and
routing goes hybrid: cheap/mechanical turns local, hard ones escalate to
OpenRouter/Claude. The existing keys stay as the fallback path, not the default.

## Model candidates

4-bit, sized for the Mac: Qwen3.5 30B-A3B MoE (~17 GB, ~3B active so fast, needs
the wired-limit raise), Qwen3.5 14B (~8 GB, the likely daily driver), Qwen3.5 4B
as the floor. All config strings — cheap to swap, which is exactly what phase 0
buys.

### Evaluated and parked: Qwen3.8-27B + DFlash2 speculative decoding

`z-lab/Qwen3.8-27B-DFlash2` (Apache-2.0, Aug 2026) is **not a standalone model** —
it is a 2B *draft* model for speculative decoding against `Qwen/Qwen3.8-27B`
(dense, 27B). DFlash2 is a block-diffusion drafter: it predicts a whole block of
tokens per pass, and decoding is **lossless** — greedy output matches the target
exactly, sampling preserves its distribution. So the speedup is genuinely free in
quality terms, which is why it's worth recording rather than dismissing.

It does not fit this hardware, for a reason worth writing down:

| Component | Q4_K_M |
|---|---|
| `ggml-org/Qwen3.8-27B-GGUF` target | **~19 GB** |
| `Qwen3.8-27B-DFlash2-GGUF` drafter | 1.1 GB |
| + KV cache | — |

That is >20 GB on a 24 GB machine whose default GPU wired limit is ~18 GB. Even
after raising `iogpu.wired_limit_mb` it leaves ~3 GB for macOS *and* the daily
driver work this laptop exists to do. It does not fit `blac` either — 19 GB does
not go into 16 GB of VRAM. **Speculative decoding buys latency, not footprint:
it adds a second model.** Our binding constraint here is memory, so this is the
right technique aimed at the wrong bottleneck.

Two further cautions found while checking:

- The headline "4.6× / 70 tok/s" is from an **M5 Max**. llama.cpp PR #27342's own
  Apple-Silicon benchmark — M5 Pro, Qwen3.8-27B Q4_K_M — reports **1.81×**.
  Assume the ~1.8× figure, not the marketing one.
- llama.cpp support is **PR #27342, still open** — a patched build, not upstream,
  so not in nixpkgs and not declaratively installable today. The GGUF card's
  `ollama run hf.co/z-lab/Qwen3.8-27B-DFlash2-GGUF` line is misleading: run alone
  that serves the 2B *drafter* as if it were a chat model. Upstream DFlash docs
  don't list ollama as a supported runtime at all.

**Revisit when** any of: the llama.cpp PR merges and lands in nixpkgs; a DFlash2
drafter ships for a model in the 14B class (only two exist today —
Muse-Glimmer-30B and Qwen3.8-27B); or the local-model host gains the memory.

**That last condition now has a live candidate.** blac with the 3080 added is
26 GB — 19 GB target + 1.1 GB drafter + KV fits with room to spare, and it is
the *only* local hardware that does. So DFlash2 is parked on **memory**, not on
merit, and the blac two-GPU build is exactly what would un-park it. It still
carries the two cautions above (expect ~1.8× on Apple Silicon and unknown-but-
better on CUDA; llama.cpp support is an unmerged PR, so this path is a patched
build either way). Nothing here changes phases 0–3, which stay on the Mac at
14B.

## Steps

1. ~~Land this plan on `main`.~~ *(done)*
2. Write the phase-0 task set + scorer; record the `deepseek-v4-flash` baseline.
3. Add `services.ollama` to the Mac's home-manager block in `mac.nix`
   (`127.0.0.1` only); pull a 14B and a 30B-A3B; `deploy mac`.
4. Measure tokens/s and memory pressure for both under real daily-driver load;
   decide whether `iogpu.wired_limit_mb` needs raising.
5. Point hermes-agent (run locally on the Mac, not 204) at the endpoint; score
   the phase-0 set through the real harness.
6. Only if 5 clears the bar: pick the always-on host, wire hybrid routing on
   `204-agent`, `deploy 204-agent`.

## Open decisions

- **Serving runtime** — recommend **ollama** (declarative via home-manager,
  uniform with the two NixOS hosts). Alternative: MLX (`mlx_lm.server`) for
  materially better Apple-Silicon throughput, at the cost of a bespoke,
  non-declarative launchd job. Revisit only if ollama's Metal speed is the
  measured blocker. Note that *any* speculative-decoding path (see DFlash2 above)
  forces patched llama.cpp or MLX and gives up the declarative ollama route — so
  treat "we want spec-decode" as the trigger to re-open this decision, not a
  detail to bolt on later.
- **Harness** — recommend **hermes-agent**; alternative is a purpose-built loop
  like `llm-NOOBservability`, which is right only if the task turns out narrow
  enough to hard-code.
- **Host for anything hermes depends on** — now leaning **`blac` woken by WoL**
  rather than a permanently-on box, since "on demand" is the actual requirement
  (see above). Alternatives: `203` (always on, but 8 GB shared with Jellyfin) vs
  staying cloud. Deferred to phase 4; phase 0–3 results decide it.
- **Whether to install the 3080 in blac** — a real hardware purchase (case,
  possibly PSU), justified only if phases 0–3 show a local model earning its
  keep at 14B. Decide *after* the benchmark, not before: 26 GB is the
  prerequisite for the 27B+DFlash2 tier, so the sequencing is
  measure → justify → buy, never the reverse.
- **All-local vs hybrid routing** — recommend hybrid, given the deepseek scar.
- **Tailnet exposure** — recommend never for the Mac endpoint; localhost only.

## Risks / rollout

- **Small-model quality is the whole risk.** Phase 0 exists to make failure
  visible instead of arguable, and to stop a bad model quietly degrading hermes.
- **A 17 GB model on a 24 GB working machine** costs battery, thermals and swap.
  Measure under real load in phase 4 before committing to the MoE.
- **Laptop sleep/roam** disqualifies the Mac as a service dependency — hence
  phase 4's host question, and the localhost-only bind in phase 1.
- **Rollout**: nothing touches `201-mono`. Each phase is one host's module;
  back out by reverting it and redeploying that host (`deploy mac`,
  `deploy 204-agent`).
