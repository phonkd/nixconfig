# Retire `int.w.phonkd.net` → `home.phonkd.net`, over the tailnet

**Repo(s):** nixconfig   **Status:** in-progress

## Goal

Two linked changes:

1. **Rename** every internal (`ipfilter = true`) service from
   `*.int.w.phonkd.net` to `*.home.phonkd.net`. Public services keep
   `*.w.phonkd.net`.
2. **Make tailnet clients reach traefik over the tailnet automatically**, so
   `ipfilter = true` stops locking us out from away-from-home. Today a remote
   client resolves an internal name to `192.168.3.201` and simply cannot route
   to it — verified live on g14 during the AFFiNE work.

`home.phonkd.net` is not a fresh namespace: it is already Home Assistant's
domain (`orphans.nix`), already `ipfilter = true`. So HA keeps the apex and
every other internal service becomes a child of it. Consistent, and HA gets the
same tailnet fix for free.

## Why it's broken today

Cloudflare publishes a **public wildcard `*.int.w.phonkd.net → 192.168.3.201`**
— a private address, in public DNS. Confirmed: even
`test-nonexistent.int.w.phonkd.net` answers `192.168.3.201`. A client away from
the LAN resolves that, tries to route to RFC1918, and dies. The `ip-filter`
middleware already trusts `100.64.0.0/10`, so the *filter* was never the
problem — the **DNS answer** is.

g14 is already on MagicDNS (`nameserver 100.100.100.100`,
`search ts.phonkd.net`), so headscale can steer it with no client-side change.

## Approach

**Note `ts.phonkd.net` is unavailable** — it is headscale's MagicDNS
`base_domain`, so every node is `<host>.ts.phonkd.net`. Hence a plain
`phonkd.net` child instead.

DNS, three places, all pointing at 201's **tailnet** IP:

| where | what | who it serves |
|---|---|---|
| headscale (obs) | `dns.nameservers.split = { "home.phonkd.net" = ["100.64.0.5"]; }` | every tailnet client, automatically |
| 201 dnsmasq | `address=/home.phonkd.net/100.64.0.5` | LAN clients + the split-DNS target itself |
| Mac dnsmasq | `"home.phonkd.net" = "100.64.0.5"` | the Mac's scoped resolver |

Client → `100.64.0.5:443` → traefik sees source `100.64.0.x` → the existing
`ip-filter` allow-list already covers it. **Tailnet-only by decision**: one
answer for everybody, no split-horizon. All 11 enrolled nodes are personal
devices, and Tailscale connects peers directly over the LAN at home, so there is
no speed cost. Accepted downside: a device with tailscaled down loses internal
services even sitting on the same LAN.

No public A record is needed for `*.home.phonkd.net` — ACME DNS-01 only needs
the TXT record, which the Cloudflare API creates.

### Authelia is the non-obvious part

Two independent breakages, both mandatory:

- **`definitions.network.internal` is `192.168.{1,3}.0/24` only.** Once traffic
  arrives from `100.64.0.x`, the `bypass`-from-internal rules stop matching and
  `dashboard.w.phonkd.net` / `priv.s3.w.phonkd.net` (both `auth = true`)
  silently escalate from bypass to **two_factor**. Add `100.64.0.0/10` —
  exactly the fix the `ip-filter` block already documents for the same reason.
- **Cookies are per-domain.** The session cookie domain is `w.phonkd.net` with
  the portal at `auth.w.phonkd.net`. `home.phonkd.net` is not under it, so a
  portal on `w.phonkd.net` cannot issue a cookie for it. `easyeffects` is the
  one `auth = true` service moving, so add a second cookie domain plus a portal
  endpoint at `auth.home.phonkd.net`, and a `forward-auth-home` middleware whose
  `rd=` points there. Router middleware selection picks by domain suffix, so it
  stays automatic.

### Certs: per-service (decided)

~16 fresh DNS-01 issuances at cutover. **Traefik does not retry a failed cert
request** (see `plans/affine.md`) — so the rollout step is not "deploy", it is
"deploy, then audit the ACME store and restart traefik until every name is
present".

## Steps

- [ ] headscale: split-DNS entry → `deploy observability` (inert on its own —
      the domain has no services yet)
- [ ] 201 dnsmasq: `home.phonkd.net` → `100.64.0.5`
- [ ] Mac dnsmasq: same entry (Mac rebuild is the user's, not deployable here)
- [ ] Rename 21 refs across 8 modules (`sonarr|prowlarr|sabnzbd|seerr|radarr|
      lidarr|slskd|notes|paperless|affine|hermes-dashboard|easyeffects|
      noobservability`), incl. paperless' CSRF/CORS origins and sabnzbd's
      `host_whitelist`
- [ ] authelia: tailnet in `internal`; second cookie domain; `auth.home` router;
      access_control rules
- [ ] traefik: pick `forward-auth-home` for `home.phonkd.net` routers
- [ ] `nix-instantiate --parse` every touched file
- [ ] Land on `main` → `deploy observability`, `deploy 201`, `deploy 203`
- [ ] Audit ACME store for all ~16 names; restart traefik for stragglers
- [ ] Verify from g14 over the tailnet: DNS answer, cert, HTTP status

## Open decisions

- **Cloudflare cleanup is NOT done here.** The `*.int.w.phonkd.net →
  192.168.3.201` wildcard (and the `home.phonkd.net` apex A record, same private
  IP) should be deleted once the migration settles. That is an outward-facing
  change to live DNS, so it is left for the user to trigger. Leaving them costs
  nothing functionally — it is the status quo — but keeps a private address in
  public DNS.
- **Four `ipfilter = true` services are NOT on the new domain and stay
  unreachable from away — needs a call.** `syncthing.w.phonkd.net`,
  `snapcast.w.phonkd.net`, `api.s3.w.phonkd.net` and `oldblac.int.phonkd.net`
  are internal-by-intent but sit on the public / old-internal trees, so they
  still resolve to `192.168.3.201` (or the public IP) and still 403 remotely.
  This migration does not touch them. Three ways out, none obviously right:
  1. **Move them to `home.phonkd.net`** — most coherent (`ipfilter = true`
     ought to imply the internal domain) but changes four more URLs.
  2. **Add `w.phonkd.net` to the split-DNS map** — one line, and the Mac
     already does exactly this. But it routes *public* services over the
     tailnet for enrolled devices too, making tailscaled a hard dependency for
     reaching e.g. vaultwarden.
  3. **Special-case the four names** in both the split map and 201's dnsmasq
     (longest-match wins over the `w.phonkd.net` wildcard). Precise, but four
     special cases in two files.

  Left for the user because option 2 silently changes how public services are
  reached, which is well outside "retire int.w".
- **Old domain is not kept as an alias.** A dual-domain period would halve the
  cutover risk but doubles the certs and leaves the leaky wildcard load-bearing.
  Decided against; the tailnet DNS change lands atomically with the rename.

## Risks / rollout

- **201 is the reverse proxy and every internal route changes at once.** Magic
  rollback only catches lost connectivity, and this failure mode is
  wrong-but-reachable. Deploy order is obs → 201 → 203 so the DNS target exists
  before the names do.
- **The dnsmasq wildcard also captures the `home.phonkd.net` apex**, moving Home
  Assistant to tailnet routing. Intended (HA is already `ipfilter = true`), but
  it means HA is in the blast radius of this change.
- **Back out**: revert the commit and redeploy the same three hosts. The old
  Cloudflare wildcard is deliberately left in place, so the old names still
  resolve exactly as before during a revert.
