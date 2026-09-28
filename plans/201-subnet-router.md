# 201 subnet router

**Repo(s):** nixconfig   **Status:** in-progress

## Goal

Expose the home `192.168.3.0/24` LAN to selected tailnet clients through
`201-mono`, without turning the other oldblac VMs into redundant routers.

## Approach

Have only `201-mono` advertise the subnet. Keep Headscale route approval and
client route acceptance separate, so this deployment alone cannot inject the
route into clients such as the work Mac.

## Steps

1. Add `--advertise-routes=192.168.3.0/24` to 201's Tailscale set flags.
2. Parse-check the edited Nix module.
3. Deploy `201-mono` and verify that the route is advertised but not approved.

## Risks / rollout

Advertising is inert until Headscale approves the route. Once approved, clients
that accept subnet routes may send `192.168.3.0/24` through 201, which can
conflict with local or work networks using the same prefix. Roll back by removing
the flag and deploying 201 again.
