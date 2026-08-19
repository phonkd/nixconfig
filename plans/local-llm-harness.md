# local-llm-harness — small self-hosted model behind a good harness

**Repo(s):** `nixconfig` (`modules/hosts/mac.nix`, later `modules/hosts/204-agent.nix`),
plus possibly a small new harness repo for the benchmark set.
**Status:** draft — written 2026-08-19, execution deferred.

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
| `blac` | RTX 5080, 16 GB VRAM | 16 GB, best local silicon | **no** (noted at `203-media.nix:99`) |
| `203-media` | RTX 3060 Ti, 8 GB | 8 GB, shared with Jellyfin NVENC | yes |

That table is the whole tension: the two fast options are not always on, and the
always-on option is small and already busy. It decides phase 4, not phase 1.

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

**Model candidates** (4-bit, sized for the Mac): Qwen3.5 30B-A3B MoE (~17 GB,
~3B active so fast, needs the wired-limit raise), Qwen3.5 14B (~8 GB, the likely
daily driver), Qwen3.5 4B as the floor. All config strings — cheap to swap,
which is exactly what phase 0 buys.

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
  measured blocker.
- **Harness** — recommend **hermes-agent**; alternative is a purpose-built loop
  like `llm-NOOBservability`, which is right only if the task turns out narrow
  enough to hard-code.
- **Always-on host for anything hermes depends on** — `blac` (fastest, needs a
  wake/always-on decision) vs `203` (always on, 8 GB shared with Jellyfin) vs
  staying cloud. Deliberately deferred to phase 4; the phase 0–3 results should
  decide it.
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
