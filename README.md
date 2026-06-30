# nixconfig

NixOS / nix-darwin / home-manager config.

## How it works

flake.nix pulls in everything under modules/ automatically via import-tree.
Drop a new .nix file in there and it's picked up - no central list to edit.

Hosts are defined in lib/registry.nix - one stanza per machine with its platform,
desktop env, tags, gpu, etc. modules/builder.nix reads the registry and routes
each host to the right config type (nixos, darwin, home-manager).

Modules gate themselves on host facts exposed by the noughty module
(lib/noughty/). Enable a module on a host by setting a tag or attribute in the
registry - no manual wiring.

## Quick start

```bash
# Build for a host
nixos-rebuild switch --flake .#hostname
# Darwin
darwin-rebuild switch --flake .#hostname
```

## Secrets

Managed with sops-nix. Decryption keys are expected at the standard paths.

## Structure

```
flake.nix          # entry point, inputs
lib/
  registry.nix     # host definitions (single source of truth)
  noughty/         # host fact module for self-gating
modules/           # feature modules (auto-imported)
  builder.nix      #registry → config routing
dotconfig/         # per-user dotfiles
```