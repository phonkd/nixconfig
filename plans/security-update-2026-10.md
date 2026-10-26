# October 2026 security update

**Repo(s):** nixconfig   **Status:** in-progress

## Goal

Prepare one pull request addressing the current-config findings in `plans/cve-audit-2026-10-26.md`. The user explicitly requested subagents and a PR and retains responsibility for deployment; this supersedes the usual local-main/no-push/deploy workflow for this effort.

## Approach

Refresh security-relevant inputs, verify selected package versions and upstream backports against the findings, and use native module options for hardening and package selection. Keep version migrations explicit. Avoid custom package overrides, new systemd units, or glue code. Keep the existing audit as dated evidence and record remediation results here.

Follow-up: prefer unstable packages over local overrides where they actually provide the fixes, check slop-trove against unstable's MCP API, and remove the unused claude-codex router, input and Home Manager integration at the user's request.

## Steps

- [x] Create a security branch and inspect upstream PR/base state; incorporate remote main through `784bdd6`.
- [x] Refresh package/browser inputs and identify remaining unfixed packages.
- [ ] Address media/storage migrations and explicit pins using native packages.
- [x] Apply verified proxy hardening and review secondary dependencies/container pins.
- [x] Parse changed Nix, inspect option/package source compatibility, review the native-update diff, and document outstanding findings.
- [x] Commit and push `security/october-2026-cve-remediation`; open [draft PR #63](https://github.com/phonkd/nixconfig/pull/63) with validation, rollout notes, and unresolved exceptions.

## Risks / rollout

No host activation or data migration during this work. oCIS and other major application upgrades require backup and migration review; package rollback alone does not undo database/schema changes. Tailscale updates require non-tailnet management paths during rollout. Full host evaluations/builds are excluded by repository guidance; syntax/source checks are not runtime validation. Preserve explicitly paired Android inputs and avoid unrelated feature changes.

## Native changes and verified versions

Root nixpkgs advances from `a033e66` to `1f607aa` (2026-10-25); unstable advances from `55bfb4d` to `3ec6363` (2026-10-23). Version claims come from these exact locked package sources, not branch names.

| Component | Before | PR selection | Result |
|---|---|---|---|
| Nix | 2.34.8 | 2.34.9 | Includes CVE-2026-110449/110450 fixes |
| Grafana | 13.0.9 | 13.0.11 | Includes reviewed authenticated DoS/disclosure fixes |
| nginx | 1.30.5 | 1.30.6 | Includes October fixes; feature prerequisites still apply |
| Chrome (Linux) | 155.0.8059.39 | 156.0.8078.47 | Updated security release |
| Edge (Linux) | 155.0.4283.45 | 156.0.4314.42 | Updated security release |
| Zen / Firefox | 1.23.2b / 157.0.1 | 1.23.4b / 158.0.1 | Updated independent browser input |
| Tailscale | 1.98.10 | 1.104.2 from unstable | Uses Go 1.27.3 and TS-2026-013 mitigation |
| SABnzbd | 5.1.2 | 5.1.3 from unstable | Fixes critical API bypass and malicious archive RCE; beta-only XSS fixes remain separate |
| Seerr | 3.2.0 | 3.5.0 from unstable | Includes avatar traversal and credential/user-data disclosure fixes |
| Immich server + ML | 3.0.2 | 3.3.5 from unstable | Removes obsolete fixed input; includes reviewed XSS, sharing, vault and ML fixes |
| Traefik | 3.7.13, aliases kept | 3.7.13, aliases deleted | Enables native `entryPoints.websecure.http.aliasHeadersStrategy` mitigation |
| Hermes | 2026-10-15 input | `05d7b5a` | Its own uv.lock advances Pillow to 13.0.0, certifi to 2026.10.19 and MCP to 2.3.0 |
| Claude Code / Codex | 2.1.304 / 0.163.0 | 2.1.310 / 0.164.0 | Updated llm-agents input; Claude Linux sandbox fixes and Codex TLS dependency updates |
| claude-codex router | 0.3.1 | Removed | Removes the unused router, source input, package and GUI shell integration at the user's request |

The refreshed NixOS CA module explicitly filters compromised emSign/Comodo roots, even though stable's base `cacert` package still says 3.126. Paperless's native module sets `REQUESTS_CA_BUNDLE` to that filtered system bundle. This does not prove that every application with a bundled/private trust store is fixed.

The Immich calendar-heatmap finding previously had unclear fixed-version metadata. Its [3.3.5 controller source](https://github.com/immich-app/immich/blob/v3.3.5/server/src/controllers/user-admin.controller.ts#L104-L105) now explicitly requires administrator access. The NixOS module selects machine learning from the server package's passthru, keeping their versions matched.

## Remaining native-package gaps

The refreshed stable and unstable sources still carry curl 8.22.0 and Pillow 12.3.0 without the reviewed patches. Native oCIS packages remain 5.0.9. Switching those package selections to this unstable pin would not fix the findings. The unused claude-codex router has been removed instead of maintaining its vulnerable Rustls/private CA dependencies; the ordinary Claude Code and Codex tools remain configured.

The user prefers unstable over local package overrides. No overrides are included: curl, Pillow and oCIS need fixed native packages before that approach can resolve their findings. slop-trove additionally needs an application API migration before it can use unstable's MCP 2.2.0. AFFiNE 0.27.4 is already latest stable, and no supported Manticore compatibility upgrade was established; their explicit digests remain unchanged rather than claiming an unverified security update.

Fixed-release evidence and remaining work, **not implemented**:

- curl **8.23.0**, official `https://curl.se/download/curl-8.23.0.tar.xz`, verified hash `sha256-ja3X0lNqMU+YKtBaZRtxP0Jr99Aswsds/7l5byIY5sU=`. The single official CVE patch does not apply cleanly to the pinned source, so use the complete fixed release rather than a locally rewritten backport. Both full and minimal curl/library consumers need coverage.
- Pillow **13.0.0**, official `python-pillow/Pillow` tag `13.0.0`, verified unpacked hash `sha256-7FHwvgfT40qiHmvcJFZN/FlOECE0YiqOLBEYCMugk+4=`. The targeted upstream fixes do not apply as a complete clean patch set to 12.3.0. Paperless/OCRmyPDF source checks found no explicitly removed API usage, but image-mode/plugin compatibility and builds remain unverified. This must cover Python dependencies, not merely add a newer top-level executable.
- oCIS **8.2.2**, official Linux-amd64 binary hash `sha256-M+o+jqRNi+ErcZMWP88RDK3O+YsgJSgZ+YNhRr4dSAQ=`. Native package remains unsupported 5.0.9; [upstream removal PR](https://github.com/NixOS/nixpkgs/pull/566479) and closed upgrade PR 409138 confirm the packaging gap. A final binary bump alone cannot safely perform the staged migration below.
- slop-trove: keep its current stable MCP **1.26.0** selection pending an application migration. Unstable offers **2.2.0**, but its [`mcp.server.fastmcp` compatibility module](https://github.com/modelcontextprotocol/python-sdk/blob/v2.2.0/src/mcp/server/fastmcp.py) explicitly raises `ModuleNotFoundError`; slop-trove imports `FastMCP` from that path. MCP 2 uses `MCPServer` and moves host/port configuration from the constructor to `run()`. Merely changing `inputs.slop-trove.inputs.nixpkgs.follows` would break startup. After adapting the application upstream, following `nixpkgs-unstable` is the native path and avoids a local dependency override. Unstable's native `mcp_1` compatibility package is 1.29.0, still missing the reviewed 1.29.1/1.30.0 fixes. The earlier MCP 1.30.0 override proposal is not included.
- **Jellyfin:** unstable offers 12.2 with matching web/FFmpeg dependencies, and its API-key database columns still match nixflix. However, nixflix's `ExecStartPost` waits at most 240 iterations and the unit times out after 300 seconds; upstream warns that first 12.x migration may take longer and must not be interrupted. Raising only the unit timeout does not fix the helper. Keep the backported 10.11.11 package until supervised offline migration or a verified readiness fix is prepared; the remaining HLS boundary finding is not cleared. [Upgrade guidance](https://jellyfin.org/docs/general/administration/upgrade/)

Additional residuals: SABnzbd's two XSS advisories name 5.2.0Beta1 as fixed; this PR selects stable 5.1.3. Codex's updated vendor lock has webpki-roots 1.0.10 plus rustls-webpki intermediate countermeasures, but lacks the subsequent 1.0.11 root-removal rollup. Neither application is described as universally CVE-free.

## SABnzbd focused source review — 2026-10-26

**Scope / integration:** reviewed draft PR #63 at `ae6c65a5a35e526143bd8ad639fee2ec21fcf524` in an isolated worktree. The shared checkout had an unrelated local commit `68a30d4`; it was not incorporated or changed. Keep the existing native 5.1.3 selection: no additional package/configuration change is needed for these two advisories on the reviewed source. This documentation is prepared for coordinated integration, not permission to merge, push or deploy. The historical audit remains unchanged.

### Fix evidence and exposure

| Finding | Rechecked evidence | Decision |
|---|---|---|
| [GHSA-mjwj-v5mr-cmcg](https://github.com/sabnzbd/sabnzbd/security/advisories/GHSA-mjwj-v5mr-cmcg), PAR2 symlink traversal → queue-state pickle RCE | Upstream lists 5.1.2 affected, 5.1.3 patched. In 5.1.3, `points_outside()` resolves both paths with `realpath()`; PAR2 recovery calls the guarded `renamer(..., create_local_directories=True)`. `load_data()` uses an explicit-allowlist `RestrictedUnpickler`, not unrestricted `pickle.load()`. Additional move/join containment, dangling-symlink handling and TAR member filtering provide defense in depth. | Retain high remediation priority despite the internal UI: downloads from public/untrusted indexers can trigger post-processing without reaching the UI. Execution in the reported chain occurs as the SABnzbd account when planted queue state is loaded on restart/repair. The service can write its admin/download state; immutable application code and existing systemd restrictions do not eliminate that chain. |
| [GHSA-q326-jpxx-jmjc](https://github.com/sabnzbd/sabnzbd/security/advisories/GHSA-q326-jpxx-jmjc), unauthenticated API dispatch | Upstream lists 5.1.2 affected, 5.1.3 patched. `secured_expose()` exposes only the checked wrapper, deletes `__wrapped__`, and rejects extra positional path arguments. `SecureDispatcher` rejects private-attribute path segments, including punctuation aliases; `SABnzbd.py` installs it at the application root. | Fixed in the selected source. Direct exploitation requires reaching the application; the `sabnzbd.home.phonkd.net` route has `ipfilter = true`, `auth = false`. The backend firewall explicitly accepts 201, and on-host clients also reach it. These reduce exposure, not substitute for API authorization. No public exposure or successful exploitation is asserted. |
| [GHSA-c5x2-896f-g5g8](https://github.com/sabnzbd/sabnzbd/security/advisories/GHSA-c5x2-896f-g5g8), NNTP error XSS; [GHSA-rpwc-qfxm-7h2v](https://github.com/sabnzbd/sabnzbd/security/advisories/GHSA-rpwc-qfxm-7h2v), stored history XSS | Both current advisory ranges explicitly include 5.1.3; both still name **5.2.0Beta1** as patched. | Separate, lower-priority residuals, not fixed by this PR. Keep UI access restricted and avoid rendering suspicious server errors/history. Do not block the stable archive/API fixes on an unreviewed beta or claim IP filtering removes XSS risk to permitted users. |

Source: [5.1.3 release and upgrade notes](https://github.com/sabnzbd/sabnzbd/releases/tag/5.1.3), [upstream exposure/response guidance](https://sabnzbd.org/wiki/extra/5.1-vulnerabilities.html), [filesystem implementation](https://github.com/sabnzbd/sabnzbd/blob/a647f73426cb70ad60ae7964b96c2d5e939b4727/sabnzbd/filesystem.py), [interface implementation](https://github.com/sabnzbd/sabnzbd/blob/a647f73426cb70ad60ae7964b96c2d5e939b4727/sabnzbd/interface.py), [dispatcher installation](https://github.com/sabnzbd/sabnzbd/blob/a647f73426cb70ad60ae7964b96c2d5e939b4727/SABnzbd.py). Upstream regression sources cover the `pivot -> .` rename escape, restricted unpickling, and HTTP 404 for `/api/__wrapped__` and `/api/__wrapped__/x`; they were inspected, **not executed** here.

### Native package and compatibility checks

- **Exact input, not branch-name inference:** root stable `1f607aa79b6356ed45d3cd3c8079c196e79efa2c` still packages 5.1.2. Selected unstable `3ec636362e1816bc2f0888fa0fa2c69f1bc9e504` [packages 5.1.3](https://github.com/NixOS/nixpkgs/blob/3ec636362e1816bc2f0888fa0fa2c69f1bc9e504/pkgs/by-name/sa/sabnzbd/package.nix), fetching tag `5.1.3`. Source-only `nix flake prefetch` resolves it to `a647f73426cb70ad60ae7964b96c2d5e939b4727` and returns `sha256-Ya7AagLwupKmkeOWPbsQB/lWyl/7egTGbcxXqM5yY54=`, exactly the derivation's source hash. No local override, patch or alternate source is involved.
- **Option reaches the executable:** locked nixflix `b92d2663aaddefddab1f52c9d705a6e66f43980c` defines `nixflix.usenetClients.sabnzbd.package` natively and uses `getExe cfg.package` in [its service's `ExecStart`](https://github.com/kiriwalawren/nixflix/blob/b92d2663aaddefddab1f52c9d705a6e66f43980c/modules/usenetClients/sabnzbd/default.nix). The selected derivation exposes `bin/sabnzbd` / `meta.mainProgram = "sabnzbd"`; `-f`, `-s` and `-b 0` invocation is unchanged. This is nixflix's unit, not the stock NixOS SABnzbd service.
- **Runtime dependency change to check:** unstable moves the package's interpreter from stable's Python 3.13 to Python 3.14 and replaces `cheetah3` with `ct3` (same `Cheetah` import namespace; native CT3 3.4.0.post5 matches upstream requirements). Both packages pin SABCTools 9.6.3, matching 5.1.3's requirements. Extraction/repair helpers remain supplied by the package wrapper. This establishes source compatibility, not a successful build, startup or complete dependency audit.
- **State and consumers:** nixflix retains `/var/lib/sabnzbd/sabnzbd.ini` and `/mnt/solo-sata/nixflix/downloads/usenet/{incomplete,complete,watch,nzb-backup,admin,logs}`. The package option does not relocate state, change the port, categories, hostname whitelist, local ranges or API-key references. Native download-client integration passes the configured key to the *arr apps; the Homepage widget uses its existing key reference. No secret content was read. Upstream permits a direct upgrade from 3.0.0+, so 5.1.2→5.1.3 does not call for a staged version migration or routine queue repair. Restricted unpickling still warrants checking real saved queue/RSS state after restart.
- **Validation boundary:** `modules/arr-slime.nix` parses and `flake.lock` parses as JSON. Sources were fetched/read only; no host evaluation, package/VM build, upstream test run, live request, restart, activation, migration or secret read was performed. Nixpkgs' attached smoke test checks stock-service startup and SABCTools, not nixflix wiring or these security regressions; its presence is not evidence of a test pass here.

### User-owned rollout / acceptance checklist — not performed

1. **Before activation:** record the actual running version and current queue/history counts; retain the old generation. Pause new submissions/RSS/watch-folder ingestion and let active post-processing finish, then stop SABnzbd for a consistent backup of `/var/lib/sabnzbd` and the Usenet tree above, including admin/queue/RSS/history state and incomplete data, preserving ownership and permissions. Protect configuration/backups as secret-bearing. Do not change paths, trigger queue repair or rotate credentials merely to perform this point update.
2. **After the user's activation, before resuming downloads:** confirm the running process is **5.1.3**, not merely that a new package exists in the store. Check service startup, SABCTools availability, absence of template/import errors, preserved queue/history/categories, and logs for rejected/corrupt saved state. If state fails to load, stop and investigate; do not accept an unexpectedly empty queue or repair it under the vulnerable binary.
3. **Separate perimeter and application checks:** a permitted LAN/tailnet client should reach the intended UI, while an unpermitted client must still be denied by Traefik; direct backend access should remain restricted. From an allowed application path (203 loopback or 201→203), with no cookies, Basic credentials or key, a read-only `/api?mode=queue&output=json` must return **403**. With the same harmless query plus `self=x`, `/api/__wrapped__` and `/api/__wrapped__/x` must return the application's **404**, never queue data. A proxy/firewall denial alone does not prove the application fix. Do not use `mode=version` as an auth test: it is intentionally public. Do not request secret-bearing configuration endpoints or send malicious archives to production.
4. **Positive integration checks:** use existing authorized clients to test SABnzbd from Sonarr, Radarr, Lidarr and Prowlarr where configured, and check Homepage's queue/rate widget. Verify the category list in SABnzbd itself: nixflix's category helper can treat HTTP errors as success, and its public-version readiness check does not prove authenticated API access. Submit one known-benign test download through the normal client; verify PAR2 repair if exercised, deobfuscation, extraction, category destination and downstream import, including `sabnzbd:media` ownership/permissions. Check legitimate linked download roots if used; TAR links/special members are intentionally skipped by 5.1.3.
5. **Resume / rollback / incident boundary:** resume ingestion only after checks pass. If rollback is needed, stop ingestion and the service first; restore trusted consistent application state with the matching old generation where needed, keeping untrusted processing disabled because 5.1.2 reintroduces both flaws. Do not feed suspect queue pickles to an older binary or initiate queue repair as a workaround. The update does not undo prior compromise: if untrusted UI reachability or suspicious downloaded state is found, preserve evidence and investigate the service account; apply upstream's credential-rotation guidance as appropriate (SABnzbd/API, Usenet, RSS-indexer and notification credentials), coordinating all consumers. Neither exploitation nor a need to rotate all secrets has been established by this source review.

## User-run migrations and verification

- **Tailscale:** deploy affected machines over their documented LAN/public management path. Activation restarts tailscaled; using its own tunnel can interrupt deploy-rs. Validate mesh connectivity and Headscale registration after each host.
- **Immich:** stop new writes and take consistent backups of the PostgreSQL database and `/mnt/solo-sata/immich`. Retain the old system generation. Allow schema migrations to finish, then check login, originals/thumbnails, upload, search/face recognition and shared/locked access. Rollback requires restoring the old database and files with the old application. [Upgrading policy](https://docs.immich.app/install/upgrading/)
- **oCIS:** do not jump directly from 5.0.9 to 8.2.2. Upstream requires each stable minor boundary: 5.0→7.0→7.1→7.2→7.3→8.0→8.1→8.2. Back up all configuration, users/IDM, metadata, shares and blobs, preserving ownership and metadata. At 5→7, review native `ocis init --diff` with the existing config/data paths; first-boot init is not a migration. 7.3→8 changes existing Open Cloud Mesh invitations/shares. Restore complete old state plus binary for rollback. No oCIS activation or persisted-state changes occur in this PR preparation. [Upgrade guide](https://doc.owncloud.com/ocis/8.2/admin/migration/upgrading-ocis.html), [5→7](https://doc.owncloud.com/ocis/8.2/admin/migration/upgrading_5.0.x_7.0.0.html), [7.3→8](https://doc.owncloud.com/ocis/8.2/admin/migration/upgrading_7.3.0_8.0.0.html)
- **Media apps:** back up their app databases/config before activation; verify SABnzbd API consumers, Seerr login/request routing and notifications. SABnzbd 5.1.3 does not claim the two XSS fixes currently published against 5.2.0Beta1.
- **Traefik:** verify Authelia login, canonical identity headers and API Authorization handling. The setting deletes dot/underscore aliases and preserves canonical dash-named headers; it does not remove the need for backend authorization.

## Validation boundary

Changed native option names were checked against the pinned NixOS/nixflix modules; Traefik's option was checked against upstream 3.7.13 source. Source reviews verify the versions, backports and entrypoint wiring. Changed Nix files must pass `nix-instantiate --parse`, the lock must parse and preserve unrelated root inputs, and the diff must pass whitespace checks. No host evaluation, build, activation or runtime regression test has been performed. The PR must not describe these checks as deployment proof.

PR verification: GitHub reports the draft open and mergeable; its head matches the pushed branch. All remaining changed Nix files parse, the lock parses, and whitespace checks pass. GitGuardian's remote check passed; it is not a build or runtime test. An independent subagent review found no source-level blockers in the native changes and verified option propagation into service commands. It confirmed that **Immich ML still imports unstable's Pillow 12.3.0**: updating stable's Python packages alone would not fix that separate package set. The claude-codex source and lock input, package/module definition and GUI import are removed, with no dangling configuration references. Remaining native-package gaps and migrations keep the overall remediation effort in progress.

## Traefik public-edge follow-up — 2026-10-26

**Status:** source review complete; native package switch proposed, not applied. Reviewed draft PR head `ae6c65a5a35e526143bd8ad639fee2ec21fcf524`. The shared checkout was clean at `68a30d4`, one unrelated shell commit ahead; review edits are isolated on `review/security-traefik-2026-10-26`. Do not merge or push this review without coordinating integration with the other security sessions. The original CVE audit remains historical evidence.

### Separate HTTP/2 availability concern (priority)

- [GO-2026-6617 / CVE-2026-97032](https://vuln.go.dev/ID/GO-2026-6617.json) describes an HTTP/2 server HPACK-encoder race when a client changes `SETTINGS_HEADER_TABLE_SIZE` while responses are encoded. Fixed versions are Go **1.26.9 / 1.27.2** and `golang.org/x/net` **0.60.0**. This is a server-crash/availability concern, not evidence of identity spoofing or RCE.
- Exact root pin [`1f607aa`](https://github.com/NixOS/nixpkgs/blob/1f607aa79b6356ed45d3cd3c8079c196e79efa2c/pkgs/by-name/tr/traefik/package.nix) selects Traefik **3.7.13** with `buildGo126Module`. Its [Go 1.26 package](https://github.com/NixOS/nixpkgs/blob/1f607aa79b6356ed45d3cd3c8079c196e79efa2c/pkgs/development/compilers/go/1.26.nix) is **1.26.8**; inspection of every listed patch found no HTTP/2 backport. Traefik's [3.7.13 go.mod](https://github.com/traefik/traefik/blob/v3.7.13/go.mod) also selects affected `x/net` **0.58.0**.
- This is not just a Go-version-only match: [`newHTTPServer`](https://github.com/traefik/traefik/blob/v3.7.13/pkg/server/server_entrypoint_tcp.go#L642) explicitly calls `protocols.SetHTTP2(true)` and supplies those protocols to `net/http.Server`. [Default TLS ALPN](https://github.com/traefik/traefik/blob/v3.7.13/pkg/tls/tlsmanager.go#L33) includes `h2`. The configured `:443` TLS entrypoint and host firewall permit the public-edge prerequisite at source level; exact deployed-binary behavior and runtime exploitation were **not tested**.
- `aliasHeadersStrategy = "delete"`, ForwardAuth and route-level IP filtering do **not** repair the HPACK race. They operate at the HTTP-handler layer, not the HTTP/2 frame-processing layer. Internal routes sharing this listener do not isolate the public listener from this concern.

### IP and identity trust boundaries

- `ip-filter` configures only `ipAllowList.sourceRange`; it does not configure `ipStrategy` or PROXY protocol. Upstream [`IPStrategy.Get()`](https://github.com/traefik/traefik/blob/v3.7.13/pkg/config/dynamic/middlewares.go#L491) defaults to [`RemoteAddrStrategy`](https://github.com/traefik/traefik/blob/v3.7.13/pkg/ip/strategy.go), which uses `req.RemoteAddr`, not `X-Forwarded-For` or `X-Real-IP`. **No public header-spoof bypass is established.** A real upstream proxy/SNAT presenting an allowed source would change the trust boundary, but the upstream forwarding topology was not verified here.
- Entrypoint `forwardedHeaders.trustedIPs` trusts `192.168.3.0/24` and loopback, not arbitrary internet peers. [Entrypoint processing](https://github.com/traefik/traefik/blob/v3.7.13/pkg/middlewares/forwardedheaders/forwarded_header.go#L117) strips managed forwarded headers from untrusted connection addresses before ForwardAuth. Its `trustForwardHeader = true` therefore does not independently establish public spoofing. Trusting the entire LAN subnet remains a deliberate broad trust boundary, distinct from the IP allowlist.
- Preserve **`entryPoints.websecure.http.aliasHeadersStrategy = "delete"`**. [Upstream alias removal](https://github.com/traefik/traefik/blob/v3.7.13/pkg/server/server_entrypoint_tcp.go#L903) removes names containing characters outside letters/digits/dashes, including dot/underscore identity aliases, before routing. Canonical `Remote-User`, `Remote-Groups`, `Remote-Name`, `Remote-Email` and `Authorization` are not deleted by this setting.
- Both ForwardAuth middlewares list those four canonical identity headers. [Upstream ForwardAuth](https://github.com/traefik/traefik/blob/v3.7.13/pkg/middlewares/auth/forward.go#L285) stops on non-2xx auth responses; after success it deletes each listed client header and copies the corresponding auth-response value, if present. The mitigation does not itself bypass an auth denial. Routes with `auth = false` do not gain verified identity from alias deletion, and unlisted client headers are not asserted as identity by Traefik. No configured backend trusting a spoofable identity alias was established.
- Routers currently place ForwardAuth before `ip-filter` when both are enabled. This can reach Authelia before the IP rejection; it does not turn forwarded-header values into allowlist inputs or establish backend access.

### Dashboard boundary (lower priority)

`api.insecure = true` causes Traefik to [create an implicit `:8080` entrypoint](https://github.com/traefik/traefik/blob/v3.7.13/pkg/config/static/static_config.go#L306), not a loopback-only listener. However, `modules/hosts/201-mono.nix` opens TCP 80/443/22, not 8080; the pinned NixOS Traefik module adds no firewall opening. `modules/homelab/apps/orphans.nix` names loopback:8080 as an app entry but enables no Traefik route for it (registry default `traefik.enable = false`), and no `api@internal` router was found. **Public 8080 access is not established**; effective runtime firewall/NAT state was not inspected. Consider disabling the insecure API or explicitly binding its entrypoint to loopback separately if local consumers still need it; do not describe the current setting as a confirmed public dashboard leak.

### Focused next step

Use the existing native `services.traefik.package` option to select **Traefik 3.7.15 from the already locked unstable input**, keeping the alias-header setting unchanged. No input refresh, package override, custom unit or glue is necessary:

```nix
package = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.traefik;
```

The exact unstable pin [`3ec6363` package](https://github.com/NixOS/nixpkgs/blob/3ec636362e1816bc2f0888fa0fa2c69f1bc9e504/pkgs/by-name/tr/traefik/package.nix) is **3.7.15**, its [Go 1.26 compiler](https://github.com/NixOS/nixpkgs/blob/3ec636362e1816bc2f0888fa0fa2c69f1bc9e504/pkgs/development/compilers/go/1.26.nix) is **1.26.10**, and upstream [3.7.15 go.mod](https://github.com/traefik/traefik/blob/v3.7.15/go.mod) selects **x/net 0.60.0**. Both package sets wire `buildGo126Module` to `buildPackages.go_1_26` in `pkgs/top-level/all-packages.nix`. The pinned stable [NixOS module](https://github.com/NixOS/nixpkgs/blob/1f607aa79b6356ed45d3cd3c8079c196e79efa2c/nixos/modules/services/web-servers/traefik.nix#L108) exposes `package` and uses it for `ExecStart`. Upstream 3.7.15 retains the alias-deletion option. This is source evidence for a native remediation, not a built/deployed validation result.

After a separately authorized change, parse the module and check the diff only; the user owns rollout and post-rollout checks of HTTP/2 negotiation, Authelia login/denial, canonical identity headers, API Authorization and external denial of IP-filtered routes. Do not send crash payloads to the live edge. Headscale serves its own public TLS listener on observability (`modules/homelab/apps/headscale.nix`); changing Traefik on 201 does not remediate or validate Headscale.

This follow-up changed documentation only: no host evaluations/builds, live-service probes, deployment/activation, migrations or secret reads.
