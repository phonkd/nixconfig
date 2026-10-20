# Direct login for Betterbird and Teams

**Repo(s):** nixconfig   **Status:** done

## Goal

Betterbird and Teams for Linux must reach work login endpoints externally,
even when Bedag's proxy rules would select an internal route. Other apps keep
their current proxy routing and internal ADFS access.

## Approach

Use each app's native proxy configuration: append `network.proxy.type = 0` to
Betterbird's managed profile preferences on work desktops, and set Teams'
system configuration to `proxyServer = "direct://"`. Keep the shared sing-box
rules and session proxy variables intact. Teams merges its system configuration
with existing user settings, preserving the configured user agent.

## Steps

- [x] Add the two app settings and check syntax and the diff.
- [x] Commit on local main without pushing.
- [x] Rebuild the current desktop (blac) and inspect the installed settings.

## Verification

Both changed Nix modules parse cleanly. The blac build and switch succeeded;
the installed Betterbird `user.js` sets `network.proxy.type` to `0` and
`/etc/teams-for-linux/config.json` sets `proxyServer` to `direct://`. The shared
sing-box configuration is byte-identical to the previous configuration.
Interactive login remains for the user after restarting the apps.

## Risks / rollout

Both work desktops (blac and z14) receive these settings on their next rebuild;
only blac is local to this session. Neither desktop is a deploy-rs target, so
activate blac with the native `nixos-rebuild switch` command. Apps read these
settings at startup and need restarting. Login success requires an interactive
sign-in. Revert the app settings and rebuild to restore proxy inheritance.
