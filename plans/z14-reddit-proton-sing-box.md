# Route Reddit through ProtonVPN on z14

**Repo(s):** nixconfig   **Status:** in-progress

## Goal

Send Reddit traffic from z14 through a ProtonVPN WireGuard endpoint in
sing-box. Keep the existing work SOCKS rules and direct fallback intact.

## Approach

- Use sing-box's WireGuard endpoint (the supported form in the installed 1.13.19),
  enabled on z14 only. Keep the private key in SOPS and render the endpoint config
  at runtime; never put it in the Nix store or the public repo.
- Put Reddit domain rules ahead of the private work rules in the
  `/etc/sing-box/config.json` merge order. Keep the existing homelab bypass.
- Zen's current z14 profile already uses the local sing-box listener on port
  2080. The route rules therefore cover its Reddit requests.

## Steps

1. Read the user's local ProtonVPN WireGuard `.conf`; extract endpoint, peer key,
   allowed IPs, tunnel address, and private key without printing the key. (Done.)
2. Add the key to SOPS, generate the endpoint config with a SOPS template, and
   add Reddit route rules to the z14 sing-box config.
3. Verify the browser uses the existing local listener, check Nix
   syntax and merged sing-box config, then rebuild z14 locally.
4. Test that Reddit uses the Proton egress while a regular site,
   work SSH, and homelab access retain their expected routes.

## Input

The WireGuard configuration is `/home/phonkd/Downloads/wg-CH-640.conf`.

## Risks / rollout

- A bad endpoint can break matched domains. Verify the WireGuard handshake and
  egress before relying on the route; the direct fallback for other domains
  remains available.
- z14 is not a deploy-rs node. Apply with a local `nixos-rebuild switch --flake
  ~/git/nixconfig#z14 --impure` after review of the generated config.
