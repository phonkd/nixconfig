# g14 VPN — ProtonVPN for public wifi + opt-in tailnet exit node

**Repo(s):** nixconfig   **Status:** in-progress

## Goal

Two independent, **opt-in** ways to leave the local network, without changing how
any device routes by default:

1. **ProtonVPN** — for untrusted/public wifi. Official Proton GTK client on both
   NixOS desktops (g14 and blac): log in once, pick a country, connect. Nothing
   runs until you click it.
2. **Tailnet exit node via 201-mono** — route g14's traffic out of the home
   uplink (home IP, reach the home LAN) when wanted, with `tailscale set`.

Default state on every device stays exactly what it is today: no tunnel, no exit
node, traffic straight out the local uplink.

## Approach

### ProtonVPN — the official app, not a declarative tunnel

203-media runs Proton as a declarative `wg-quick` full tunnel because it is a
headless server with one fixed egress. A desktop wants the opposite: pick a
nearby country on the spot, see it in a tray icon, turn it off when you leave.
So `pkgs.proton-vpn` (4.15.3, the real ProtonVPN GTK app) goes into the shared
desktop baseline in `modules/desktop.nix`, gated on `nixosDesktop` — g14 and
blac both get it.

Two things this needs on NixOS, both verified against the live machine:

- **`networkmanager` group.** The app drives NetworkManager, and NixOS's NM
  polkit rule grants control only to members of that group
  (`subject.isInGroup("networkmanager")`); `phonkd` was in `wheel`+`dialout`
  only. Added to the existing `extraGroups` list in `desktop.nix` — it has to be
  in that one list, since NixOS resets a declarative user's groups to exactly
  what is declared.
- **A Secret Service for the login.** Already satisfied — KDE's `ksecretd`
  owns `org.freedesktop.secrets` on this machine, so `proton-keyring-linux`
  works as-is. **No gnome-keyring needed**; adding one would just mean two
  keyrings and two unlock prompts.

Nix installs the app and nothing else. Login, server choice, kill switch and
NetShield are runtime state in the app — deliberately not modelled here.

### Exit node — capability in nix, activation at runtime

- **201-mono** advertises itself (`--advertise-exit-node`,
  `useRoutingFeatures = "server"`).
- **g14** is merely *able* to use one (`useRoutingFeatures = "client"`).
  Nothing selects an exit node declaratively — that would make it survive
  reboots, which is the opposite of the ask.

The toggle is plain tailscale, no wrapper script:

```
tailscale set --exit-node=201-mono    # route everything via home
tailscale set --exit-node=            # back to normal
tailscale exit-node list              # who is offering
```

`--operator=phonkd` (set on g14) is what makes those work without `sudo`. Add
`--exit-node-allow-lan-access` if you want the local network reachable while the
exit node is up; leaving it off is the safer default on public wifi.

Both live in `modules/tailnet.nix`, the module that already owns per-host
tailscale policy (it has a `201-mono` gate for the DNS pin).

**`extraSetFlags`, not `extraUpFlags`** — this matters. The nixpkgs
`tailscaled-autoconnect` unit only runs `tailscale up ... ${extraUpFlags}` when
the backend state is `NeedsLogin|NeedsMachineAuth|Stopped`. 201 is already
`Running`, so an `extraUpFlags` entry would silently never apply. `extraSetFlags`
drives a separate `tailscaled-set` unit that runs `tailscale set` on **every**
activation — idempotent and effective on already-enrolled nodes.

`--operator=phonkd` on g14 so the toggle needs no `sudo`. Net-new privilege is
nil: phonkd is in `wheel` and could already do this via sudo.

### Three latches keep it off by default

An advertised exit node routes nothing until **all** of:

1. 201 advertises it (nix, done here),
2. headscale **approves** the `0.0.0.0/0` route,
3. a client explicitly selects it (`tailscale set --exit-node=...`).

No client ever sets `--exit-node` from nix, so (3) is never satisfied
accidentally — on g14 or anywhere else.

