# screenening on Hyprland desktops

Status: implemented; PR prepared for review (no deployment).

Publish the personal display TUI as phonkd/screenening with a runnable Nix
flake. Add a locked input following this configuration's nixpkgs and Monique,
and install its default package on NixOS Hyprland desktops through the
existing Hyprland module, including both z14 and blac. The command only acts
when run; it brings its own Monique runtime dependency. Keep the existing
Monique hotplug service and monitor configuration source.

The user explicitly requested a GitHub PR, overriding the usual local-main,
no-push deployment workflow for this change. Validate package inclusion on
both hosts before updating the PR. Do not deploy pending review.
