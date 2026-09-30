# z14 to builder peer relay

**Repo(s):** nixconfig   **Status:** in-progress

## Goal

Keep z14's build traffic to 205-builder direct when possible, use a home-LAN
peer when direct UDP fails, and retain the embedded DERP relay as the fallback.

## Approach

Use Tailscale Peer Relay with 204-agent (192.168.3.204) as the first candidate.
It is on the same LAN as 205-builder (192.168.3.205) and carries no public
reverse-proxy workload. Grant relay capability to z14 and 205-builder only.
Headscale 0.28 does not support relay grants, so run the existing pinned
unstable Headscale 0.29.3 package on observability. The stable nixpkgs package
is left in place for all other hosts.

Tailscale prefers direct connections, then an available peer relay, then DERP.
It does not promise to select a relay by the sum of its ping times to both
endpoints. The first rollout has one candidate and therefore does not claim
automatic nearest-host selection.

## Steps

- [x] Pin observability's Headscale package to the existing 0.29.3 input.
- [x] Enable a peer relay UDP port on 204-agent and grant z14 and builder access.
- [x] Validate the Headscale policy with 0.29.3 and parse the changed Nix files.
- [ ] After review, back up Headscale's database, deploy observability then 204,
      apply the policy, and check `tailscale ping` from z14 to 205-builder.

## Risks / rollout

204's relay UDP port must be reachable from z14's network. If NAT traversal
cannot establish that path, forward UDP/40000 from the home router to
192.168.3.204. The NixOS firewall rule alone cannot create a router forward.
If the relay is unavailable, traffic continues through the embedded DERP.
Headscale's 0.28-to-0.29 database migration blocks downgrades without restoring
a pre-upgrade database backup. Apply the policy only after upgrading Headscale.
