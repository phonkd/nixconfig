# screenening on Hyprland laptops

Status: implemented; PR prepared for review (no deployment).

Publish the personal display TUI as phonkd/screenening with a runnable Nix
flake. Add a locked input following this configuration's nixpkgs and Monique,
and install its default package only on NixOS Hyprland laptops through the
existing Hyprland module. Today that selects z14; blac and macOS are excluded.
Keep the existing Monique hotplug service and monitor configuration source.

The user explicitly requested a GitHub PR, overriding the usual local-main,
no-push deployment workflow for this change. Validate the package and the
laptop/non-laptop gate before opening the PR. Do not deploy pending review.
