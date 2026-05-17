{
  self,
  inputs,
  ...
}:
{
  flake.homeModules.gui =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        self.homeModules.base
        self.homeModules.terminal
        self.homeModules.desktop
        self.homeModules.proxy
      ];
    };
  flake.homeModules.gui-nixos =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        self.homeModules.desktop-nixos-specific
        self.homeModules.gui
        self.homeModules.gaming
        self.homeModules.desktop-environment
        inputs.nix-index-database.homeModules.default
        { programs.nix-index-database.comma.enable = true; }
      ];
    };
  # NixOS-side GUI: gated on host.is.nixosDesktop (desktop set AND linux).
  # No `imports` needed -- system-minimal lives in alwaysImport directly.
  # (Function modules can't be deduplicated by Nix, so multiple import
  # paths to system-minimal would produce duplicate option definitions.)
  flake.nixosModules.gui =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    lib.mkIf config.noughty.host.is.nixosDesktop {
      home-manager.users.phonkd.imports = [
        self.homeModules.gui-nixos
      ];
    };

  # Darwin-side GUI: gated on host.is.darwinDesktop. Wires Home Manager
  # with the cross-platform `gui` HM module (not gui-nixos, which carries
  # Hyprland + Linux-only bits).
  flake.darwinModules.gui-darwin =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    lib.mkIf config.noughty.host.is.darwinDesktop {
      home-manager.users.${config.noughty.user.name}.imports = [
        self.homeModules.gui
      ];
    };
}
