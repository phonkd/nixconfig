# Betterbird Entra native host

**Repo:** nixconfig  **Status:** in-progress

## Goal

Resolve Linux Entra Bridge's missing-native-host error in the existing Betterbird
Flatpak on work desktops. This enables access to the existing Microsoft broker;
it does not solve the separate Bedag OWA/AD FS session persistence issue.

## Approach

Reuse codgician's maintained NUR package via a locked source input and callPackage.
Keep the native host inside Betterbird's sandbox, with existing read-only Nix
store access, a read-only native manifest directory, and permission to talk only
to com.microsoft.identity.broker1. Disable the unavailable native-messaging
portal/proxy through Betterbird's native preferences. No custom launcher,
systemd unit, broker fork, join, enrollment, or credential copying.

## Steps

- [x] Inspect upstream package and installed Betterbird native messaging code.
- [x] Build the existing package and query broker version from inside Flatpak.
- [x] Add the locked input and Home Manager/Flatpak configuration.
- [x] Check Nix syntax, package smoke test, manifest contents, and Flatpak broker access.
- [x] Commit only this change; preserve the user's existing flake.lock edit.
- [ ] Activate on z14 if sudo is available; otherwise document the activation step.

Validation: the upstream package and its offline smoke test built successfully;
the native-host protocol returned broker version 3.0.2 both on the host and
inside Flatpak with the proposed D-Bus permission. Nix parsing and diff checks
passed. Existing lock nodes are unchanged except the root's new input reference;
the user's pre-existing screenening lock update is preserved separately. Sudo requires
a password, so system activation and extension UI verification remain pending.

## Rollout and limits

The configuration follows the existing z14/blac profile mapping and is enabled
only when the broker is enabled. Install the signed Linux Entra Bridge extension
manually, rebuild locally, and fully restart Betterbird. Broker version access
does not prove successful SSO or compliance. Reverting the configuration removes
the manifest and Flatpak permission; reset the two native-messaging preferences
if returning to a portal/proxy configuration.