## Amending the "no exit nodes" rule

`plans/headscale-mesh.md` carries a **HARD RULE — no subnet routers, no exit
nodes**, to stop the tailnet hijacking work traffic (the Mac's work VPN uses
overlapping RFC1918 space).

That rule stands **for subnet routers**, which is where the danger actually is:
a subnet router advertising `10.0.0.0/8` hijacks work traffic for every client
that accepts routes, with no per-client opt-in. An exit node is different — it
advertises `0.0.0.0/0`, which a client uses *only* when explicitly told to. The
rule is narrowed, not dropped:

- **Never advertise RFC1918 subnet routes.** Unchanged, still absolute.
- **The Mac must never set an exit node.** It is the machine with the work VPN.
  Nothing here touches the Mac; `useRoutingFeatures` stays `none` there.

## Steps

- [x] `modules/tailnet.nix`: 201 → `useRoutingFeatures = "server"` +
      `extraSetFlags = [ "--advertise-exit-node" ]`; g14 → `"client"` +
      `--operator=phonkd`.
- [x] `modules/desktop.nix`: `pkgs.proton-vpn` + the `networkmanager` group, in
      the shared `nixosDesktop` baseline (g14 and blac).
- [x] `modules/homelab/apps/headscale-policy.hujson`: `autoApprovers.exitNode`
      for user `phonkd@`, so the approval survives a coordinator rebuild instead
      of living only as out-of-band DB state.
- [ ] `deploy 201` (advertise), apply the policy, approve the route.
- [ ] Rebuild g14, verify.

## Open decisions

- **Exit node only on g14.** blac gets the Proton app like g14, but not
  `useRoutingFeatures = "client"` — it is a desktop sitting on the home LAN, so
  routing it back out through 201 buys nothing. Widening it is a one-word change
  in `tailnet.nix` if that turns out to be wrong.
- **201 is DERP-relayed.** Measured during this work: `tailscale ping 100.64.0.5`
  → `via DERP(headscale) in 110ms`, "direct connection not established". So exit
  node traffic goes g14 → Hetzner relay → 201 → internet. It works, but it is
  not fast, and it is a known-open item in `headscale-mesh.md` (201's uplink
  diverts Hetzner-bound traffic into wg-obs). If speed matters more than a home
  IP, `tailscale set --exit-node=observability` uses the Hetzner box instead,
  which g14 reaches directly — but note obs currently does **not** advertise
  itself; that would be the same two-line change applied to its host name.

## Risks / rollout

- **`checkReversePath = "loose"` on g14 and 201.** Implied by
  `useRoutingFeatures`. Mild: strict rp_filter drops packets arriving on an
  interface that is not the route back; loose accepts if routable via any
  interface. Standard tailscale guidance for exit-node clients/servers.
- **IP forwarding on 201.** Already on — `networking.nat.enable = true` (for
  wg0) sets the same sysctl. The tailscale module sets it at `mkOverride 97` vs
  nat's `99`, so it resolves cleanly to `true`, no conflicting-definition error.
- **Proton app vs tailscale routing.** Verified from live `ip rule` on g14:
  tailscale owns prefs 5210–5270, an NM WireGuard default route lands in `main`
  (32766). With no exit node, table 52 holds only tailnet routes, so Proton's
  default route is reached and both coexist. With an exit node set, table 52
  gains a default route at pref 5270 and **tailscale wins** — the two are
  mutually exclusive, tailnet first. So don't run both and expect Proton: turn
  the exit node off first. `curl ifconfig.me` settles which one you are on.
- **Proton's *permanent* kill switch will cut the tailnet** (it blocks all
  non-VPN egress, and tailscale's underlay is non-VPN egress). Nix cannot fix
  this. Use the normal kill switch; if the mesh dies while Proton is up, that is
  the permanent one and it is a setting inside the app.
- **Back out:** revert the commit and rebuild. To drop the exit node without a
  rebuild: `headscale nodes approve-routes -i <201> -r ""`.
