{
  self,
  inputs,
  ...
}:
{
  flake.homeModules.zed-editor =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      programs.zed-editor = {
        enable = true;
        package = inputs.nixpkgs-unstable.legacyPackages.${pkgs.system}.zed-editor;
        userKeymaps = [
          {
            context = "Workspace";
            bindings = {
              "cmd-1" = "workspace::ToggleLeftDock";
              "cmd-2" = "workspace::NewTerminal";
              "cmd-3" = "workspace::ToggleRightDock";
            };
          }
        ];
      };
      home.packages = [
        inputs.nixpkgs-unstable.legacyPackages.${pkgs.system}.zed-discord-presence
      ];
    };
}