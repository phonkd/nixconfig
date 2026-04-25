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
        self.homeModules.gaming
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
        self.homeModules.desktop-environment
        inputs.nix-index-database.homeModules.default
        { programs.nix-index-database.comma.enable = true; }
      ];
    };
  flake.nixosModules.gui =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        self.nixosModules.base
      ];
      home-manager.users.phonkd.imports = [
        self.homeModules.gui-nixos
      ];
    };
}
