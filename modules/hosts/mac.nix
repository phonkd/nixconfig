{
  self,
  inputs,
  pkgs,
  ...
}:
{
  imports = [
    inputs.nix-darwin.flakeModules.default
    inputs.home-manager.flakeModules.home-manager
  ];
  flake.darwinConfigurations."Eliss-MacBook-Pro" = inputs.nix-darwin.lib.darwinSystem {
    modules = [
      self.darwinModules.macm4
      self.darwinModules.dns
      self.darwinModules.shell
      inputs.home-manager.darwinModules.home-manager
      {
        imports = [
          self.module.darwin.work
        ];
      }
    ];

  };
  flake.darwinModules."macm4" =
    { pkgs, config, ... }:
    {
      home-manager.users.phonkd.imports = [
        self.homeModules.gui
        self.homeModules.work
        {
          #home.stateVersion = "26.05";
          targets.darwin = { copyApps.enable = false; linkApps.enable = true; };
        }
      ];
      nixpkgs.hostPlatform = "aarch64-darwin";
      system.stateVersion = 6;
      nix.settings.experimental-features = "nix-command flakes";
      security.pam.services.sudo_local = {
        enable = true;
        touchIdAuth = true;
      };
      system.defaults = {
        NSGlobalDomain = {
          NSWindowShouldDragOnGesture = true;
          NSAutomaticQuoteSubstitutionEnabled = false;
        };
      };
      system.primaryUser = "phonkd";

      users.users.phonkd.home = "/Users/phonkd";
      homebrew = {
        enable = true;
        enableZshIntegration = true;
      };
    };
}
