# work-tunnel-watch — notice when the bedag SSH tunnels are down, offer to start them

**Repo(s):** `nixconfig` (new HM module, Mac-only). One input comes from the
private `~/git/bedag-setup` repo — the tunnel start command.
**Status:** draft

## Goal

Today, when the work `ssh -D` gateway tunnels are not running, nothing says so.
sing-box keeps happily accepting connections on `127.0.0.1:2080`, routes the work
domains at its `socks` outbounds on `127.0.0.1:30001-30006`, and every one of
those dials fails. The user-visible symptom is a browser tab that hangs and then
errors, or a `kubectl` that times out — with no hint that the cause is a dead
tunnel rather than a dead service, a bad VPN, or a broken cluster.

Wanted: when a **burst** of outbound dials to the tunnel SOCKS ports fails, put up
**one** dialog — "work tunnels look down, start them?" — with a button that
actually starts them. Quiet the rest of the time.

Two properties matter and shape the whole design:

- **Demand-driven, not a timer.** A poll-every-60s "tunnels are down!" nag would
  fire all evening and all weekend. The alert should only exist when something
  *tried* to use a tunnel and failed. That is the entire reason this watches the
  sing-box log instead of just probing the ports on a schedule.
- **Ask, don't auto-start.** Bringing the tunnels up is interactive — the work
  setup is Yubikey-backed (`modules/work/default.nix` enables `pcscd` +
  `yubikey-manager`), so a silent background `ssh` would at best sit waiting on a
  touch the user never sees, at worst burn through retries.
  *(Assumption, confirmed or killed in Step 0: if the bedag ssh config
  authenticates non-interactively, "Open decisions" has the supervise-instead
  option, which is strictly better when it applies.)*

## Background — the pieces that already exist

| Piece | Where | Relevant detail |
|---|---|---|
| sing-box listener | `modules/proxy.nix` | mixed HTTP+SOCKS on `127.0.0.1:2080`, launchd user agent, `KeepAlive.Crashed` |
| sing-box log | `~/Library/Logs/sing-box.log` | `StandardOutPath` + `StandardErrorPath` of that agent; `log.level = "info"`, so ERROR lines are included |
| tunnel outbounds | `~/git/bedag-setup/singbox.json` (**not in this repo**) | six `socks` outbounds on `127.0.0.1:30001-30006` + the domain/ip_cidr rules that pick between them |
| the tunnels themselves | bedag-setup / by hand | `ssh -D` gateway tunnels; exact start command TBD (Step 0) |
| host wiring | `modules/hosts/types/gui/default.nix:99` | `homeModules.proxy` is imported **only** by `gui-darwin`, i.e. only `Eliss-MacBook-Pro` |

This whole plan is Mac-only for the same reason `proxy.nix` is: no NixOS host
imports the proxy module, and `~/git/bedag-setup` does not exist on the Linux
boxes.

## Approach

One new launchd user agent, `work-tunnel-watch`, running a small script. It is a
**state machine with four states** — idle, suspect, asking, snoozed — and the
value is entirely in the transitions being conservative.

```
  tail sing-box.log
        │  ERROR line naming 127.0.0.1:3000[1-6]
        ▼
   ┌──────────┐   N failures within W seconds    ┌──────────┐
   │   idle   │ ───────────────────────────────► │ suspect  │
   └──────────┘                                  └────┬─────┘
        ▲                                             │ probe the ports
        │                                             ▼
        │                                     ports answer? ── yes ──► back to idle
        │                                       (not a tunnel fault: don't ask)
        │                                             │ no
        │                                             ▼
        │                                       snoozed? ── yes ──► back to idle
        │                                             │ no
        │                                             ▼
        │                                    ┌──────────────┐
        ├──── "Not now" (snooze 30m) ────────│    asking    │
        └──── "Start"  → run start cmd ──────└──────────────┘
                       → re-probe → report outcome
```

**Why log-tail as the trigger and port-probe as the verdict.** The log answers
"did anyone care?" — cheap to detect, but log formats are a soft contract and
parsing them for *truth* is fragile. The probe answers "is it actually down?" —
authoritative, but says nothing about demand. Using each for what it is good at
means a sing-box log-format change degrades this to "no alert" rather than to
"false alerts", which is the right failure direction for something whose output
is a modal dialog.

