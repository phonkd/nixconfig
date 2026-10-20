# Betterbird theme on NixOS desktops

Status: in progress

The private theme input is already pinned. z14 links the CSS and preferences into
its Flatpak profile, while blac only installs Betterbird and has a different
profile directory.

1. Move the two Home Manager file links into the shared NixOS desktop module.
   Map z14 and blac to their existing Betterbird profile directories.
2. Remove the z14-only links and verify both hosts resolve the theme sources.
3. Commit on local main, activate blac, and confirm both profile files are
   managed links. A Betterbird restart loads the CSS.
