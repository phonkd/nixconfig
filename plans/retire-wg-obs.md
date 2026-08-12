# Retire wg-obs — move the observability data plane onto the tailnet

**Repo(s):** nixconfig   **Status:** DONE on the nix side (2026-08-12) — wg-obs
is deleted and every sender runs over the tailnet. Only the router-side cleanup
is outstanding, and it is inert: four UniFi rules that now point at nothing.

## CORRECTION (2026-08-11) — the original premise was partly wrong

This plan first claimed 201 *could not reach* obs's public IP, and that obs's
`allowedIPs = [10/8, 172.16/12, 192.168/16]` black-holed the return path. The
evidence was a bad test: `curl https://89.167.83.90/` returns `rc=000` from
**any** host, because headscale serves a Let's Encrypt cert via autocert and the
TLS handshake fails without matching SNI. Retested with
`curl --resolve hs.phonkd.net:443:89.167.83.90`, **201 answers rc=200** — it
reached obs perfectly well the whole time.

The real cause was simpler and entirely ours: the `networking.hosts` pin in
`modules/tailnet.nix` sent 201's DERP *and* STUN to `10.9.0.1`, and since obs is
both the STUN server and the tunnel far end, obs reflected the tunnel source.
201 advertised `10.3.0.0:45281` and was pinned to DERP forever.

**Consequence: no router work is needed for 201.** Dropping the pin was enough —
verified after deploy, 201 now reports `IPv4: yes, 85.195.231.133:37255`. The
retirement is still worth doing (one less moving part, one less trust boundary),
but it is cleanup, not a prerequisite.

## Goal

Delete the home-router↔Hetzner site-to-site WireGuard tunnel (`wg-obs`,
`10.9.0.0/24`) and carry the last thing still riding it — the metrics/log data
plane — over the headscale tailnet instead. This is Phase 3 of
`plans/headscale-mesh.md`, and it also removes the *cause* of the two hosts that
can never establish direct tailnet paths.

## Why this fixes 201 and 203

Measured while investigating the "everything is relayed" report (2026-08-11):

- **201** reaches `1.1.1.1` fine (4 ms, HTTP 301) but `89.167.83.90` fails
  instantly (`rc=000`). Its internet works; obs specifically does not.
- **201's netcheck** reports `IPv4: yes, 10.3.0.0:45281` — the tunnel address —
  so it advertises an endpoint nobody can route to and is pinned to DERP.
- **203** with its WAN carve-out disabled behaves the same way (`UDP: false`,
  `IPv4: (no addr found)`), and enabling the carve-out (`203-reach-tailnet` →
  Internet 1) black-holed it off the tailnet entirely.

The mechanism is in this repo, in `observability-vpn`: the wg-obs peer carries

```nix
allowedIPs = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" ];
```

so **obs installs a route sending every home RFC1918 destination into the
tunnel**. Any home host that reaches obs with its private source address intact
gets its reply routed back down the tunnel instead of the path it came from —
asymmetric, dropped. On top of that, `modules/tailnet.nix` pins
`hs.phonkd.net → 10.9.0.1` on 201, so 201's DERP *and* STUN deliberately ride
the tunnel, guaranteeing the tunnel-reflected endpoint.

Remove wg-obs and both disappear: no 192.168/16 route on obs, no reason to pin
201's coordinator to a tunnel IP, no need for per-host WAN carve-outs at the
router. Hosts reach obs the ordinary way, get real endpoints, and can go direct.

## Approach

Two phases, split on reversibility. Phase 1 changes only *which address* things
talk to, with the tunnel still up as a fallback. Phase 2 is the teardown.

### Phase 1 — repoint the data plane at the tailnet (safe, reversible)

`10.9.0.1` → `100.64.0.4` everywhere, and expose Loki/Mimir/Grafana on
`tailscale0` **in addition to** `wg-obs`. Both paths work throughout, so each
host can be cut over and verified independently, and any host can be reverted on
its own.

| File | Change |
|---|---|
| `modules/observability.nix` | `obsHost` → `100.64.0.4` (ext-mail keeps `10.0.0.3`, Hetzner private net — unaffected); add `networking.firewall.interfaces.tailscale0.allowedTCPPorts` alongside the wg-obs one |
| `modules/hosts/204-agent.nix` | `lokiUrl` / `mimirUrl` (+ the runbook text) |
| `modules/homelab/apps/traefik/traefik.nix` | OTLP logs endpoint (2 occurrences) |
| `modules/homelab/apps/crowdsec.nix` | Loki URL |
| `modules/homelab/apps/orphans.nix` | Grafana route `ip = "10.9.0.1"` → `100.64.0.4` |

Deploy order: obs first (so it listens on tailscale0), then 205, 204, 203, 201.
Verify after each that its journal still lands in Loki and its metrics in Mimir.

### Phase 2 — tear the tunnel down (destructive, do with someone at a keyboard)

