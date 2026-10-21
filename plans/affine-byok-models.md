# Usable ChatGPT models in AFFiNE

**Repo:** nixconfig  
**Status:** in-progress

## Problem

AFFiNE 0.27.3 validates the saved workspace router key, but its Intelligence
picker resolves providers without workspace context and its built-in chat choices
only include Gemini/Claude. A successful router HTTP test does not establish a
working AFFiNE chat. Native provider settings alone cannot repair that picker.

## Approach

Upgrade the pinned server and matching desktop client to upstream 0.27.4, which
introduces editable BYOK models and a replacement model selection path. Keep the
existing saved key and private endpoint policy. Verify the new native runtime's
config path and ensure the saved provider has usable GPT models. Use native
configuration and supported operations; no application patch or model spoofing.

## Steps

- [x] Verify saved key, endpoint, policy, and the 0.27.3 model-picker implementation.
- [x] Pin the 0.27.4 container and desktop artifact; wire required native config.
- [ ] Commit to main and deploy 203 over the verified LAN SSH route.
- [ ] Verify model choices and an AFFiNE chat path, not only direct router inference.
- [ ] Update the installed desktop client or establish the working browser path.

## Rollout / rollback

Preserve a database backup before the upgrade because BYOK is experimental and
the upstream release warns that configuration may need updating. Keep OAuth and
API credentials out of the repository and logs. The workload is on 203-media;
201's existing router is unchanged. Revert the image/client pin to roll back;
restore the database backup only if a migration makes that necessary.

Backup created on 203 at
`/var/lib/affine/backups/before-0.27.4-20261021.dump` (root-only, custom pg_dump
format). The existing instance has one user and one enabled, validated OpenAI
workspace key pointing at the homelab router.
