# sing-box proxy — design notes

Two halves that share nothing but the package:

- `darwin.nix` — unprivileged launchd agent, mixed inbound on
  `127.0.0.1:2080`, app-layer only. Apps reach it via `http_proxy`, the macOS
  system proxy setting, or ssh `ProxyCommand`.
- `nixos.nix` — root system service with a tun device, capturing everything.

They were one file with platform branches until the Linux side grew a tun,
three traffic classes and a secret. The resemblance was superficial and it made
both harder to read; see the file headers.

## macOS: broad tun (`route_address = 0.0.0.0/0`) does not work

Tried, unreliable with sing-box ≤ 1.13. Structurally sing-box must be both
"the kernel's default route" and "a client of the kernel's network" for its own
`direct` dials, which needs a way to tell its own packets from everyone
else's.

- **Linux** has `fwmark` + `ip rule`: sing-box marks its own packets and the
  kernel routes them around the tun.
- **macOS** has no equivalent. `IP_BOUND_IF` does not reliably override the
  routing table when the default points at utun, and `default_interface`
  injected pre-launch fixed it only briefly — not across restarts or
  Wi-Fi/Ethernet switches.

Symptoms hit in practice: `network is unreachable` on every direct dial; a DNS
loop with `dns.final = type=local` (system DNS → sentinel → tun → sing-box →
system DNS → …); `auto_detect_interface` latching onto utun itself after
`auto_route`; ICMP lost entirely (SOCKS5 cannot carry it); orphaned utun and a
dead default route after a crash.

Narrow tun + per-tunnel domain routing does not compose either: domain rules
need the connection inside sing-box first, which needs the destination IP in
`route_address`, which you only know after resolving. FakeIP solves that loop
and is being removed in 1.14.

**Revisit when** sing-box adopts `NEPacketTunnelProvider` (Apple's Network
Extension auto-excludes the provider from its own tunnel, killing the
chicken-and-egg — unlikely soon), or when switching tool entirely. Until then
macOS stays app-layer.

## Linux: the tun does work, with four traps

All four were hit, in this order, and each is guarded in `nixos.nix`:

1. **`route.auto_detect_interface` is mandatory.** Without it `direct` dials
   follow the default route — which `auto_route` just pointed at the tun — so
   every dial re-entered the tun and looped. ~4.6 cores until stopped by hand.
   The journal signature is `inbound connection from 172.19.0.1`, the tun's own
   address. (The macOS notes above predicted this shape.)
2. **`stack = "system"` black-holes IPv4.** Packets arrive (tun0 RX climbs) and
   are dropped silently — no dial, no log. IPv6 meanwhile escapes, because the
   tun has no v6 address, so the machine looks healthy while every IPv4-only
   host is dead. Use `gvisor`. **Always test with `curl -4` against an
   IPv4-only host**; a dual-stack host proves nothing.
3. **MagicDNS sits inside the tailnet CIDR.** `100.100.100.100` is in
   `100.64.0.0/10`, so a "tailnet → endpoint" rule swallows all system DNS and
   deadlocks an endpoint that needs DNS to bootstrap. Carve it out first.
4. **sing-box merges `--config` files by PATH, not command-line order.**
   Measured: the same file at `/home/…/.claude/x.json` lands at `match[0]`, at
   `/home/…/zz-x.json` at `match[18]`. From `/nix/store` the generated config
   always sorted after the work config, so its `sniff` rule ran after every
   domain rule had already been skipped. Hence installing it to
   `/etc/sing-box/config.json` — `/etc` < `/home` < `/nix` < `/run`. sing-box
   sorts by the path it is given, so a symlink into the store is fine.

Debugging any of this starts with `logLevel = "debug"`: the
`router: match[N] => …` lines name the winning rule and are the only external
view of how the merged rule set was assembled.
