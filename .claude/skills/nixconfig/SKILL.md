---
name: nixconfig
description: How this NixOS/nix-darwin homelab flake is wired — module auto-import + registry, host topology, the phonkds.modules app registry, traefik/dashboard/sops/observability conventions, port allocations, and the verification workflow. Read before adding a service, exposing something through traefik, touching secrets, or debugging why a module doesn't apply.
---

# Working in this nixconfig repo

## Architecture: three wiring layers

1. **File discovery**: `flake.nix` uses flake-parts + `import-tree ./modules` — every
   `.nix` file under `modules/` is auto-imported as a *flake-parts* module. Creating a
   file is enough to define things; no per-file import list exists.
2. **Module definition**: each file defines `flake.nixosModules."<name>"` (a NixOS
   module, usually a function taking `{ config, pkgs, lib, noughtyLib, ... }`).
3. **Module activation** — the step that's easy to forget: defining a nixosModule does
   NOT put it in any host. It must be listed either in
   - `modules/builder.nix` → `alwaysImport` (for cross-host modules that self-gate), or
   - a host's `extraModules` in `lib/registry.nix` (host-specific, e.g. `203-media`).

`modules/builder.nix` reads `lib/registry.nix` and emits
`flake.nixosConfigurations.<host>` / `darwinConfigurations.<host>`. Registry entries
carry `kind`, `platform`, `tags`, `extraModules`.

**Self-gating**: alwaysImport modules wrap their config in
`lib.mkIf (noughtyLib.hostHasTag "some-tag")` or `config.noughty.host.is.server` /
`config.noughty.host.name == "..."`. Import each function module via exactly ONE path
(function equality is always false → duplicate option definitions otherwise).

## Hosts and topology

| Host | Tags (relevant) | Notes |
|---|---|---|
| 201-mono | reverse-proxy, homelab-server, observability-sender | 192.168.3.201. Traefik :443 (api :8080, metrics :8083), homepage :8082, authelia :9091, vaultwarden :8000, paperless :28981, open-webui :11111, syncthing, garage, DNS |
| 203-media | media-server, gigaplayer-server, observability-sender | 192.168.1.203 (ens18, default gw) + 192.168.3.203 (ens19, policy-routed table 203). nixflix *arr stack, jellyfin :8096 (NVENC, RTX 3060 Ti passthrough), sabnzbd :8080, slskd :5030, ollama :11434, oCIS :9200, samba shares. nftables firewall: everything open to 192.168.3.201 only |
| 204-agent | observability-sender | slop-trove; reaches 203's ollama over 192.168.3.0/24 |
| observability (Hetzner) | observability-server | Loki :3100, Mimir :9009, Grafana :3000 — reachable ONLY at 10.9.0.1 over WireGuard (wg-obs, site-to-site via home router) |

## Exposing an app: the phonkds.modules registry

Option type lives in `modules/phonkds-options.nix`: per-app `ip`, `port`, `path`,
`traefik.{enable,domain,auth,ipfilter,extraMiddlewares,scheme,transport}`,
`dashboard.{enable,icon,link,widget}`. Producers write entries; the consumers
(`homelab-traefik`, `homelab-dashboard`) read them **on the reverse-proxy host**, so:

- App on 201 itself: one block gated on `homelab-server`, ip `127.0.0.1`
  (see `vaultwarden.nix`, `paperless.nix`).
- App on another host: `lib.mkMerge` of TWO blocks — routing/dashboard gated on
  `reverse-proxy` (ip = the other host's 192.168.3.x), workload gated on the host's
  tag (see `arr-slime.nix`, `apps/ocis.nix`).
- Thing not managed by nix at all (router, PVE): routing-only entry in
  `apps/orphans.nix`.

Traefik conventions: public domains `*.w.phonkd.net`, internal `*.int.w.phonkd.net`
with `ipfilter = true`. Available middlewares: `forward-auth` (authelia), `ip-filter`,
`pve-headers`, `vnc-root-rewrite`. Self-signed HTTPS backend → `scheme = "https"` +
`transport = "insecureTransport"`. Homepage live widgets need the API key in
`sops.templates."homepage.env"` as `HOMEPAGE_VAR_<APP>_KEY` (reverse-proxy block of
arr-slime.nix).

## Secrets (sops-nix)

One shared file for all servers: `modules/homelab/global-secrets/secret.yaml`
(defaultSopsFile, age-encrypted; the Mac's key at `~/.config/sops/age/keys.txt` can
edit it). Both 201 and 203 decrypt it, which is why widget keys live on 201 and
service secrets on 203 with no duplication.

Add a secret non-interactively:
```
sops set modules/homelab/global-secrets/secret.yaml '["name-of-secret"]' '"value"'
```
Then per host: `sops.secrets."name" = { };` (+ `owner` if a service user reads it),
and compose env files with `sops.templates."x.env".content` using
`config.sops.placeholder."name"`.

## Observability

Senders (tag `observability-sender`) run Alloy: journal → Loki push, embedded
`prometheus.exporter.unix` + process-exporter (:9256) → Mimir remote_write
(pipeline `prometheus.remote_write.nixvms` in `modules/observability.nix`).

- **Extra scrape jobs**: Alloy loads every `*.alloy` file in `/etc/alloy` into ONE
  shared namespace — drop `environment.etc."alloy/foo.alloy"` from any module and
  reference `prometheus.remote_write.nixvms.receiver` directly. Gate it on
  `observability-sender` so the reference can't dangle (traefik.nix does this).
- **Logs without journald**: Loki ingests OTLP natively at
  `http://10.9.0.1:3100/otlp/v1/logs` (traefik ships app+access logs this way;
  `experimental.otlpLogs = true` still required as of traefik 3.7).
- **Alert rules**: pushed by `mimir-rules-sync` via mimirtool. `rules sync` is a
  mirror op — ALWAYS scope with `--namespaces=...` or it deletes every other
  namespace in the tenant (bit us live once).

## Port allocation — check before binding

Grep first: `grep -rn "<port>" modules --include="*.nix" | grep -v worktrees`.
Collisions already hit: homepage owns **8082** on 201 (nixpkgs default — traefik
metrics had to move to 8083); node_exporter owns **9100** on every sender — oCIS's
internal web service collided and was moved to 9101 via `WEB_HTTP_ADDR`. oCIS
fullstack squats most of 9110–9282 plus 33177/45023/45363/46833/46871 on 203.
8080 is traefik's api on 201 AND sabnzbd on 203 (different hosts, fine).

## Unfree packages

No blanket `allowUnfree` in system modules — use the scoped predicate per host block:
```nix
nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "ocis_5-bin" ];
```
(pattern: `aislop.nix`, `apps/ocis.nix`).

## Workflow rules (user-established)

- **Never verify with full evals** — no `nixosConfigurations.<x>` toplevel builds or
  getFlake harnesses. `nix-instantiate --parse <file>` + grep for dangling refs is
  the ceiling. The user rebuilds on the target and pastes failures back.
- Verify NixOS option names against the real module source, not from memory. Locate
  nixpkgs: `nix eval --raw .#nixosConfigurations."203-media".pkgs.path`, then read
  `<path>/nixos/modules/...`.
- Push the branch; the **user opens/merges PRs themselves**. Don't `gh pr create`
  unprompted.
- GitHub's "Potential fix for pull request finding" autofix commits have invented
  nonexistent options before (`services.ocis.settings`) — if a merged branch breaks,
  diff against your own last commit first.
- Commits: imperative summary + a body explaining *why*, matching existing style.
