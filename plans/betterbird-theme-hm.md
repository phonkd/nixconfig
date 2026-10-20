# Betterbird theme on NixOS desktops

Status: in progress

The private theme input is already pinned. z14 links the CSS and preferences into
its Flatpak profile, while blac only installs Betterbird and has a different
profile directory.

1. Move the two Home Manager file links into the shared NixOS desktop module.
   Map z14 and blac to their existing Betterbird profile directories.
2. Remove the z14-only links and verify both hosts resolve the theme sources.
3. Give Betterbird read-only Flatpak access to /nix/store: Home Manager creates
   links there, and the default Flatpak sandbox cannot follow them. Confirmed
   with an isolated Flatpak run on blac.
4. Commit on local main, activate blac, and confirm both profile files are
   readable from inside the Flatpak. A Betterbird restart loads the CSS.
