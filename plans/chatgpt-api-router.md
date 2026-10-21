# ChatGPT subscription API router

**Repo:** nixconfig  
**Status:** in-progress

## Goal

Provide an OpenAI-compatible API backed by the user's ChatGPT/Codex subscription,
hosted in the homelab for use by existing API clients.

## Approach

Run CLIProxyAPI on 201-mono using the native NixOS module and package from the
existing pinned nixpkgs-unstable input. The stable input lacks the module.
Expose `https://models.home.phonkd.net/v1` through the app registry and Traefik's
tailnet IP filter. Bind the backend to loopback on port 8317 and require a random
client API key stored in sops. Use a separate management key for OAuth enrollment.
Keep refreshed OAuth credentials in the service's private state directory.

## Steps

- [x] Check existing adapters, native module options, upstream config, and ports.
- [x] Add the service, encrypted keys, and internal route.
- [x] Parse changed Nix files, review wiring, and commit on main without pushing.
- [ ] Deploy 201 and verify routing, authentication, and service health.
- [ ] Complete ChatGPT OAuth enrollment with the user and verify an inference request.

## Decisions

The user authorized choosing a router and hosting it in the homelab. CLIProxyAPI
provides Chat Completions and Responses compatibility and native NixOS integration.
Clients use bearer authentication; browser SSO would interrupt API requests.
No paid API fallback is configured. Available models and limits follow the account.

## Rollout / rollback

Deploy with `deploy 201` after committing. Check existing Traefik service health
as well as the new endpoint. Disable the new service and registry entry and
redeploy to roll back. OAuth sign-in requires the account owner's browser approval;
never store OAuth tokens in the repository or Nix store.

The first deploy stopped before activation because stable's NixOS manual redirect
table lacks the newer module's anchors. Set the native
`documentation.nixos.checkRedirects = false` option and register the module with
`documentation.nixos.extraModules` so its option references are included in the
mixed-version manual. No package patch or custom unit is needed.
