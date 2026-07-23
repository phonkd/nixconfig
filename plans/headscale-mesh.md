# headscale mesh

**Repo(s):** nixconfig   **Status:** in-progress

_Decisions locked:_ embedded DERP (no tailscale.com relays); **Tailscale SSH**
(model A — identity+ACL, sshd:5432 kept as break-glass); coordinator at
`hs.phonkd.net` with built-in Let's Encrypt.

_Status (2026-07-24):_ **Phase 1 servers all done.** Coordinator live on obs
(headscale 0.28, valid LE cert, HTTPS 200). headscale user `phonkd` + a reusable
1-year pre-auth key minted and stored as sops `headscale_authkey`. Client module
`tailnet` wired into builder.nix `alwaysImport`; canonical ACL applied to the
coordinator (`headscale-policy.hujson`, `policy set`). **All 5 servers enrolled +
verified over the tailnet: 201-mono (100.64.0.5), 203-media, 204-agent,
205-builder, observability** — direct P2P Tailscale SSH by MagicDNS name works,
incl. cross-network home↔Hetzner (30ms). Remaining: the **Mac client** (Phase 1
step 5, cask + `tailscale login`, `--accept-dns=false`). Nothing retired yet —
wg-obs/sing-box/proxyCommand still live.

_201-mono notes (both faults external to this change):_
- **Mac→201 over the sing-box proxy is dead** (SSH banner timeout — only .201;
  .203/.204/.205 fine, 201's sshd healthy from the LAN). Worked around by
  deploying via `ssh -J 192.168.3.203` (see `~/deploy-201-via-jump.sh`, a
  throwaway). Now that 201 is on the tailnet, reach it at `201-mono` / 100.64.0.5
  instead — the proxy hairpin no longer matters for management.
- **201's uplink to the internet is intermittent.** Its gateway 192.168.3.1 (the
  `.3` segment; note 203 uses 192.168.1.1) periodically drops all of 201's
  TCP/UDP + DNS while still passing ICMP — every earlier deploy hit a down window
  (crowdsec-update-hub / tailscaled-autoconnect failed on DNS → rollback). The
  deploy that stuck landed during a healthy window (0/20 loss, DNS resolving).
  This is a standing 201/router problem worth fixing on its own (it breaks ACME
  renewals etc.), unrelated to headscale. `tailnet.nix` pins hs.phonkd.net→10.9.0.1
  on 201 so mesh control/DERP rides the wg tunnel it can always reach.

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
7. **DONE (2026-07-24).** `deploy.hostname` for the 4 homelab nodes now points at
   their tailnet IP (201→100.64.0.5, 203→100.64.0.3, 204→100.64.0.1,
   205→100.64.0.2), not the 192.168.3.x sing-box address. Used **IPs not MagicDNS
   names** so it stays valid whichever way the Mac DNS decision goes (below).
   Re-verified: `deploy 201/203/204/205` all activate cleanly over the tailnet —
   incl. **`deploy 201` with no jump script**, the host whose Mac→proxy hairpin is
   dead. observability stays on 10.9.0.1 (wg-obs — most reliable path to Hetzner,
   and wg-obs is the data plane until Phase 3). Build offload still goes to
   192.168.3.205 over sing-box (unchanged in step 7).
8. **TODO — needs a Mac `darwin-rebuild` (sudo, user-run) + two inputs.** Move
   `nix.buildMachines` to 205's tailnet IP (primitive verified: root→
   nixremote@100.64.0.2 works), then strip the now-redundant homelab entries from
   `proxy.ipRanges` in `modules/hosts/mac.nix` and the `10.9.0.1`/`10.0.0.2` ssh
   match blocks. Blocked on: (a) which of the *other* proxy.ipRanges addresses
   (192.168.1.46/.47/.150/.203, 192.168.3.200) are NOT on the tailnet and must
   stay in sing-box — don't strip those or the Mac loses them; (b) the Mac DNS
   decision (see open decisions) since removing routes interacts with it. Keep
   Spotify + bedag — sing-box stays, only its homelab-host-access role goes.

Phase 3 — later, optional: move metrics/log ingestion onto the tailnet and retire
wg-obs + the home-router VPN-client route. Biggest simplification, but it touches
the observability pipeline, so it's its own effort.

## Open decisions

- ~~DERP relay~~ **RESOLVED: embedded DERP** (`derp.server.enabled`, `urls = []`) —
  fully self-hosted, no tailscale.com dependency.
- ~~Tailscale SSH vs sshd~~ **RESOLVED: Tailscale SSH** (identity + ACL). sshd on
  :5432 kept as off-tailnet break-glass. deploy-rs activation stays phonkd+sudo
  initially (ACL could grant root later).
- ~~Coordinator TLS~~ **RESOLVED: headscale built-in Let's Encrypt** on `hs.phonkd.net`.
- **Mac DNS — work-traffic isolation (OPEN).** Work traffic must keep flowing
  through sing-box, never headscale. Structurally safe already: the tailnet is
  `100.64.0.0/10` (disjoint from all work/homelab RFC1918), no subnet routes and
  no exit node are used, and `override_local_dns = false`, so tailscale only ever
  handles `100.64/10` + the `ts.phonkd.net` DNS domain — sing-box stays the
  classifier for everything else. The *one* real interaction is the macOS system
  resolver. Two Mac-only options: (a) `--accept-dns=false` — tailscale touches DNS
  zero, guaranteed work-DNS isolation, but no MagicDNS on the Mac (reach hosts by
  tailnet IP); (b) keep MagicDNS and verify work split-DNS still resolves. *Rec:*
  (a) for the Mac given the hard work constraint. Servers are unaffected either way.
- **Enrollment scope.** Servers + Mac now; laptops (blac, g14) and phone later.

## Risks / rollout

- **HARD RULE — never advertise `10.0.0.0/8` (or other work ranges) over the
  tailnet.** The Mac's work VPN uses overlapping RFC1918 space; a subnet router
  advertising it would hijack work traffic. Every host stays its own client; no
  subnet routers, no exit nodes. This is what keeps work traffic on sing-box.
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
