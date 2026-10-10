# Spotifast

**Repo(s):** nixconfig   **Status:** in-progress

## Goal

Add Spotifast to the shared Linux desktop package set for z14 and blac.

## Approach

Use the official `github:crmne/spotifast` flake package with its upstream
nixpkgs and Rust toolchain pins. Install alongside Spotify in the existing
desktop module.

## Steps

- [x] Add and lock the upstream input, then reference its default package.
- [x] Parse the changed Nix files and review the lockfile diff.
- [ ] Commit to local main and activate on z14 with its native local rebuild.

## Risks / rollout

The initial Rust build may take time. Neither Linux desktop is a deploy-rs
node; z14 is the current host, and blac receives this package on its next local
rebuild. Remove the package reference and input to roll back the configuration.
