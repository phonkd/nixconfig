# Usable ChatGPT models in AFFiNE

**Repo:** nixconfig  
**Status:** done

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
- [x] Commit to main and deploy 203 over the verified LAN SSH route.
- [x] Verify model choices and an AFFiNE chat path, not only direct router inference.
- [x] Update the installed desktop client or establish the working browser path.

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

## Result

Committed the upgrade as `ab6cab8` and deployed 203 successfully. AFFiNE reports
0.27.4, its service is active, and public HTTPS returns 200. The native backend
runtime now reads the mounted configuration via
`AFFINE_BACKEND_RUNTIME_CONFIG_PATH`; its custom/private endpoint policy is active.

The upstream migration left the legacy workspace profile with an empty model
definition. Recreated profile `one` through the native BYOK profile operation,
preserving its endpoint and key, with the Responses dialect and three enabled
models: `gpt-6.1-sol`, `gpt-6-luna`, and `gpt-5.6-sol`. All three passed AFFiNE's
native chat, tool-calling, and structured-output probes. The native runtime
resolved both the default chat route and each explicit model choice. An actual
`executeCopilot` request using `gpt-6-luna` returned the requested `AFFINE_OK`.
These checks exercise AFFiNE's routing and execution, rather than only the router.
The browser model picker has not been visually inspected in an authenticated
user session.

The browser assets are upgraded with the server. The desktop package pin and
verified AppImage hash are updated in the repository, but the local desktop
installation was not rebuilt: local sudo requires an interactive password.
An older desktop app still needs upgrading; the deployed browser is the available
path at `https://affine.home.phonkd.net`.
