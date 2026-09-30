# fast-llm-tools — snappy one-shot LLM helpers on Cerebras

**Repo(s):** `nixconfig` (a new home-manager module, e.g. `modules/fast-llm.nix`,
plus a hyprland bind and a zsh widget). The script is small enough to live
inline; it only gets its own repo if it grows past one file.
**Status:** draft — written 2026-09-30.

## Goal

Cerebras serves Qwen 3.8 27B at a speed where a whole answer lands in a fraction
of a second. That speed changes which tools are worth building. At this latency
an LLM call feels like a local command, not a chat, so it can sit behind a
keystroke without breaking flow. Build a few tiny tools that exist *because*
it's that fast:

1. **`q`, the CLI:** `q "how do I tar a dir excluding node_modules"` streams the
   answer to stdout. Piping works too: `git diff | q "commit message"`.
2. **Fix the last command:** a zsh widget. When a command fails, press a key and
   the buffer is replaced with a corrected command. You review it and press Enter;
   it never auto-executes.
3. **rofi prompt:** `SUPER+A` opens rofi, you type a question, and the answer
   shows in rofi and is copied to the clipboard. Optionally the answer is a shell
   command that you can confirm and run in a terminal.

Explicitly *not* a chat UI, an agent, or a hermes replacement. These are
one-shot calls with no tools and no memory.

## Approach

**One core script, three thin front-ends.** The core, `fastllm`, is a
`writeShellApplication` that uses `curl` + `jq`. It sends a single
`/v1/chat/completions` request to `https://api.cerebras.ai/v1` (OpenAI-compatible)
with `stream: true` and prints the tokens as they arrive. A flag selects a system
prompt per mode:

| mode | system prompt gist | output |
|---|---|---|
| `ask` | terse answer, no preamble | free text |
| `cmd` | "reply with exactly one shell command for zsh on NixOS/macOS, no prose, no fences" | one line |
| `fix` | given the failed command, its exit code and stderr tail, "reply with the corrected command only" | one line |

The model and the endpoint are env/config values (`FASTLLM_MODEL`,
`FASTLLM_BASE_URL`), so switching to another fast provider later is a config
string, not a rewrite. That matches the local-llm-harness thesis.

**Front-ends:**

- **CLI `q`** — calls `fastllm ask`, and stdin (if present) is prepended as
  context.
- **zsh fix widget** — a `precmd` hook stores the last command and its exit code.
  Capturing stderr is the hard part, and it's handled in stages. v1 re-runs
  nothing and sends only the command plus its exit code. v2 captures the stderr
  tail of commands that are marked safe to re-run, or reads it from kitty's
  last-command-output via shell integration (see open decisions). The widget
  calls `fastllm fix` and puts the result into `$BUFFER`. It's bound to something
  like `Esc Esc` or `^X^F`, next to the existing binds in `modules/shell.nix:71`.
- **rofi** — `rofi -dmenu -p ask` → `fastllm ask` → the result goes to
  `rofi -e` or into a second dmenu, then to `wl-copy`. Bind it in
  `modules/hyprland.nix` next to `SUPER, D` / `SUPER, V`.

**Secret:** the Cerebras API key lives in Bitwarden and is read through the
existing secretspec + `bw` flow (`modules/secretspec.nix`), cached in the session
like the other user-side keys. It stays out of sops because this is a user tool,
not a host service. If the per-call `bw` round-trip adds noticeable latency, read
the key once at login into a `0600` file under `$XDG_RUNTIME_DIR`.

## Steps

1. **Spike (no nix):** use curl to hit Cerebras with the Qwen 3.8 model id and
   measure time-to-first-token and total time for a 1-line `cmd` answer from
   z14 and the Mac. Confirm the exact model id (`/v1/models`) and the
   free-tier rate limits. If TTFT is over ~300 ms, the "feels instant" premise
   is weaker, and step 4's UX should stream visibly.
2. **`fastllm` + `q`:** add a home-manager module with the script, the system
   prompts and the secret wiring. Enable it on z14 and the Mac. Verify that
   `q "…"` and `git diff | q …` work.
3. **zsh fix widget (v1: command + exit code only).** Add the widget and a
   binding, and verify on a few classic typos (`gti status`,
   `nix-shell -p foo` → `nix shell nixpkgs#foo`, a missing `sudo`).
4. **rofi front-end + hyprland bind** (z14 only; the Mac has no rofi — see open
   decisions).
5. **fix widget v2:** feed stderr using whichever capture method step 3 showed is
   viable.
6. `deploy z14`, and rebuild the Mac via its usual path; mark this plan done.

## Open decisions

- **Model id / size.** Default: Qwen 3.8 27B, the model on Cerebras's public
  tier. The alternative is a smaller or larger Cerebras model if one is faster
  or more accurate for single-command answers. It's decided in the step 1 spike.
- **Stderr capture for `fix`.** *Recommendation:* start with kitty shell
  integration's last-command-output (`kitten @ get-text --extent
  last_cmd_output`), since kitty is already the terminal. It needs
  `allow_remote_control` scoped to the socket. The alternative is a zsh wrapper
  that tees stderr for every command. That's invasive, it breaks TTY-aware
  programs, and it's rejected unless kitty's route fails.
- **Replace `pay-respects`/`thefuck`?** None is installed today, so there's
  nothing to replace. The LLM widget is the only "fix" path.
- **Mac launcher.** rofi is Linux-only. On the Mac the `q` CLI works as is; a
  Hammerspoon hotkey + `hs.dialog` prompt (next to the dictation setup) is the
  obvious mirror, but it's deferred until the rofi version proves useful.
- **Auto-run `cmd` answers from rofi?** Default: **no**. Copy only, or open a
  terminal with the command pre-filled and not executed. A fast model is still a
  model.
- **Privacy.** Anything sent to `fix`/`q` goes to Cerebras, and that can include
  stderr and piped content with paths, hostnames or secrets. *Recommendation:*
  `fix` sends only the command and a truncated stderr tail, and never env or file
  contents. `q` sends only what you piped in.

## Risks / rollout

- **Nothing server-side:** it's home-manager only, on z14 (and later the Mac),
  and needs no 201/homelab changes. Rollout is `deploy z14`. To back out, remove
  the module import or the keybind.
- **Provider churn:** Cerebras is new for this model, so tiers, rate limits and
  pricing may change. The base-URL/model env vars keep a swap to OpenRouter (or a
  local model from `local-llm-harness`) a one-line change.
- **A wrong "fix" gets run:** mitigated by never auto-executing. The widget only
  fills the buffer.
- **Latency from secret lookup:** a `bw` call per invocation would ruin the
  snappiness, so cache the key per session (see Approach).