The threshold (N failures in W seconds) is what turns "one flaky request" into
"the tunnel is down". Start at **N=3, W=60**, both as module options.

### Detecting the failures

The expectation is that the ERROR line for a failed SOCKS dial contains the
tunnel's own address, because the dial that fails *is* the dial to
`127.0.0.1:3000X` — something like:

```
ERROR[…] [3608275395 2ms] inbound/mixed[mixed-in]: open outbound connection:
  socks connect tcp 127.0.0.1:30001->…: dial tcp 127.0.0.1:30001: connect: connection refused
```

If so, the matcher is just `ERROR` + `127\.0\.0\.1:3000[1-6]` and no correlation
is needed. **This is the one thing to verify before writing the module** — hence
Step 0. If the address turns out *not* to be on the ERROR line, the fallback is to
correlate on sing-box's per-connection id (`[3608275395]`), which appears on both
the `outbound/socks[<tag>]` INFO line and the ERROR line; that needs a small
id→tag LRU, and is the reason to prefer the simple form if it works.

### Probing

`nc -z -w2 127.0.0.1 3000X` (or a bash `/dev/tcp` connect) across all six ports.
Verdict "down" only if **none** answer — one dead gateway out of six is a
different problem and should not trigger the "start your tunnels" dialog.

Caveat to check in Step 0: an `ssh -D` listener can in principle outlive a wedged
SSH session, in which case the port answers while dials still fail. If the bedag
ssh config sets `ServerAliveInterval`/`ServerAliveCountMax`, ssh exits and the
listener disappears — the port probe is then sufficient. If it does not, escalate
the probe to a real SOCKS5 CONNECT through the port to a known-reachable work
host, and add `ServerAliveInterval` to the bedag config while there.

### Asking

`osascript -e 'display dialog …'`, **not** `display notification`:

- `display notification` needs the calling app (Script Editor) to hold
  Notification Center permission — a per-machine TCC grant that can silently be
  off. A "helpful alert" that no-ops is worse than none.
- `display dialog` has no such gate, and it gives real buttons, which is the whole
  point: the ask has to be actionable.

A home-manager `launchd.agents` unit lands in `~/Library/LaunchAgents` and so runs
in the Aqua GUI session, where `display dialog` renders. Add `activate` so it
comes to the front rather than lurking behind windows.

