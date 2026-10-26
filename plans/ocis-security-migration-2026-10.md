# oCIS sharing/traversal remediation

**Repo(s):** nixconfig   **Status:** in-progress — containment prepared/approved; rollout pending, migration draft

## Goal and boundaries

Remove the two confirmed oCIS 5.0.9 vulnerabilities without risking users, shares
or stored files. This is the oCIS workstream of [security PR #63](https://github.com/phonkd/nixconfig/pull/63),
not evidence that remediation has shipped. User owns rollout. No deployment,
activation, persisted-state migration, secret reads or full host evaluations/builds
are authorized. Ask before custom glue, units or package overrides. Public access
must not change without explicit agreement.

## Verified evidence — 2026-10-26

- PR #63 is open/draft at `ae6c65a5a35e526143bd8ad639fee2ec21fcf524`.
  The shared checkout was clean at `68a30d4`, with one unrelated shell commit
  ahead of the PR. Work is isolated on `review/ocis-security-2026-10` in
  `/tmp/opencode/nixconfig-ocis-security`, based on the PR head. Do not merge or
  push this branch without coordinating integration; do not include that shell change.
- [GHSA-48c2-qw7m-wg3g / CVE-2026-23989](https://github.com/owncloud/security-advisories/security/advisories/GHSA-48c2-qw7m-wg3g):
  all versions **<7.3.2** affected; **7.3.2** patched. External attackers with a
  public link can retrieve files outside the intended share and, under some
  circumstances, create arbitrary empty files. Vendor severity High, CVSS 8.2;
  no account required, but access to a public link is required.
- [GHSA-p325-hhcp-j884 / CVE-2025-55302](https://github.com/owncloud/security-advisories/security/advisories/GHSA-p325-hhcp-j884):
  all versions **<7.2.1** affected; **7.2.1** patched. Authenticated users can
  traverse to unintended resources. Vendor severity Moderate, CVSS 5.3. Do not
  describe this advisory as unauthenticated RCE or proven arbitrary OS-file read.
- Both locked [stable](https://github.com/NixOS/nixpkgs/blob/1f607aa79b6356ed45d3cd3c8079c196e79efa2c/pkgs/by-name/oc/ocis_5-bin/package.nix)
  and [unstable](https://github.com/NixOS/nixpkgs/blob/3ec636362e1816bc2f0888fa0fa2c69f1bc9e504/pkgs/by-name/oc/ocis_5-bin/package.nix)
  package **5.0.9**, with no advisory patches. A switch to this unstable input
  does not fix either finding. [Sequential packaging PR #409138](https://github.com/NixOS/nixpkgs/pull/409138)
  is closed/unmerged; [removal PR #566479](https://github.com/NixOS/nixpkgs/pull/566479)
  is open/unmerged and records that upstream no longer supports 5.
- [8.2.2](https://github.com/owncloud/ocis/releases/tag/v8.2.2), published October 21,
  is the current upstream stable release returned by GitHub. Being above both
  advisory thresholds is not proof that every dependency is fixed.

### Configured exposure, not a live inventory

At the PR base, `modules/homelab/apps/ocis.nix` exposes `ocis.w.phonkd.net` publicly
through 201's Traefik, with `auth = false; ipfilter = false;`. oCIS still has its own
authentication. The service runs on 203, listens on `0.0.0.0:9200`, uses
`/mnt/solo-sata/ocis`, and has no explicit package selection.

The pinned [NixOS module](https://github.com/NixOS/nixpkgs/blob/1f607aa79b6356ed45d3cd3c8079c196e79efa2c/nixos/modules/services/web-apps/ocis.nix)
defaults to `ocis_5-bin`, sets `OCIS_BASE_DATA_PATH` to `stateDir`, and
`OCIS_CONFIG_DIR` to `${stateDir}/config` unless `configDir` is set.
The existing local `preStart` only initializes a missing `config/ocis.yaml`;
it does **not** migrate existing configuration. The media firewall admits all
ports from 201 (`modules/arr-slime.nix`), so the backend firewall does not protect
against requests forwarded by the public router. Traefik's header-alias mitigation
does not repair oCIS authorization. Live version, active links, external storage
overrides, federation and backup availability remain unverified.

## Temporary access options — IP filter approved, rollout pending

The user approved preparing the existing LAN/Headscale IP filter after the impact
was explained. This branch now sets only the oCIS route's `ipfilter = true`, with
a comment linking this plan. No deployment or live access change has occurred.
Hostname, oCIS URL, outer auth setting and shared middleware ranges are unchanged.
Other options below remain alternatives, not authorization to implement them.

| Option | Native change / owner action | Effect and limits |
|---|---|---|
| **Recommended: trusted-network-only** | Set only `phonkds.modules.ocis.traefik.ipfilter = true` in `modules/homelab/apps/ocis.nix`; user rolls out 201 | Existing middleware permits LAN ranges `192.168.{1,2,3}.0/24`, `10.8.0.0/16` and Headscale `100.64.0.0/10`. This is **not tailnet-only** and not a patch. Outside recipients and off-mesh sync clients lose access; allowed clients/users retain vulnerability exposure. |
| Withdraw the route | Set the oCIS registry entry's `traefik.enable = false`; user rolls out 201 | Removes this public router and its generated backend entry. All access through this hostname stops, including trusted clients. Direct backend/internal access is separate; confirm no alternate router/forwarding exists. |
| Revoke public links | Owners remove existing links through the native app; confirm old links fail and prevent/review new creation | Addresses the public-link prerequisite only if revocation is complete and new links are controlled. Disrupts recipients, does not fix authenticated traversal, and is weaker operational containment than restricting the whole route. |
| Retain public access | No configuration change | Explicitly accept both residual findings until a fixed, tested migration lands. Share passwords/expiry or rate limiting are not authorization fixes. |

For trusted-network access, keep the existing hostname and `services.ocis.url`
unchanged; route that hostname to 201's tailnet address using an agreed client DNS
mapping. The existing `.home.phonkd.net` split-DNS rule does not automatically
cover this `.w.phonkd.net` hostname. Check TLS/SNI and the source address actually
seen by Traefik. Do not relabel the oCIS URL/issuer as a quick workaround. User
must verify an outside client is denied and a permitted LAN/tailnet client can
log in, sync and download before relying on containment. Preserve an independent
management path; do not combine this with a Headscale/Tailscale upgrade.

Adding Authelia (`auth = true`) is not the preferred option: interactive redirects
can break WebDAV, desktop/mobile clients and anonymous links, and authorized users
still reach vulnerable oCIS. Do not invent a path-prefix blocklist for the sharing
issue. Do not assume newer sharing flags exist in 5.0.9: the 8.2 changelog introduces
`OCIS_ENABLE_PUBLIC_SHARING` to reject **new** public links; that is not evidence
that it invalidates old links or is a 5.0.9 kill switch.

## Supported sequence and packaging gate

Upstream's [upgrade policy](https://doc.owncloud.com/ocis/8.2/admin/migration/upgrading-ocis.html)
requires **all stable major/minor upgrade steps in order**, backup first, and
forward-only operation. Do not jump from 5 to 8 or run only a final binary bump.
The documented sequence through 8.1 is:

`5.0.9 → 7.0.x → 7.1.x → 7.2.x → 7.3.x (at least 7.3.2) → 8.0.x → 8.1.x`

6.x is not an extra stable migration boundary. Select and pin actual artifacts
and checksums/digests for **each** hop before scheduling rollout; prefer the newest
appropriate patch in each line after reviewing its notes. The GitHub stable
release listing includes 7.0.1, 7.1.4, 7.2.0, 7.3.2, 8.0.9 and 8.1.0. It did not
list a 7.2.1 release: the advisory's threshold is not proof that an artifact exists.
Any vulnerable transit release must stay isolated from public/untrusted clients.

**Final-hop evidence gap:** the 8.2 admin migration index and its source directory
currently stop at 8.0→8.1; a dedicated 8.1→8.2 guide was not found. Target 8.2.2,
but obtain upstream guidance/confirmation for that hop and review
[8.2 changes](https://github.com/owncloud/ocis/blob/v8.2.0/CHANGELOG.md) before calling
the complete procedure supported. Review IDP/login changes, OIDC group-sync
defaults if external provisioning is used, and 8.2.1/8.2.2 release notes too.

**Packaging is a blocker, not an implemented solution.** Prefer upstream native
sequential packages selected through `services.ocis.package`. Reviving upstream
packaging needs all transit versions, not just 8.2.2. If unavailable, user must
choose between waiting with containment, an upstream-image deployment using
native `virtualisation.oci-containers` (separate storage/UID/network review), or
explicitly approving temporary local packages/overrides. A container conversion
is not a drop-in package change. No such code, image pins, custom units or
migration wrappers are included here; no publication of upstream PRs is authorized.

## Backup and restore gate — user-run, before any hop

1. Agree downtime, recovery point and storage capacity; pause sync clients and
   block ingress/writes, then gracefully stop the **entire** oCIS stack. Read-only
   UI/maintenance mode is not a substitute for stopping all services for backup.
2. Verify `/mnt/solo-sata` is the intended mounted disk and the existing config
   is present. It is configured as ext4 with `nofail`; do not let the first-boot
   initializer create an empty replacement instance on an absent mount. Do not
   assume a VM-root snapshot includes this separate virtio data disk.
3. Take a consistent backup of **all** `/mnt/solo-sata/ocis`, including config,
   IDM users/groups, IDP keys, system/share metadata, NATS persistence, user spaces,
   blobs/revisions, indexes and custom assets. Preserve numeric ownership, modes,
   symlinks, ACLs and xattrs. ext4 has no native snapshots: use a verified
   underlying-storage snapshot covering all disks while stopped, or a complete
   offline copy. Keep an independent copy off this disk.
4. User privately inventories path overrides in persisted config/environment;
   include any external LDAP/IDP, NATS, metadata paths and S3 blobs in the **same
   recovery point**. Securely retain the original environment/secrets through the
   user's existing backup/secret process; do not print them or commit them.
5. Retain the matching Nix generation/package closure, source revision and
   runtime settings; prevent garbage collection of rollback binaries. Record
   backup identity/time and verify a restore in an isolated clone. Login, users,
   representative file hashes and share permissions must survive restoration.
   Do not expose the clone publicly or let it send mail/federation notifications
   or share live external storage/identity-write endpoints with production.

[Backup requirements](https://doc.owncloud.com/ocis/8.2/admin/maintenance/b-r/backup.html),
[data layout](https://doc.owncloud.com/ocis/8.2/admin/maintenance/b-r/backup_considerations.html),
[restore requirements](https://doc.owncloud.com/ocis/8.2/admin/maintenance/b-r/restore.html).

## Rehearsal, then supervised rollout — user-run

For **each** boundary: stop → consistent checkpoint → select verified target →
review configuration/env changes → apply required migration → start privately →
validate → stop/checkpoint before the next boundary. Rehearse the entire sequence
on a restored clone first; never run two versions against the same state. Agree
timeouts and allow migrations to finish without an automatic rollback/restart
interrupting them. Do not combine with unrelated host/application upgrades.

- [5→7](https://doc.owncloud.com/ocis/8.2/admin/migration/upgrading_5.0.x_7.0.0.html):
  review removed/deprecated env variables, removed resharing, mandatory
  `activitylog.service_account`, and `collaboration.secret` (office use also
  needs WOPI/CSP review). Run the **target binary's native** `ocis init --diff`
  as the service identity with the existing config/data paths and appropriate
  runtime environment. This command **writes** a patch and config backup and can
  prompt; it is not a read-only check and must not run during PR preparation.
  Review/apply the generated diff privately. Preserve existing identity/mount IDs
  and secrets; do not replace `ocis.yaml` with fresh initialization.
- [7.0→7.1](https://doc.owncloud.com/ocis/8.2/admin/migration/upgrading_7.0.0_7.1.0.html),
  [7.1→7.2](https://doc.owncloud.com/ocis/8.2/admin/migration/upgrading_7.1.0_7.2.0.html),
  [7.2→7.3](https://doc.owncloud.com/ocis/8.2/admin/migration/upgrading_7.2.0_7.3.0.html):
  no advertised breaking changes, but perform every step and inspect per-version
  environment/CLI changes. Do not reopen to untrusted clients at 7.2.0.
- [7.3→8](https://doc.owncloud.com/ocis/8.2/admin/migration/upgrading_7.3.0_8.0.0.html):
  existing Open Cloud Mesh invitations/shares no longer work and must be set up
  again if OCM is used. Inventory privately, coordinate recipients, and verify
  recreation; do not confuse OCM federation with ordinary local/public shares.
- [8.0→8.1](https://doc.owncloud.com/ocis/8.2/admin/migration/upgrading_8.0.0_8.1.0.html):
  no advertised breaking changes in the guide; additionally review target patch
  notes, especially search-index rebuild/re-extraction requirements and capacity.
- 8.1→8.2.2 remains gated on the guidance gap above and successful full rehearsal.

At every gate check admin/non-admin login, user/group and space identity, sample
file checksums, upload/download (including large/resumable), desktop/mobile sync,
search, revisions/trash, direct shares and public-link permissions/passwords/expiry.
On the final fixed target, use synthetic users/files on the isolated clone to
verify that link holders cannot read sibling/unshared resources or create files
outside the share, and that ordinary users cannot traverse to another user's
ungranted resources. Use upstream regression cases where available; no exploit
tests against production. Check Traefik TLS, redirects and preserved Authorization
headers. Record exact running version, migration completion and test results.

### Rollback / reopening

On any failed gate, keep ingress blocked and stop oCIS. Restore the **complete
matching** pre-hop state (config, identity, metadata, blobs and external stores)
and the matching binary/generation/environment. Never downgrade a binary against
migrated state or restore only the database/config. Retain failed state separately
for diagnosis; account for any writes since the checkpoint before restoring.
Rollback to 5.0.9 reintroduces both vulnerabilities: containment must remain in
place. Reopening public access is a separate user decision, only after the fixed
target, successful restore rehearsal and access-boundary tests are recorded.

## Progress and next decisions

- [x] Reverify advisories, pinned package/module sources and configured exposure.
- [x] Prepare containment options, phased migration, backup/rollback and test gates.
- [x] User approves temporary access policy: existing LAN/Headscale IP filter.
- [x] Prepare the route-only configuration change in the isolated worktree.
- [ ] Coordinate integration into PR #63 without unrelated session changes.
- [ ] User rolls out 201 and verifies outside denial plus permitted client access.
- [ ] Choose maintained packaging route and resolve final-hop guidance.
- [ ] Pin/verify every transit artifact; review native module compatibility.
- [ ] User completes backup/restore rehearsal and staged rollout.
- [ ] User verifies running fixed version and approves public reopening.

This workstream changes this plan and the oCIS route's IP-filter setting only.
The historical CVE audit, shared security plan and lock remain untouched to avoid
concurrent edit conflicts. Source review confirms the registry option attaches
the existing `ip-filter` middleware and preserves its ranges. The changed Nix
file passes `nix-instantiate --parse`; whitespace checks pass. No finding is marked
resolved; no host evaluation, build, activation, secret access or live security
test was performed. Containment is not effective until the user rolls it out and
verifies it; it does not fix authorization for clients still allowed through.
