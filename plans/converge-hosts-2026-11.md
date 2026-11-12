# Converge hosts on main and clean up git state
**Repo:** nixconfig   **Status:** paused — waiting for blac (holds 201's `c09a0b4`)

## Goal
Every deploy-rs server runs `main`, `main` evaluates for all of them, and the
checkout carries no stale worktrees or merged branches. Triggered by the
process-exporter exclude (`6f399de`) not being deployable to 203.

## Findings (2026-11-12, from z14)
| Host | Running | vs main |
|---|---|---|
| observability | `6f399de` (main) | current |
| 201-mono | `c09a0b4`, deployed 2026-11-11 14:28 | **only on blac's checkout** (not on z14 or origin; blac was off on 2026-11-12) |
| 203-media | `f30b6a0` (2026-10-30) | 40 behind; nixpkgs 1f607aa→c56a87d, tailscale 1.104.2→1.104.5 |
| 204-agent | `d4f01a1` | 81 behind |
| ext-mail | `d4f01a1` | 81 behind; deploy needs `-r` + sops fix (nixconfig-ops) |

- `main` fails to evaluate for 203: nixflix requires Seerr ≥ 3.5.0, while
  `modules/arr-slime.nix` pins `pkgs.seerr` (3.2.0, stable). The pin's
  justification (SABnzbd-only rollout) is finished:
  `plans/security-main-sabnzbd-2026-10.md` is done.
- The "203 activation is held" note in `plans/security-update-2026-10.md` is
  stale: the Immich gate was resolved by `plans/immich-upgrade-2026-10-28.md`
  (done; 3.3.5 is live on 203).

## Steps
- [ ] When blac is on: merge its `main` (contains `c09a0b4`) into this checkout's main. Nothing else proceeds before this.
- [ ] Seerr (not yet approved): back up `/var/lib/seerr` on 203, switch `nixflix.seerr.package` to the unstable package (3.5.x, as already done for immich), and confirm `main` evaluates for every node.
- [ ] Deploy 203 off-tailnet (tailscale bump), then 204, 201, ext-mail (`-r`, may still fail on sops). After each deploy, check that the host's workloads are active by name.
- [ ] Update the stale hold note in `plans/security-update-2026-10.md`.
- [ ] Git: `git worktree remove --force` the /tmp worktrees whose files were wiped and the clean, merged `.claude/worktrees`; delete fully merged local branches. Undecided: whether to also delete the ~25 unmerged September branches; the dirty `nvim-lua` worktree stays.
- [ ] Verify: `nixos_configuration_revision` is the same for all hosts; process-exporter series drop in the Mimir overview.

## Out of scope
The open oCIS migration, the Jellyfin HLS review branch, and the ext-mail sops key.