Buttons: `{"Not now", "Start tunnels"}`, default `"Start tunnels"`. On "Start
tunnels": run the configured command, re-probe, and report the outcome in a second
short dialog (success, or the command's stderr). On "Not now" or dialog timeout:
snooze.

### Snoozing

A state file under `~/.local/state/work-tunnel-watch/`. "Not now" snoozes for
`snoozeMinutes` (default 30). Also snooze after a *successful* start, to cover the
window where the log still holds pre-start failure lines. Without this the thing
re-asks immediately and becomes exactly the nag it was meant to replace.

### Ergonomics: a `work-tunnels` CLI

Cheap to add alongside, and it makes the agent debuggable instead of magic:

- `work-tunnels status` — per-port up/down
- `work-tunnels start` — the same start command the dialog runs
- `work-tunnels snooze [min]` / `work-tunnels unsnooze`
- `work-tunnels watch --once` — run one probe+ask cycle, for testing the dialog
  without waiting for a real failure burst

## Steps

**Step 0 — reconnaissance on the Mac (do this first).** Not optional: two design
branches above depend on it, and one required input does not exist anywhere in
this repo.
1. Capture a real failure. With the tunnels stopped, `curl` a work domain through
   the proxy and watch `tail -f ~/Library/Logs/sing-box.log` → confirm whether the
   ERROR line carries `127.0.0.1:3000X`. **Paste one real line into this plan.**
2. Read `~/git/bedag-setup/` for how the tunnels are started today (script? shell
   function? `ssh -D` by hand?) and whether `ssh.nix` sets `ServerAliveInterval`.
   Record the exact start command.
3. Confirm whether starting them needs a Yubikey touch.

**Step 1 — `modules/work/tunnel-watch.nix`.** Define
`flake.homeModules.work-tunnel-watch` with options: `enable`, `logFile` (default
`${config.home.homeDirectory}/Library/Logs/sing-box.log`), `ports` (default
`[30001 … 30006]`), `failureThreshold` (3), `windowSeconds` (60), `snoozeMinutes`
(30), `startCommand` (**required**, from Step 0). Build the watcher with
`pkgs.writeShellApplication` so `shellcheck` runs at build time and
`runtimeInputs` pins the `nc`/`osascript` paths.

**Step 2 — the launchd agent.** `launchd.agents.work-tunnel-watch`, mirroring the
sing-box agent's conventions in `proxy.nix` but with two deliberate differences:
`ProcessType = "Background"` (this one *is* background work, unlike the proxy,
which sits in the interactive path and says so in a comment), and
`KeepAlive = true` rather than `Crashed`-only — a `tail -F` loop that exits for any
reason should come back. Keep `ThrottleInterval = 30`. Own log at
`~/Library/Logs/work-tunnel-watch.log`.

**Step 3 — wire it in.** Import `self.homeModules.work-tunnel-watch` from the
`flake.homeModules.proxy` body in `modules/proxy.nix`. That file already owns the
log path and the sing-box lifetime, so the coupling is real, and putting the
import anywhere else splits one fact across two files. Add a cross-reference
comment at the `StandardOutPath` line: *this path is parsed by tunnel-watch*.

**Step 4 — the `work-tunnels` CLI** (same derivation, dispatch on `$1`), added to
`home.packages`.

**Step 5 — verify.** `nix eval` the darwin config's HM activation — never a full
toplevel build, see the `nixconfig` skill — then land on `main` and `deploy` the
Mac. Functional test: `launchctl list | grep tunnel-watch`; stop the tunnels;
`work-tunnels watch --once` → dialog appears → "Start tunnels" → tunnels come up.
Then the real path: stop the tunnels, hit a work URL three times, confirm the
dialog fires on its own and that a fourth request does *not* re-ask.

**Step 6 — mark this plan `done`.**

## Open decisions

1. **Supervise the tunnels instead of asking.** If Step 0 finds the tunnels
   authenticate non-interactively, the better answer is not an alert at all — it is
   six `launchd.agents.work-tunnel-<n>` units with `KeepAlive = true`, and the
   problem stops existing. *Recommendation: take this only if Step 0 says no
   Yubikey touch is needed.* The two are not exclusive: supervise them, and keep
   the watcher as the "supervision itself is failing" backstop, with its dialog
   text changed to say so.
2. **Where `startCommand` lives.** *Recommended:* an option in this repo whose
   value points at a script in `bedag-setup`, so work specifics stay in the work
   repo and this module stays generic. *Alternative:* spell the `ssh -D`
   invocations out here — rejected, it duplicates the work repo and will drift.
3. **Threshold N=3 / W=60s.** A starting point. The options are baked in at build
   time, not read at runtime, so expect one round of adjustment after living with
   it.
4. **Dialog vs. menu-bar indicator.** A dialog interrupts; a menu-bar dot
   (xbar/SwiftBar) informs passively. *Recommendation: dialog* — the ask was to be
   *asked*, and a passive dot is one more thing to not look at. Revisit if the
   dialog proves annoying.
5. **sing-box log growth.** Nothing rotates `~/Library/Logs/sing-box.log` today,
   and this plan makes it load-bearing. Out of scope here, but worth a follow-up
   (`newsyslog.d` entry). `tail -F` survives rotation, so adding it later does not
   break the watcher.

## Risks / rollout

- **False positives.** Guarded three ways: the burst threshold, the "all six ports
  dead" probe verdict, and the snooze. Worst realistic case is one unnecessary
  dialog, dismissed with "Not now".
- **Log-format drift on a sing-box upgrade.** Degrades to silence, not to noise
  (see the rationale above). Mitigation: `work-tunnels watch --once` makes it a
  ten-second check after any sing-box bump.
- **Dialog from a background agent doesn't show.** The one thing that would sink
  the feature. Tested directly in Step 5 before anything depends on it; if Aqua
  session access turns out to be a problem, fall back to a small always-running
  menu-bar helper.
- **Rollout / back-out.** `deploy Eliss-MacBook-Pro`; back out by setting
  `enable = false` (the agent unloads on the next activation) or reverting the
  commit. Nothing else depends on it, and sing-box's own behaviour is untouched —
  this module only *reads* its log.
