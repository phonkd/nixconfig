# 201 activation: stop transient DNS/tailnet races from aborting deploys

**Repo(s):** nixconfig   **Status:** done

## Goal

`deploy 201` aborted twice on 2026-08-14 — once on `crowdsec.service`, once on
`syncthing-init.service` — each time discarding an otherwise-good activation.
Both units recovered on their own seconds later. Make activation on 201 clean
*because the units start correctly*, without `--auto-rollback=false`.

## What actually happens (verified in 201's journal, not assumed)

**Why a transient failure is fatal to the whole deploy.**
`switch-to-configuration-ng` (`pkgs/by-name/sw/switch-to-configuration-ng`)
sets `exit_code = 4` in two places:

1. immediately, for any *start job* whose result is `failed`, `timeout` or
   `dependency`;
2. after a 90 s settle, for any unit anywhere on the system left in `failed`
   (it calls `ListUnitsByPatterns` with **no** pattern, so a unit that failed
   hours ago on a timer counts too).

deploy-rs treats exit 4 as a failed activation and rolls back. **`Restart=`
cannot help** — crowdsec already carries `Restart=always` / `RestartSec=60`
from upstream and the deploy still rolled back, because case (1) fires the
moment the start job fails, long before the restart timer.

**Root cause on 201: DNS and the tailnet are the same thing, and activation
restarts both.**

- `/etc/resolv.conf` on 201 is `nameserver 127.0.0.1` → its own dnsmasq.
- `/etc/dnsmasq-resolv.conf` (written by resolvconf from tailscaled) has
  exactly one upstream: `100.100.100.100` — Tailscale MagicDNS.
- So *every* name lookup on 201 needs dnsmasq **and** tailscaled.
- `network-online.target` on 201 pulls in only `dhcpcd.service` and
  `network-addresses-ens18.service`. It is reached while the resolver is still
  down, so `Wants=network-online.target` is a lie on this host.

**Symptom 1 — crowdsec, twice over, for two different reasons.**

- `19:04:29.487` — `crowdsec-setup` (ExecStartPre) ran `cscli hub update`
  ~100 ms *before* dnsmasq finished starting:
  `lookup cdn-hub.crowdsec.net: Temporary failure in name resolution`. The
  setup script is `set -euo pipefail`, so the whole ExecStartPre failed →
  `Control process exited, code=exited, status=1`.
  (The task brief guessed Loki here; the journal says DNS.)
- `19:05:36.172` — next attempt got past setup, then died on the *other*
  dependency: `unable to start crowdsec routines: starting acquisition error:
  loki is not ready: context deadline exceeded`. The loki datasource probes
  `<url>/ready` for `wait_for_ready` (default **10 s**) and a failure there is
  fatal. Loki is genuinely tailnet-only from 201 — `100.64.0.4:3100` works,
  `10.9.0.1:3100` does not (201's `wg0` is the *client* VPN, `10.8.0.0/24`,
  not wg-obs) — and the tailnet took ~2 min to reconverge after tailscaled
  restarted at `19:04:45`. It succeeded on the 60 s retry at `19:06:47`.

**Symptom 2 — syncthing-init is not a network problem at all.**
nixpkgs gives it `Requisite=syncthing.service` + `After=syncthing.service`.
`Requisite=` is evaluated when the start job is dispatched and does **not**
pull `syncthing.service` into the transaction, so `After=` has nothing to
order against. `switch-to-configuration` issues one `StartUnit` call per unit,
so syncthing-init gets dispatched while syncthing is still stopped (or still
blocked on `/mnt/syncthing` growing): `Syncthing service is inactive` → job
result `dependency` → exit 4. Both times today syncthing started ~1 s later
and a second syncthing-init job succeeded. Nothing was wrong.

## Blast radius — is anything else exposed?

Histogram of every `Failed to start` / `Dependency failed` in 201's whole
journal (back to 2026-05-07):

| unit | count | verdict |
|---|---|---|
| `crowdsec` | 6772 | this bug (plus a July crash-loop, since fixed) |
| `crowdsec-update-hub` | 10 | same DNS race, timer-driven — and a unit left `failed` aborts the *next* deploy via case (2) |
| `traefik` | 3 | a config error on 2026-07-05, not a race |
| `tailscaled-autoconnect` | 2 | `tailscale up` timing out, July only, not seen since |
| `syncthing-init` | 2 | this bug |
| Sonarr/Prowlarr/podman-filestash/Seerr | 15–20 each | services since migrated off 201 |

`alloy`, `garage`, `paperless`, `memos`, `vaultwarden`, `homepage-dashboard`
and `crowdsec-firewall-bouncer` have **never** failed to start: they either
only bind local sockets or retry their remote endpoints instead of exiting.
`syncthing` itself logs `lookup relays.syncthing.net: no such host` and keeps
running. So the exposed set is crowdsec, crowdsec-update-hub, syncthing-init —
all covered below.

## Approach

Considered and rejected: making `network-online.target` on 201 actually mean
"resolver up" by ordering dnsmasq/tailscaled before it. It is the most honest
model, but `traefik.service` and `authelia-main.service` also
`Wants=network-online.target`, so it would delay the reverse proxy on every
activation and risks ordering cycles on the host that fronts everything. Not
worth it for three units.

Also rejected: `Restart=on-failure` (does not address the failed *start job* —
see above) and anything that hides a failure (`-` prefixes, `SuccessExitStatus`,
disabling units).

1. **`dns-online.service`** (new, in `modules/dns.nix` next to the dnsmasq it
   describes): a `Type=oneshot`, *not* `RemainAfterExit`, that polls `getent
   hosts` until lookups actually resolve, ordered after
   `network-online.target` / `dnsmasq.service` / `tailscaled.service`. Not
   remaining-after-exit is what makes it re-gate on every activation instead
   of staying `active` from the last boot. It exits 0 on timeout so it can
   never itself become the `failed` unit that aborts a deploy — the real
   consumer still reports the real error.
2. **crowdsec + crowdsec-update-hub** order after `dns-online.service`, which
   is the actual dependency their `cscli hub update` has.
3. **crowdsec's loki acquisition** gets `no_ready_check = true` and
   `max_failure_duration = "10m"`. The datasource then skips the blocking
   `/ready` probe and lets its background query loop retry with backoff
   (`loki is not available, will retry for 10m0s` → `loki is back after …`).
   Startup no longer depends on the tailnet at all, and a genuinely dead Loki
   still fails the unit after 10 minutes.
4. **syncthing-init** swaps `Requisite=` for `Requires=`, putting
   syncthing.service in the same transaction so the existing `After=` orders
   correctly. A real syncthing failure still propagates as `dependency`.

## Risks / rollout

- `dns-online` adds a barrier before crowdsec only; in the healthy case
  `getent` answers on the first poll (~ms). Worst case it waits 150 s, bounded
  by `TimeoutStartSec=180s`, and then continues anyway.
- Deploy over the **LAN**, not the tailnet — activation restarts tailscaled:
  `deploy 201 --hostname 192.168.3.201`.
- Back out: `git revert`, redeploy. Magic rollback still covers lost
  connectivity.
