# Chat index on GUI machines

**Repos:** phonkd/wutchatwusdat and phonkd/nixconfig  
**Status:** done (prepared for PR; activation pending review)

## Goal
Make `wutchatwusdat` available on all GUI machines to search and resume local Claude Code, Codex and OpenCode conversations.

## Approach
Publish the standalone tool as a Nix flake. Add a pinned input in nixconfig and install its default package through the shared, cross-platform `homeModules.gui` package list. Follow nixconfig's nixpkgs input.

## Steps
1. Published and built `github:phonkd/wutchatwusdat`; the source history contains no chat index or transcripts.
2. Added and locked the flake input and wired its package into the shared GUI module.
3. Parsed changed Nix files and verified shared Linux/macOS GUI import paths; submitted as the requested PR.

## Risks / rollout
The explicit request is a PR; activation follows review and merge. Existing client installations provide the resume commands. The tool creates its local index only when invoked; it does not change client configuration. Revert the input and package entry to remove it. Keep unrelated unpublished local commits out of this PR.