| File | Change |
|---|---|
| `modules/observability.nix` | delete `observability-vpn`; drop the wg-obs firewall block and udp/51821 |
| `modules/builder.nix` | drop `observability-vpn` from `alwaysImport` |
| `modules/tailnet.nix` | **remove the 201 `networking.hosts` pin** |
| `modules/hosts/203-media.nix` | drop the `10.9.0.0/24` postUp/preDown routes (tailscale's own rules already keep `100.64.0.0/10` off the Proton tunnel) |
| `modules/hosts/mac.nix` | `obs-rescue` via `10.9.0.1` → public IP / tailnet |
| `modules/dns.nix` | the `no-hosts` comment about the tunnel pin |
| `lib/registry.nix` | stale wg-obs comments |

Router side (UniFi, not in repo): delete the wg-obs site-to-site peer, the
`observability` PBR (dest `10.9.0.1`), the `203-observability` static route
(`10.9.0.0/24`), and `203-reach-tailnet` — all four become dead weight.

**The 201 chicken-and-egg.** 201 currently has *no* path to obs except the
tunnel, and removing the pin is what gives it one — but the pin can only be
removed by a deploy, which rides the tailnet, which rides the tunnel. Resolve it
by deploying the pin removal **while the tunnel is still up** (201 keeps its
existing tailscaled session through the cutover; the pin only affects new DNS
resolution), then tearing the tunnel down, then confirming 201 re-establishes to
`89.167.83.90` directly. If it does not, recover over LAN: 201's real sshd is on
`:5432` at `192.168.3.201`.

## Steps

- [x] Phase 1 edits; deployed obs, 201, 204, 205 (203 pending, see below)
- [x] **Verified ingest over `100.64.0.4`**: Loki `hostname` label lists all six
      senders, and Mimir `count by (hostname) (up)` returns all six. Queried
      from g14 over the tailnet.
- [x] 201 pin removed and verified: `netcheck` → `IPv4: yes,
      85.195.231.133:37255` (was `10.3.0.0:45281`); traefik/dnsmasq/alloy active.
- [x] Phase 2 edits written: `observability-vpn` deleted, dropped from
      `alwaysImport`, wg-obs firewall block gone, 203's `10.9.0.0/24`
      postUp/preDown gone, Mac `obs-rescue` tunnel route gone, comments in
      `dns.nix`/`mac.nix` corrected.
- [x] **`deploy 203-media`** — done. The feared ~3 h CUDA rebuild was not the
      issue in the end: g14 now offloads to 205-builder, so `ollama-0.32.3`
      built on `ssh://nixremote@192.168.3.205` instead of the laptop. Verified
      after: alloy + tailscaled active, endpoints `100.64.0.4:3100/:9009`, the
      `10.9.0.0/24` route gone, logs in Loki within 3 min, and metrics only
      12.6 s stale.
- [x] `deploy observability` — wg-obs interface dropped. Verified: `ip addr show
      wg-obs` → "does not exist", udp/51821 no longer listening, and
      loki/mimir/grafana/alloy all still active.
- [x] Verified after teardown: Loki's `hostname` label still lists all six
      senders in the last 5 min, and Grafana still serves through traefik
      (`https://grafana.phonkd.net` → 302 login redirect via 85.195.231.133).
- [ ] **Router (only thing left):** delete the wg-obs peer, the `observability`
      PBR (dest 10.9.0.1), the `203-observability` static route (10.9.0.0/24),
      and `203-reach-tailnet`. All four are now dead weight — nothing routes to
      10.9.0.0/24 any more — so this is tidying, not a fix.

_Gotcha seen during Phase 1:_ 205's activation **stopped alloy and did not
restart it** — the deploy exited 0 but never printed `Deployment confirmed`, and
telemetry from that host was silently dead for ~25 min until it was started by
hand. Check `systemctl is-active alloy` on each host after deploying, not just
the deploy's exit code.

## Open decisions

- **Grafana's exposure.** Today it is wg-obs-only (never public). On the tailnet
  it becomes reachable to every enrolled device, which is the same trust
  boundary the ACL already grants for everything else. Alternative is fronting
  it through traefik on 201 with authelia. *Rec:* tailnet-only for now — it is
  strictly narrower than the current "any home RFC1918 host" reach.
- **Do it at all?** Everything works today over DERP; this buys direct paths
  (~70–110 ms → LAN/WAN latency) and deletes a whole moving part. It is cleanup,
  not a fix for anything broken. Worth doing, but not urgent.

## Risks / rollout

- **203 is currently offline** (last seen 2 h) after the `203-reach-tailnet`
  experiment — that rule must be disabled and 203 back on the tailnet before any
  of this starts.
- **Losing telemetry silently** is the main Phase 1 risk: a sender that cannot
  reach `100.64.0.4` just stops shipping. Hence per-host deploy + verify rather
  than a big-bang change.
- **obs is the coordinator.** If it drops off during Phase 2, existing tailnet
  sessions survive (data plane is P2P/DERP) but new enrolments do not. Hetzner
  console is the recovery path.
- **Back out:** Phase 1 is a one-line revert per file. Phase 2 requires
  re-adding the router peer, so that is the point of no easy return.
