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

Deploy after committing. Use the LAN SSH path through 203 if activation may
restart Tailscale, even when its package version is unchanged:

```sh
deploy 201 --hostname 192.168.3.201 --ssh-opts "-o ConnectTimeout=10 -o BatchMode=yes -o ProxyCommand='ssh -o ConnectTimeout=8 -o BatchMode=yes 203-media nc %h %p'"
```

Check existing Traefik service health
as well as the new endpoint. Disable the new service and registry entry and
redeploy to roll back. OAuth sign-in requires the account owner's browser approval;
never store OAuth tokens in the repository or Nix store.

The first deploy stopped before activation because stable's NixOS manual redirect
table lacks the newer module's anchors. Set the native
`documentation.nixos.checkRedirects = false` option and register the module with
`documentation.nixos.extraModules` so its option references are included in the
mixed-version manual. No package patch or custom unit is needed.

The first activation restarted Tailscale and interrupted deploy's SSH session,
leaving services stopped despite deploy reporting rollback. Completed the current
generation's activation over the LAN path with `switch-to-configuration switch`,
restored DNS and all enabled services, then retried certificate/catalog downloads.
ChatGPT device enrollment succeeded with the user's browser approval.

## Client setup and operations

- Base URL: `https://models.home.phonkd.net/v1` (tailnet access required).
- API key: the sops entry `cliproxyapi-api-key`. Retrieve from this checkout with
  `sops decrypt --extract '["cliproxyapi-api-key"]' modules/homelab/global-secrets/secret.yaml`.
- Management UI: `https://models.home.phonkd.net/management.html`; its separate
  key is the sops entry `cliproxyapi-management-key`.
- Discover available model IDs with authenticated `GET /v1/models`.
- Enroll or renew the account on the host with
  `sudo -H -u cliproxyapi cliproxyapi -config /var/lib/cliproxyapi/config.yaml -codex-device-login -no-browser`
  from a directory readable by the service user, such as `/var/lib`.
  Complete the device approval in the account owner's browser. The service
  watches its OAuth directory and picks up the credential without a restart.
- Configuration is declarative: management UI config edits are overwritten on
  restart. Provider OAuth tokens remain in `/var/lib/cliproxyapi`.
