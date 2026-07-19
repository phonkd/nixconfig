# headscale mesh

**Repo(s):** nixconfig   **Status:** draft

## Goal

Replace the current hub-and-spoke connectivity (home-router VPN client → observability
as the only reachable tunnel endpoint, plus sing-box SOCKS + per-host ssh
`proxyCommand`/port/key blocks) with a **self-hosted WireGuard mesh**: Headscale as
the coordinator on observability, official Tailscale clients on every host and the
Mac. Outcome: any enrolled device reaches any other by a stable name
(`ssh 201-mono`, `deploy ext-mail`) regardless of physical network — home LAN,
Hetzner public, Hetzner private, or the Mac roaming — with no per-host routing to
hand-maintain. This is what kills the O(hosts²) config growth; ext-mail
reachability is just the first symptom.

## Approach

Coordinator + clients, rolled out in phases so nothing that works today breaks
while it's built. The existing wg-obs / sing-box / proxyCommand layer stays live
through Phase 1–2 and is only retired once the mesh is proven.

- **Coordinator:** `services.headscale` on observability (already the public
  Hetzner box). Public HTTPS endpoint at a new DNS name (e.g. `hs.phonkd.net` → obs
  public IP), TLS via headscale's built-in Let's Encrypt. New module
  `modules/homelab/apps/headscale.nix`, gated on the `observability-server` tag.
  Standalone public service — **not** in the 201 traefik/phonkds registry (that's
  the home reverse proxy; obs terminates its own TLS).
- **Clients (NixOS):** one small alwaysImport module (`modules/tailnet.nix`)
  enabling `services.tailscale` on every server (gate on `is.server`), with
  `authKeyFile` (sops pre-auth key) + `--login-server https://hs.phonkd.net` +
  `--ssh`. Boots and self-registers headless.
- **Client (Mac):** Tailscale via homebrew cask (already using homebrew), one-time
  `tailscale login --login-server https://hs.phonkd.net --ssh`.
- **SSH over the tailnet = Tailscale SSH.** Auth by tailnet identity + headscale
  ACL, not sshd. This is the piece that retires the whole `:5432` / `id_rsa` /
  `known_hosts` / `proxyCommand` class of problem we've been fighting — over the
  tailnet there is no port or key to get wrong.

## Steps

Phase 1 — stand it up (additive, nothing retired):
1. Pick + create DNS `hs.phonkd.net` A record → observability public IP (external,
   user action). Decide DERP (see open decisions).
2. `modules/homelab/apps/headscale.nix`: `services.headscale` (server_url,
   `dns.base_domain`, letsencrypt hostname), open TCP 443 + 80 on obs firewall.
   Verify option names against the real headscale module before writing.
3. sops: create a reusable headscale pre-auth key, store as a secret; wire
   `sops.secrets` on each server.
4. `modules/tailnet.nix`: `services.tailscale` for `is.server` hosts with
   `authKeyFile` + `extraUpFlags = [ "--login-server" … "--ssh" ]`. Add to
   `builder.nix` alwaysImport.
5. `deploy observability` (via the **existing** path) to bring up headscale, then
   `headscale users create` + mint the pre-auth key; deploy the rest so they
   enroll. Mac: install cask, `tailscale login … --ssh`.
6. Headscale ACL: allow `phonkd` (and `root` for deploy activation) to SSH all
   nodes. Verify `ssh 201-mono`, `ssh ext-mail`, etc. over the tailnet.

Phase 2 — cut over + delete (once Phase 1 verified):
7. Point `deploy.hostname` in `lib/registry.nix` at tailnet MagicDNS names.
   Re-verify `deploy <host>` for each node.
8. Remove the per-host ssh match blocks (`10.9.0.1`, `10.0.0.2`) and the
   `proxy.nix`-generated homelab `proxyCommand` entries; drop the homelab
   `ip_cidr` ranges from sing-box (keep Spotify + the bedag work VPN — sing-box is
   NOT deleted, only its homelab-access role).

Phase 3 — later, optional: move metrics/log ingestion onto the tailnet and retire
wg-obs + the home-router VPN-client route. Biggest simplification, but it touches
the observability pipeline, so it's its own effort.

## Open decisions

- **DERP relay.** Default = Tailscale's public DERP servers (relay only, encrypted,
  no traffic/control visibility to them) — easiest, but a partial external
  dependency, which slightly undercuts "self-hosted". Alternative = headscale
  **embedded DERP** (fully self-hosted, a bit more config + a UDP port). *Rec:*
  start on Tailscale DERP, switch to embedded in a follow-up if the SaaS-adjacency
  bothers you. **Flagging because you chose Headscale specifically to avoid SaaS.**
- **Tailscale SSH vs keep sshd.** *Rec:* Tailscale SSH (retires port/key/known_hosts
  entirely). Alternative: keep sshd on :5432 and just use tailnet IPs/names — simpler
  mental model, but keeps the exact complexity we're trying to shed. Note deploy-rs
  activation still needs a privileged user; ACL can grant `root` directly or keep
  phonkd+sudo.
- **Coordinator TLS.** *Rec:* headscale built-in Let's Encrypt on `hs.phonkd.net`.
  Alternative: a tiny nginx/caddy in front. Built-in is fewer moving parts.
- **Enrollment scope.** Servers + Mac now; laptops (blac, g14) and phone later.

## Risks / rollout

- **New public surface on observability:** headscale is internet-facing (443/80).
  It's the coordinator, so it must be — mitigate by keeping it patched; it's a
  small, well-scoped Go service. Today obs only exposes the wg UDP port.
- **Coordinator is not a hard SPOF:** the data plane is P2P/DERP and keeps working
  if headscale is down; only *new* enrollments / key rotations need it live. So an
  obs reboot doesn't sever existing tailnet SSH.
- **No chicken-and-egg:** observability is first deployed via the existing
  wg/proxy path; the mesh only has to exist after that.
- **Rollout:** every step lands via `deploy <host>` (Phase 1 offloads to 205 or
  `--remote-build`). Back out = revert the module commits and `deploy` again; the
  untouched wg-obs/sing-box/proxyCommand layer still works throughout Phase 1–2.
- **Verify option names** against the real `services.headscale` / `services.tailscale`
  module source before writing (repo rule — no option names from memory).
