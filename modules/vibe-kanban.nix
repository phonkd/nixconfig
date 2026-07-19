# vibe-kanban — BloopAI's local kanban board for orchestrating AI coding
# agents (https://github.com/BloopAI/vibe-kanban).
#
# It is distributed ONLY as an npm package (a thin npx wrapper that fetches a
# per-platform prebuilt Rust binary on first run); there is no nixpkgs package.
# The Mac has no global Node, so this wraps `npx vibe-kanban` with a
# nix-provided Node runtime — run `vibe-kanban` and it serves on 127.0.0.1.
#
# The version is pinned for reproducibility; bump VIBE_KANBAN_VERSION below (or
# export it / pass `latest`) to upgrade. Wired onto the Mac in
# modules/hosts/mac.nix.
{
  ...
}:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.vibe-kanban = pkgs.writeShellApplication {
        name = "vibe-kanban";
        runtimeInputs = [ pkgs.nodejs_22 ];
        text = ''
          exec npx --yes "vibe-kanban@''${VIBE_KANBAN_VERSION:-0.1.44}" "$@"
        '';
      };
    };
}
