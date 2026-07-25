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
8. **WRITTEN (2026-07-24), pending the Mac `darwin-rebuild` (sudo, user-run) to
   apply + verify.** In modules/hosts/mac.nix: proxy.ipRanges reduced to just
   10.9.0.0/24 (obs); nix.buildMachines.hostName → 100.64.0.2; nixremote
   matchBlock → 100.64.0.2; added name aliases 201-mono/203-media/204-agent/
   205-builder → tailnet IP with `proxyCommand none` (beats the bedag `Host *`
   socat catch-all, which sorts LAST in the generated ~/.ssh/config), a
   `Host 100.64.0.*` none block, and a `Host 192.168.1.* 192.168.3.*` block that
   ssh-jumps through 203 (`ProxyCommand ssh phonkd@100.64.0.3 nc %h %p`) for
   non-enrolled LAN boxes. SMB (8445→203) kept (routes via wg, independent of
   ipRanges). After rebuild, verify: `deploy` still works, `ssh 201-mono` +
   `ssh root@192.168.3.47` (Proxmox) resolve, work ssh unaffected. Also uncheck
   "Use Tailscale DNS" for accept-dns=false. Roll back the darwin generation if
   anything's off. Original decisions/notes below.
   Decisions made (2026-07-24): reach
   non-enrolled LAN boxes by **ssh-jump through 203**, no subnet router; Mac goes
   **accept-dns=false**. All primitives verified: deploy-over-tailnet ✓, build
   offload root→nixremote@100.64.0.2 ✓, Mac→203(tailnet)→Proxmox(192.168.3.47)
   ssh-jump authenticates ✓. 192.168.3.200 is offline (non-issue);
   192.168.1.46/.47 unneeded. The edits: `nix.buildMachines` hostName →
   100.64.0.2; strip all 192.168.x from `proxy.ipRanges` (keep 10.9.0.0/24 for obs
   until Phase 3); add tailnet name aliases (201-mono→100.64.0.5 etc.) + a
   `Host 192.168.3.*` `ProxyCommand ssh phonkd@100.64.0.3 nc %h %p` jump block;
   repoint the nixremote matchBlock to 100.64.0.2. SMB forward (8445→203) keeps
   working (routes via the wg outbound, independent of ipRanges).
   **The catch:** the catch-all `Host * → socat SOCKS 2080` that currently proxies
   all unmatched ssh comes from `~/git/bedag-setup/home-manager/ssh.nix` (the WORK
   repo, imported into HM). The new jump/alias blocks must render BEFORE it or
   homelab ssh falls through to the work catch-all and fails — and HM matchBlock
   ordering can't be checked without a full eval (workflow-forbidden) or the
   rebuild. So this step should be done INTERACTIVELY: apply, `darwin-rebuild`,
   inspect the generated ~/.ssh/config ordering + confirm work ssh still works,
   roll back the darwin generation if off. Not a fire-and-forget edit.

Phase 3 — later, optional: move metrics/log ingestion onto the tailnet and retire
wg-obs + the home-router VPN-client route. Biggest simplification, but it touches
the observability pipeline, so it's its own effort.

_Update (2026-07-25) — everything homelab off sing-box; only work + Spotify left
(user directive: "route homelab through tailnet and work through sing-box"):_

1. **obs management → tailnet.** `proxy.ipRanges` is now empty; the obs
   `10.9.0.0/24` range + the `10.9.0.1` :5432/id_rsa ssh block are gone. `deploy
   observability` targets 100.64.0.4 (registry), interactive ssh via the
   `observability`/`obs` alias. wg-obs survives only as the metrics/log **data
   plane** (senders push to obs's own 10.9.0.1) — Phase 3's job; the Mac doesn't
   touch it.
2. **homelab web → tailnet.** `.w.phonkd.net` is removed from the sing-box
   `domains` list (sing-box `domains` = Spotify only now). Instead the Mac's
   previously-dead `darwinModules.dns` is wired into builder.nix
   `alwaysImportDarwin` and repointed at **201's tailnet IP 100.64.0.5** (was
   192.168.3.201). nix-darwin's dnsmasq writes `/etc/resolver/<domain>` per
   `addresses` entry, so ONLY `*.w.phonkd.net` / `*.int.phonkd.net` /
   `grafana.phonkd.net` resolve via local dnsmasq → 100.64.0.5; work + general
   DNS keep their normal resolvers (compatible with accept-dns=false). 201 opens
   :443 on all interfaces (incl. tailscale0) and traefik binds `:443`, so
   `*.w.phonkd.net` reaches traefik over the mesh from anywhere. `no_proxy` also
   gains `.phonkd.net,100.64.0.0/10` so env-proxy CLI clients go direct.

Net: sing-box carries **only** the bedag work VPN (additionalConfigFile) +
Spotify. Everything homelab (ssh/deploy, obs, SMB, web) is on the tailnet.

