# Edge, Teams PWA and Microsoft Identity Broker

## What is configured

`modules/microsoft-edge.nix` is imported once through `modules/builder.nix`.
It enables Edge Stable and the native broker on **work-tagged NixOS desktops**:
currently `z14` and `blac`. Servers and macOS are unaffected.

- Edge Stable **155.0.4283.45** comes from the root locked Nixpkgs input.
  Home Manager's native `programs.microsoft-edge.commandLineArgs` selects
  `--password-store=gnome-libsecret` for browser and PWA launches. The desktop's
  existing `NIXOS_OZONE_WL=1`, Hyprland portals and PipeWire remain in use.
- Broker **3.0.2** comes from the existing locked `nixpkgs-unstable` input via
  the module's `package` option. The root stable input currently has 3.0.1.
  No overlay, local derivation, new flake input or mutable package is needed.
- GNOME Keyring provides Secret Service; greetd's existing PAM integration
  unlocks the login keyring. Its password must match the login password.
  Passwordless login does not automatically unlock a password-protected keyring.
- `services.gnome.glib-networking` exposes GIO's dynamically loaded TLS provider
  to the session. The broker's WebKitGTK needs this to load HTTPS sign-in pages;
  having all ELF libraries present is not sufficient.
- `/etc/opt/edge/policies/recommended/nixconfig.json` recommends ordinary cookie
  storage and no clearing of browsing data at exit. These are defaults, not
  mandatory policy overrides. Existing user preferences and organization policies
  can supersede them. Third-party cookie blocking is not globally disabled.
- `services.intune` remains disabled. No portal, enrollment agent, credential,
  tenant identifier, automatic sign-in or device-join command is installed by
  this module. The broker is available on demand; activation itself does not
  authenticate anyone.

## What this can and cannot solve

| Mechanism | Device trust | Expected behavior |
| --- | --- | --- |
| Browser cookies and web-app token renewal | No registration/join required | Teams, Outlook and Microsoft 365 in the same normal Edge profile can reuse the web session, subject to tenant policy. |
| Edge profile sign-in/sync | Distinct from simply signing into a website | May use native authentication; sync success alone does not establish broker/PRT health. |
| Broker SSO | Current documented device-trust flow uses Entra join | Shares protected authentication state with participating applications. Installing/running it alone does not establish an account or PRT. |
| Intune enrollment/compliance | Separate management operation | Not configured here; required if the tenant demands an Intune-compliant device. |

