# Microsoft Edge and Linux broker SSO

**Repo:** nixconfig   **Status:** in-progress — implementation/checks complete;
local activation requires sudo authentication, then user sign-in testing

## Goal

Provide persistent Edge/Teams PWA sessions on the work-tagged NixOS desktops,
and investigate native Microsoft Identity Broker 3.x without automatic Entra
join or Intune enrollment.

## Approach

Use maintained Nixpkgs packages and existing desktop Secret Service/PAM and
Wayland integration. Keep browser persistence independent from optional broker
activation. Verify the actual 3.x package's units, D-Bus files, ELF dependencies
and key storage; do not reuse the old Java/user-systemd implementation.

## Steps

- [x] Inspect locked Nixpkgs/Home Manager options and Microsoft documentation.
- [x] Add a reusable work-desktop Edge module and optional broker integration.
- [x] Document supported versus experimental behavior, activation, PWA setup,
      diagnostics and policy limits.
- [x] Format, evaluate and build available checks; commit on main without pushing.
- [ ] Activate on the current desktop if its rebuild is available; record limits.

## Open decisions

Microsoft documents Entra join for current broker device trust. Browser cookies
can persist without device trust, but neither cookies nor a broker override
tenant session controls. Broker activation must not execute an authentication,
join, registration or enrollment flow. Prefer native upstream service wiring;
evaluate any missing integration before adding local maintenance. User chose to
enable broker services now, leaving all sign-in/join actions manual.

## Risks / rollout

Scope to work-tagged NixOS desktops (z14 and blac); no server changes. NixOS is
not Microsoft-supported. A successful build or D-Bus activation does not prove
authenticated token renewal. Use normal user login to test persistence across
browser and session restarts. Revert the module enablement to roll back software;
never delete keyrings or device keys as part of activation/rollback.

## Verification / remaining rollout

- Edge Stable 155.0.4283.45 from root Nixpkgs, broker 3.0.2 from the existing
  locked unstable input. No lock changes, copied packages, custom units or Java.
- Official DEB hash matches Nixpkgs. Inspected its real D-Bus/systemd files,
  postinst, ELF dependencies and key paths. Imported upstream unit passes
  `systemd-analyze verify`.
- NixOS and Home Manager assertions pass for z14 and blac; Intune stays off.
  A server evaluation confirms the broker remains disabled there.
- Exact configured packages build locally (remote transfer stalled). Edge
  renders headless about:blank using an empty temporary profile. Broker session
  D-Bus activation/introspection succeeds on a private bus; all native binaries
  resolve libraries through their patched loader; `dsreg --help` runs.
- New module is nixfmt-clean; both changed Nix files parse; diff checks pass.
  builder.nix already failed whole-file nixfmt before this one-line addition.
- Activation blocked by local sudo authentication (`sudo -n true`: password
  required), not by an approval rejection. Neither desktop is a deploy-rs node.
- After local rebuild, test root system-bus activation, `edge://policy`, voluntary
  sign-in, graphical broker UI and next-day renewal using
  `docs/microsoft-edge-sso.md`. No token acquisition, join or enrollment has
  been performed during implementation.

### Interactive follow-up: error 4b25j

- User activated the initial configuration; both broker interfaces work and the
  root device service runs. Edge reaches the broker's interactive method.
- The sign-in WebKit window fails before authentication with
  `g-tls-error-quark` code 0 (TLS provider unavailable). The running broker's
  GIO module path lacks glib-networking.
- Enabled the native `services.gnome.glib-networking` option. No override or
  custom wrapper. With the broker's actual GLib, TLS support changes from false
  to true; a certificate-validated connection to Microsoft's public login host
  succeeds without requesting authentication. NixOS assertions/parse/format
  checks pass, and the evaluated session environment includes the provider.
- Local sudo authentication is still required to activate this fix. Rebuild
  and reboot (or restart the full session and broker), then manually retry the
  sign-in. Authenticated renewal remains unverified.