**Pending the Mac `darwin-rebuild` (user-run) to apply + verify.** Check:
`deploy observability` + `ssh observability` over the tailnet; a homelab web app
in the browser (e.g. `https://dashboard.w.phonkd.net`) and `curl -I
https://immich.w.phonkd.net` resolve to 100.64.0.5 and load; work DNS/ssh + a
Spotify play still go via sing-box unchanged. Watch the browser path specifically
— if a browser is configured to use sing-box as a system proxy (rather than the
env vars), it may need a proxy bypass for `.phonkd.net`; the `/etc/resolver`
scoping covers the resolver side but not a hard system-proxy setting. Roll back
the darwin generation if anything's off.

## P2P / DERP-relay debugging (2026-07-26)

_Symptom:_ every homelab peer stayed on `DERP(headscale)` relay instead of direct
P2P (`tailscale ping` → "direct connection not established"; `205-builder` build
offload pushing ~350 MB through the relay). `tailscale netcheck` on 201/203 showed
`IPv4: 10.3.0.0:<port>` — a **private** reflexive address — while the Mac showed
its real public IP (`85.5.57.44`).

_Two root causes:_
1. **Hetzner cloud firewall blocked UDP/3478 (STUN)** — the embedded DERP's STUN
   port. Opened at the Hetzner level → obs (public IP) can reflect. NB the NixOS
   firewall already allowed it (`headscale.nix`), but the cloud firewall is a
   separate layer. **Also open UDP/41641** (Tailscale data port) there, or even
   Mac↔obs stays on DERP — 3478 is only STUN, direct data uses 41641.
2. **DNS leak poisoning STUN (the `10.3.0.0`).** 201 pins `10.9.0.1 hs.phonkd.net`
   in /etc/hosts (needed — its uplink can't reach obs's public IP, so it reaches
   the coordinator over wg-obs). But 201 also runs `homelab-dns` (dnsmasq), which
   served that /etc/hosts pin to **every** homelab client. So all VMs resolved
   `hs.phonkd.net → 10.9.0.1` and sent their STUN through the wg-obs tunnel →
   reflected as the tunnel's SNAT source `10.3.0.0` → no usable public endpoint →
   permanent relay. The Mac doesn't use 201 for DNS, so it resolved the public IP
   and STUN'd cleanly — that's the only reason the Mac differed.

_Fix (this branch):_ `modules/dns.nix` homelab-dns gains `no-hosts = true` (stop
serving 201's /etc/hosts pin to the network) + an authoritative
`address=/hs.phonkd.net/89.167.83.90` (hand clients the coordinator's real public
IP, without depending on 201's flapping uplink to forward upstream). 201 itself
still resolves the tunnel pin via nsswitch `files` (before dns), so its own
control path is unchanged. Needs `deploy 201` (deploy-rs magic-rollback covers a
bad activation). **Verify after deploy:** on 201 `tailscale status` still shows
connected; on 203 `getent hosts hs.phonkd.net` → 89.167.83.90 and `tailscale
netcheck` shows the real public IP; then `tailscale ping` Mac↔203 goes direct.

_Residual limits (inherent, not bugs):_ 201 itself stays on relay until its real
uplink is fixed (its STUN over the tunnel is always 10.3.0.0). And Mac↔hosts on
the `192.168.3.x` VLAN (204/205) may still relay even after the fix: they share
the home public IP with the Mac but sit on a different subnet, so direct needs NAT
hairpin or inter-VLAN routing of the LAN endpoints. Mac↔203 (same /24) should go
direct. The build-offload path (Mac→205) is the main casualty of that VLAN split.

_Update (2026-07-26) — CAUSE 2 found, a UniFi policy-based route (203-specific)._
Even with the DNS fix, 203 stayed relayed. `tracepath` from 203 to obs's PUBLIC
IP (89.167.83.90) goes INTO a wg tunnel at the UniFi gateway — hop `10.2.0.1`,
`pmtu 1420` (wg MTU), egressing Hetzner-Frankfurt (`159.26.104.x`, cdn77); 203's
apparent public IP is `159.26.104.84`, not the home `85.5.57.44`. Cause: a UniFi
**policy-based route** `203` = `source MAC bc:24:11:ea:b3:3d (=203 ens18) → dest
Any → gateway observability-hetzner`, i.e. ALL of 203's traffic (incl. Tailscale
STUN) is forced through the Hetzner wg tunnel. obs is both the STUN server and the
tunnel far-end, so it reflects the tunnel address (10.3.0.0) → no usable public
endpoint → permanent relay. This is INDEPENDENT of the DNS leak and dominant for
203; the DNS fix alone won't free 203. _Fix (UniFi console, not in repo):_ if 203
doesn't need datacenter egress, delete the `203` PBR (the `10.9.0.0/24 →
observability-hetzner` static route still carries metrics to obs); if it does, add
a higher-priority PBR `203 → 89.167.83.90/32 → default WAN` so only the DERP/STUN
path bypasses the tunnel. NB the DNS fix (commit on this branch) must be actually
`deploy`ed to 201 — a wholesale git revert (dc4d98b, later un-reverted) meant an
earlier 201 rebuild didn't carry it; verify `getent hosts hs.phonkd.net` → the
public IP on 201 after deploy. Also open UDP/41641 (not just 3478) at the Hetzner
cloud firewall for obs, or even Mac↔obs stays on DERP.

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
