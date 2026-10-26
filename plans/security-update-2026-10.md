# October 2026 security update

**Repo(s):** nixconfig   **Status:** in-progress

## Goal

Prepare one pull request addressing the current-config findings in `plans/cve-audit-2026-10-26.md`. The user explicitly requested subagents and a PR and retains responsibility for deployment; this supersedes the usual local-main/no-push/deploy workflow for this effort.

## Approach

Refresh security-relevant inputs, verify selected package versions and upstream backports against the findings, and use native module options for hardening and package selection. Keep version migrations explicit. Avoid custom package overrides, new systemd units, or glue code. Keep the existing audit as dated evidence and record remediation results here.

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

The refreshed NixOS CA module explicitly filters compromised emSign/Comodo roots, even though stable's base `cacert` package still says 3.126. Paperless's native module sets `REQUESTS_CA_BUNDLE` to that filtered system bundle. This does not prove that every application with a bundled/private trust store is fixed.

The Immich calendar-heatmap finding previously had unclear fixed-version metadata. Its [3.3.5 controller source](https://github.com/immich-app/immich/blob/v3.3.5/server/src/controllers/user-admin.controller.ts#L104-L105) now explicitly requires administrator access. The NixOS module selects machine learning from the server package's passthru, keeping their versions matched.

## Outstanding packaging decisions

The latest stable and unstable channel sources still carry curl 8.22.0 and Pillow 12.3.0 without the reviewed patches. Native oCIS packages remain 5.0.9. Stable MCP remains 1.26.0, while unstable has a new major API. The pinned claude-codex source retains vulnerable Rustls/private CA dependencies even in upstream's latest application tag.

The repository requires explicit approval before package overrides; a scoped exception for these fixes was requested. Until approved and implemented, these remain unresolved findings. Native package updates above can be reviewed independently. AFFiNE 0.27.4 is already latest stable, and no supported Manticore compatibility upgrade was established; their explicit digests remain unchanged rather than claiming an unverified security update.

Prepared exceptions, **not implemented**:

- curl **8.23.0**, official `https://curl.se/download/curl-8.23.0.tar.xz`, verified hash `sha256-ja3X0lNqMU+YKtBaZRtxP0Jr99Aswsds/7l5byIY5sU=`. The single official CVE patch does not apply cleanly to the pinned source, so use the complete fixed release rather than a locally rewritten backport. Both full and minimal curl/library consumers need coverage.
- Pillow **13.0.0**, official `python-pillow/Pillow` tag `13.0.0`, verified unpacked hash `sha256-7FHwvgfT40qiHmvcJFZN/FlOECE0YiqOLBEYCMugk+4=`. The targeted upstream fixes do not apply as a complete clean patch set to 12.3.0. Paperless/OCRmyPDF source checks found no explicitly removed API usage, but image-mode/plugin compatibility and builds remain unverified. This must cover Python dependencies, not merely add a newer top-level executable.
- oCIS **8.2.2**, official Linux-amd64 binary hash `sha256-M+o+jqRNi+ErcZMWP88RDK3O+YsgJSgZ+YNhRr4dSAQ=`. Native package remains unsupported 5.0.9; [upstream removal PR](https://github.com/NixOS/nixpkgs/pull/566479) and closed upgrade PR 409138 confirm the packaging gap. A final binary bump alone cannot safely perform the staged migration below.
- slop-trove: local dependency replacement with MCP **1.30.0**, preserving major-1 API rather than switching to unstable's major 2. Source checks confirm the used FastMCP/tool/run APIs remain compatible and finite body/session limits are enabled. The native service has a package option; the application's existing derivation accepts `python3Packages`.
- claude-codex: keep application **0.3.1**, update only Cargo dependencies to Rustls **0.23.46**, rustls-webpki **0.103.16**, webpki-roots **1.0.11**. Native Cargo resolution and locked offline metadata checks succeeded in a temporary source copy with exactly those three version/checksum changes. `cargoPatches` alone is insufficient with the existing `cargoLock` import; the approved implementation must keep the source lock and dependency vendoring consistent.
- **Jellyfin:** unstable offers 12.2 with matching web/FFmpeg dependencies, and its API-key database columns still match nixflix. However, nixflix's `ExecStartPost` waits at most 240 iterations and the unit times out after 300 seconds; upstream warns that first 12.x migration may take longer and must not be interrupted. Raising only the unit timeout does not fix the helper. Keep the backported 10.11.11 package until supervised offline migration or a verified readiness fix is prepared; the remaining HLS boundary finding is not cleared. [Upgrade guidance](https://jellyfin.org/docs/general/administration/upgrade/)

Additional residuals: SABnzbd's two XSS advisories name 5.2.0Beta1 as fixed; this PR selects stable 5.1.3. Codex's updated vendor lock has webpki-roots 1.0.10 plus rustls-webpki intermediate countermeasures, but lacks the subsequent 1.0.11 root-removal rollup. Neither application is described as universally CVE-free.

## User-run migrations and verification

- **Tailscale:** deploy affected machines over their documented LAN/public management path. Activation restarts tailscaled; using its own tunnel can interrupt deploy-rs. Validate mesh connectivity and Headscale registration after each host.
- **Immich:** stop new writes and take consistent backups of the PostgreSQL database and `/mnt/solo-sata/immich`. Retain the old system generation. Allow schema migrations to finish, then check login, originals/thumbnails, upload, search/face recognition and shared/locked access. Rollback requires restoring the old database and files with the old application. [Upgrading policy](https://docs.immich.app/install/upgrading/)
- **oCIS:** do not jump directly from 5.0.9 to 8.2.2. Upstream requires each stable minor boundary: 5.0→7.0→7.1→7.2→7.3→8.0→8.1→8.2. Back up all configuration, users/IDM, metadata, shares and blobs, preserving ownership and metadata. At 5→7, review native `ocis init --diff` with the existing config/data paths; first-boot init is not a migration. 7.3→8 changes existing Open Cloud Mesh invitations/shares. Restore complete old state plus binary for rollback. No oCIS activation or persisted-state changes occur in this PR preparation. [Upgrade guide](https://doc.owncloud.com/ocis/8.2/admin/migration/upgrading-ocis.html), [5→7](https://doc.owncloud.com/ocis/8.2/admin/migration/upgrading_5.0.x_7.0.0.html), [7.3→8](https://doc.owncloud.com/ocis/8.2/admin/migration/upgrading_7.3.0_8.0.0.html)
- **Media apps:** back up their app databases/config before activation; verify SABnzbd API consumers, Seerr login/request routing and notifications. SABnzbd 5.1.3 does not claim the two XSS fixes currently published against 5.2.0Beta1.
- **Traefik:** verify Authelia login, canonical identity headers and API Authorization handling. The setting deletes dot/underscore aliases and preserves canonical dash-named headers; it does not remove the need for backend authorization.

## Validation boundary

Changed native option names were checked against the pinned NixOS/nixflix modules; Traefik's option was checked against upstream 3.7.13 source. Source reviews verify the versions, backports and entrypoint wiring. Changed Nix files must pass `nix-instantiate --parse`, the lock must parse and preserve unrelated root inputs, and the diff must pass whitespace checks. No host evaluation, build, activation or runtime regression test has been performed. The PR must not describe these checks as deployment proof.

PR verification: GitHub reports the draft open and mergeable; its head matches the pushed branch. All five changed Nix files parse, the lock parses, and whitespace checks pass. GitGuardian's remote check passed; it is not a build or runtime test. An independent subagent review found no source-level blockers in the native changes and verified option propagation into service commands. It confirmed that **Immich ML still imports unstable's Pillow 12.3.0**: a future stable-only Python override would not fix that separate package set. Remaining override approval keeps the overall remediation effort in progress.
