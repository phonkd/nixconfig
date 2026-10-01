# Agent Deck on GUI desktops

**Repo(s):** nixconfig  **Status:** in-progress

## Goal

Provide a terminal view for Codex and Claude Code sessions on the Linux desktops and Mac, using the existing subscription-backed CLIs.

## Approach

Install Agent Deck from the already locked `llm-agents` input in the shared GUI home module. Include tmux, which Agent Deck uses to keep sessions alive when detached. Add an `ad` shell function: bare `ad` starts Codex in the current directory, `ad claude` starts Claude Code, and `ad agents` opens the board. Keep the existing Codex and Claude Code package choices.

## Steps

- [x] Add Agent Deck, tmux, and the `ad` command to the shared GUI module.
- [ ] Parse the changed Nix file, commit it with the staged `llm-agents` input it depends on, and activate it on the available desktop host.

## Risks / rollout

The package adds to the Home Manager closure on blac, z14, and the Mac. Their existing AI CLI packages remain as configured. The desktop hosts have no deploy-rs nodes, so activation uses each machine's local rebuild command.
