# llm-agents.nix on GUI desktops

**Repo(s):** nixconfig  **Status:** in-progress

## Goal

Add numtide/llm-agents.nix as a flake input for GUI desktop packages. Use its Codex, Claude Code, and OpenCode packages when their locked versions are newer than the versions currently configured.

## Approach

Lock the upstream flake with its own nixpkgs pin so its prebuilt packages can use the upstream cache. Compare each locked package version before changing the desktop package selection.

## Steps

- [x] Add and lock the flake input.
- [x] Compare versions: keep Codex from nixpkgs-unstable (Numtide 0.159.2 < 0.159.3); switch Claude Code (2.1.286 > 2.1.284) and OpenCode (1.18.34 > 1.18.31).
- [ ] Parse the changed Nix files, commit to local main, and deploy any changed NixOS desktop hosts.

## Risks / rollout

Claude Code and OpenCode change the NixOS desktop home closure. The Numtide cache should supply their builds; the lock pin must be updated to receive newer daily upstream releases.
