# proxy.nix — design notes

Current design: sing-box mixed inbound on `127.0.0.1:2080`. Apps reach it
via `http_proxy` env, macOS system proxy, or SSH `ProxyCommand`.

## Why not broad tun (`route_address = 0.0.0.0/0`)

Tried, doesn't work reliably on macOS with sing-box ≤ 1.13. Structurally:
sing-box has to be both "the kernel's default route" (catching all
traffic) and "a client of the kernel's network" (for its own `direct`
outbound dials). Those roles need a way to differentiate sing-box's own
packets from everyone else's.

- **Linux** uses `fwmark` + `ip rule`: sing-box marks its own packets,
  the kernel routes them around the tun. Works cleanly.
- **macOS** has no fwmark equivalent. `IP_BOUND_IF` (socket-level
  interface bind) doesn't reliably override the routing table when the
  default points at utun. `default_interface` injected pre-launch fixed
  it briefly but not consistently across restarts and Wi-Fi/Ethernet
  switches.

Symptoms hit in practice:
- `network is unreachable` / `no route to internet` on every direct dial
- DNS loop when `dns.final = type=local` (system DNS → sentinel → tun → sing-box → system DNS → …)
- `auto_detect_interface` latching onto utun itself after auto_route
- ICMP entirely lost (SOCKS5 can't carry it)
- Crashes leave orphan utun + dead default route

## Why not narrow tun + per-tunnel domain routing

Doesn't compose. Narrow `route_address` means the kernel only routes
specific CIDRs into the tun. Domain rules need the connection to enter
sing-box first, which needs the destination IP to be in `route_address`
— but the IP comes from a DNS lookup, which you can only know after
resolving. FakeIP solves this loop but is being removed in sing-box 1.14.

## When to revisit

- sing-box adopts macOS Network Extensions framework
  (`NEPacketTunnelProvider`). Apple's NE auto-excludes the provider app
  from its own tunnel, removing the chicken-and-egg. Unlikely soon —
  major architectural shift, requires signed system extension.
- Switching tool entirely. Surge / Tailscale / Cloudflare WARP all use
  NE and just work. Different feature sets.

Until then: stay app-layer.
