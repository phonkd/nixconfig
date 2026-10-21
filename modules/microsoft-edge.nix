{ self, inputs, ... }:
{
  # Broker-only integration: services.intune also installs the management
  # portal/agent. Reuse Microsoft's packaged 3.x units without that dependency.
  flake.nixosModules.microsoft-identity-broker =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.microsoft-identity-broker;
    in
    {
      options.services.microsoft-identity-broker = {
        enable = lib.mkEnableOption "Microsoft Identity Broker (experimental on NixOS)";
        package = lib.mkPackageOption pkgs "microsoft-identity-broker" { };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
            message = "Microsoft Identity Broker requires x86_64 Linux.";
          }
          {
            assertion = lib.versions.major (lib.getVersion cfg.package) == "3";
            message = "This integration requires the native Microsoft Identity Broker 3.x architecture.";
          }
        ];

        environment.systemPackages = [ cfg.package ];
        services.dbus.enable = true;
        services.dbus.packages = [ cfg.package ];
        # System D-Bus activates microsoft-identity-device-broker.service as
        # root; session D-Bus directly executes the user broker. No user unit,
        # dedicated service account, boot-time sign-in or enrollment command.
        systemd.packages = [ cfg.package ];
        services.gnome.gnome-keyring.enable = true;

        # Reproduce only the directory creation from the official 3.0.2 DEB's
        # postinst. Its actual key paths differ from the release-note text.
        # Key material is runtime state and must never enter the Nix store.
        systemd.tmpfiles.rules = [
          "d /etc/microsoft/identity-broker 0755 root root -"
          "d /etc/microsoft/identity-broker/private 0700 root root -"
          "d /etc/microsoft/identity-broker/certs 0700 root root -"
        ];
      };
    };

  flake.nixosModules.microsoft-edge =
    {
      config,
      lib,
      pkgs,
      noughtyLib,
      ...
    }:
    {
      imports = [ self.nixosModules.microsoft-identity-broker ];

      config = lib.mkIf (config.noughty.host.is.nixosDesktop && noughtyLib.hostHasTag "work") {
        nixpkgs.config.allowUnfreePredicate =
          pkg:
          builtins.elem (lib.getName pkg) [
            "microsoft-edge"
            "microsoft-identity-broker"
          ];

        services.microsoft-identity-broker.enable = lib.mkDefault true;
        # The root nixos-26.05 input still carries 3.0.1. The already-locked
        # unstable input has maintained 3.0.2 packaging; use its native package
        # option without an overlay, copied derivation or changing any locks.
        services.microsoft-identity-broker.package =
          let
            brokerPkgs = import inputs.nixpkgs-unstable {
              system = pkgs.stdenv.hostPlatform.system;
              config.allowUnfreePredicate = pkg: lib.getName pkg == "microsoft-identity-broker";
            };
          in
          brokerPkgs.microsoft-identity-broker;
        # Already provided by the shared desktop baseline; keep the login
        # dependency explicit for this work-desktop integration.
        services.gnome.gnome-keyring.enable = true;
        security.pam.services.greetd.enableGnomeKeyring = true;

        home-manager.users.${config.noughty.user.name}.programs.microsoft-edge = {
          enable = true;
          package = pkgs.microsoft-edge; # Stable, from the locked Nixpkgs.
          # Hyprland isn't auto-detected as a GNOME desktop. Use the existing
          # Secret Service consistently, including PWA launches, through HM's
          # native option. NIXOS_OZONE_WL comes from the desktop baseline.
          commandLineArgs = [ "--password-store=gnome-libsecret" ];
        };

        # The NixOS chromium policy module doesn't target Edge. Recommendations
        # preserve user/organization policy precedence, and never override CA.
        environment.etc."opt/edge/policies/recommended/nixconfig.json".text = builtins.toJSON {
          ClearBrowsingDataOnExit = false;
          DefaultCookiesSetting = 1;
        };
      };
    };
}