Microsoft supports Linux SSO on selected Ubuntu and RHEL releases, **not
NixOS**. Its current requirements include permission to join devices to Entra.
Do not interpret successful packaging as an assurance that NixOS passes device
trust or compliance checks. See [Microsoft's Linux SSO documentation](https://learn.microsoft.com/en-us/entra/identity/devices/sso-linux).

Intune installation is not a software prerequisite for running the separately
packaged broker. That does **not** prove this tenant permits broker SSO without
enrollment. Browser-only persistence is the available join-free path. Broker
3.x documentation does not establish a guaranteed join-free Edge SSO mode;
complete a broker sign-in only if you intend any device-trust operation it
requests. This configuration neither fakes a supported OS nor bypasses CA.

Silent renewal is possible while the app's and identity provider's sessions
remain usable. A broker cannot override sign-in frequency, MFA, revoked sessions,
or device-compliance requirements. Daily prompts should be correlated with the
tenant's Entra sign-in logs and applied Conditional Access session controls,
especially if cookies survive browser restarts. See [session lifetime policies](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-session-lifetime).

## Activate

### Rebuild

These desktops are local rebuild clients, not `deploy` targets. On each host:

```sh
cd ~/git/nixconfig
sudo nixos-rebuild switch --flake .#z14 --impure
# On blac instead:
sudo nixos-rebuild switch --flake .#blac --impure
```

Log out and back in with your password so the session bus activation environment,
Home Manager PATH and keyring are current. No reboot, enrollment or sign-in
script is part of the module.

To keep Edge but disable broker availability, set this in the host's NixOS
configuration and rebuild:

```nix
services.microsoft-identity-broker.enable = false;
```

Disabling software does not remove server-side Entra membership or local keys.
Do not delete keyrings or use `dsreg --cleanup` as routine troubleshooting.

## Sign in and install Teams

1. Launch **Microsoft Edge** from the desktop menu or `microsoft-edge-stable`.
   Use a dedicated, normal work profile. Avoid Guest/InPrivate, ephemeral
   profiles, and temporary `--user-data-dir` arguments for daily use.
2. In `edge://version`, verify the executable and command line include the
   configured password-store flag, and note the profile path. In
   `edge://policy`, reload policies and check `ClearBrowsingDataOnExit=false`
   and `DefaultCookiesSetting=1` at **Recommended** level, without errors.
   If a policy is ignored on the installed Linux version, use the equivalent
   browser settings; do not assume a JSON file alone proves policy application.
3. For browser-only use, open `https://teams.microsoft.com`,
   `https://outlook.office.com` and `https://www.microsoft365.com` in that
   profile, and sign in on the websites. Choose “Stay signed in” if offered
   and permitted. Edge profile sync is optional for this route.
4. For broker/profile SSO, use the profile menu's work/school sign-in. Complete
   MFA normally. Review any device join/management prompt before accepting it.
   Stop if enrollment is demanded and you do not intend to enroll; installing
   the broker does not grant an exception. No sign-in is performed by the agent.
5. On Teams, select the install icon in the address bar, or the Apps menu's
   install action. Manage the result at `edge://apps`. Install from the same
   work profile so the PWA shares its session. Allow microphone, camera and
   notifications as needed. Test screen sharing through the Hyprland portal.

The built-in PWA installation creates a desktop launcher; no Electron wrapper
or second browser profile is needed. See [Edge PWA installation](https://learn.microsoft.com/en-us/microsoft-edge/progressive-web-apps/ux).

If login loops occur, check the browser's clear-on-exit and cookie settings and
extensions first. If Teams reports blocked third-party cookies, use a site-scoped
exception for the affected Microsoft sign-in/Teams sites where company policy
permits it. Keep organization-mandated settings intact.

## Verify operation

Run these in the logged-in graphical session, **without sudo** unless shown.
The introspection commands only discover interfaces; they do not request tokens
or perform device registration.

```sh
microsoft-edge-stable --version
systemctl cat microsoft-identity-device-broker.service

# Secret Service availability and default collection lock state:
busctl --user list | rg 'org.freedesktop.secrets'
busctl --user get-property org.freedesktop.secrets \
  /org/freedesktop/secrets/aliases/default org.freedesktop.Secret.Collection Locked

# Session D-Bus directly activates the native user broker:
busctl --user introspect com.microsoft.identity.broker1 \
  /com/microsoft/identity/broker1

# System D-Bus delegates activation to the packaged root service:
busctl --system introspect com.microsoft.identity.devicebroker1 \
  /com/microsoft/identity/devicebroker1
systemctl status microsoft-identity-device-broker.service --no-pager

# Check directory permissions only; never print private key contents:
sudo stat -c '%a %U:%G %n' /etc/microsoft/identity-broker/{private,certs}

# Read-only account/device/PRT diagnostics; do not publish unredacted output:
dsreg --status
journalctl -b -u microsoft-identity-device-broker.service --no-pager
journalctl -b _EXE="$(command -v microsoft-identity-broker)" --no-pager
```

The key directories should be `700 root:root`, and an unlocked keyring reports
`b false`. On a new installation, “not registered” / no PRT is expected.
The device service may be inactive until requested: there is no boot-time login
and no user `microsoft-identity-broker.service` in 3.x. For user broker logs, also
check `journalctl --user -b`;
logging destinations vary with D-Bus activation. Review logs locally before
sharing, since identifiers and authentication details may be present.

After a voluntary sign-in, `dsreg --status` can show account/PRT state. Record
refresh timestamps locally, reopen Teams/Outlook, then check again after normal
use. Fully quit Edge and its PWAs, reopen them, and repeat after logout/login
and the following day. Persistent web login alone proves browser persistence,
not broker use. Interface activation proves IPC, not an authenticated Edge
exchange; correlate broker activity during sign-in and PRT state to assess that.
Do not call internal token-acquisition D-Bus methods by hand.

## Packaging findings (2026-10-21)

The maintained [Nixpkgs 3.0.2 derivation](https://github.com/NixOS/nixpkgs/blob/55bfb4d7437bd4e09ab7cba58a43bd68eb310044/pkgs/by-name/mi/microsoft-identity-broker/package.nix)
unpacks Microsoft's Noble AMD64 DEB, fixes the ELF interpreter/RPATH with
`autoPatchelfHook`, and substitutes store paths into its systemd ExecStart and
session D-Bus Exec. Its dependencies include GTK3, WebKitGTK 4.1, libsoup 3,
libsecret, D-Bus, OpenSSL 3, curl, p11-kit, libuuid, X11 and C++ runtime libraries.
These are native dependencies; neither Java nor a container/FHS environment is
required. A separate RPM derivation would duplicate this maintained integration.

Static inspection of the [official 3.0.2 DEB](https://packages.microsoft.com/ubuntu/24.04/prod/pool/main/m/microsoft-identity-broker/microsoft-identity-broker_3.0.2-noble_amd64.deb)
established the following:

- Session bus: `com.microsoft.identity.broker1`, directly executed user binary.
- System bus: `com.microsoft.identity.devicebroker1`, activated through
  `SystemdService=microsoft-identity-device-broker.service`. Its `Exec=/bin/false`
  fallback is unused with NixOS's systemd D-Bus activation. The unit runs as
  root, and the D-Bus policy permits only root to own the name. No legacy
  `microsoft-identity-broker` service account is necessary.
- The DEB postinst and native binaries use
  `/etc/microsoft/identity-broker/private/` and `certs/`. Nix does not run DEB
  maintainer scripts; tmpfiles recreates the directories declaratively.
- User tokens use libsecret/Secret Service. Protect the login keyring and the
  persistent Edge profile; never put either in declarative store-backed files.
- GTK/WebKitGTK supplies interactive UI. Native Wayland sign-in still requires
  the graphical session environment to reach the activated process. Existing
  Home Manager Hyprland systemd integration supplies the session environment;
  a plain SSH session is not an equivalent test.

Microsoft's [3.x release notes](https://learn.microsoft.com/en-us/entra/identity/devices/whats-new-linux)
describe the C++ rewrite, direct user-broker D-Bus invocation and the move to
Entra join. They spell the service/key location differently in places from the
inspected artifact; this module follows the actual DEB, not those stale paths.
Neither successful linking nor service startup proves the proprietary
authentication path accepts NixOS; authenticated renewal remains a manual test.

## Validation record

### First interactive test: fixed missing TLS provider

The initial deployment successfully activated both broker components. Edge
called `getAccounts`, `acquireTokenSilently` and `acquireTokenInteractively`, and
the broker created its GTK/WebKit window. The interactive request then failed
with `4b25j`: its log reported `g-tls-error-quark`, code `0`, which means
[no TLS provider is available](https://docs.gtk.org/gio/error.TlsError.html).
The live broker's `GIO_EXTRA_MODULES` contained gvfs and dconf, but no
glib-networking TLS backend. This is a local runtime dependency failure, not
evidence that the tenant rejected authentication.

The module now enables the existing NixOS `services.gnome.glib-networking`
option. Testing the broker's actual GLib with the host's provider changes
`g_tls_backend_supports_tls` from false to true. A certificate-validated TLS
connection to `login.microsoftonline.com:443` also succeeds with that provider;
no credentials or authentication requests were sent by that test. Configuration
evaluation confirms the provider is included in the session environment.

After rebuilding this fix, restart the graphical session and its broker before
retrying. Rebooting is the simplest way to ensure no old broker or D-Bus
activation environment survives. The change neither disables certificate
validation nor modifies keyrings/device state.

### Initial implementation checks

Passed on z14:

- Parsing both changed Nix files; formatting the new module; diff whitespace
  checks. `builder.nix` has a pre-existing whole-file formatting discrepancy;
  only the module import line was changed.
- Evaluation of both desktops' Edge/broker configuration and NixOS/Home Manager
  assertions (no failures); Intune disabled; broker disabled on `201-mono`.
- Builds of the exact configured Edge and broker packages. The remote builder
  stalled during transfer; the same derivations built locally successfully.
- Edge `--version` and headless `about:blank` rendering in a disposable profile.
- Native broker session D-Bus activation and interface introspection on a
  private bus; `dsreg --help`; verification of the upstream systemd unit.
- All three broker executables resolve their libraries with their own patched
  ELF interpreter. The host's older `ldd` gives misleading glibc-version errors
  for this unstable package; using the executable's interpreter avoids that.

Reproduce the package builds without switching the system:

```sh
nix build --impure --no-link \
  .#nixosConfigurations.z14.config.services.microsoft-identity-broker.package \
  .#nixosConfigurations.z14.config.home-manager.users.phonkd.programs.microsoft-edge.finalPackage
```

**Confirmed after deployment:** system-bus startup, Edge-to-broker requests and
creation of the interactive GTK/WebKit window. **Still unverified:** effective
Edge policies, successful authentication after the TLS fix, tenant acceptance,
or token renewal across days. `sudo -n true` still reports that a password is
required, so activation of the fix must be run locally. The agent has not
performed a Microsoft sign-in, device join or enrollment. See
`plans/microsoft-edge-sso.md` for rollout status.
