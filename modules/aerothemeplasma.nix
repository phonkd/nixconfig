# AeroThemePlasma -- the Windows 7 look for the KDE desktops.
#
# This replaces the hand-drawn Aero7 theme that used to live in modules/win7/.
# That one was a Plasma *theme*: an Aurorae frame, a panel background, a colour
# scheme, and plasma-manager pointing Plasma at them. AeroThemePlasma is a
# Plasma *shell* -- it ships its own start menu, taskbar, system tray, volume
# flyout, Aero Peek, Flip3D, the UAC dialog and the boot splash, and to do that
# it rebuilds libplasma and plasma-workspace with the aeroshell patches applied.
# The result is much closer to Windows 7 than anything a theme can reach.
#
# The packaging is upstream (github:nyakase/aerothemeplasma-nix); this module
# only decides what we switch on. Two things are worth knowing before editing:
#
#   * The flake input is pinned to the Plasma 6.6 series on purpose. See the
#     comment on the `aerothemeplasma` input in flake.nix -- it is not a stale
#     pin waiting to be bumped, it tracks our nixpkgs' Plasma version.
#
#   * plasma-manager is deliberately gone. AeroThemePlasma configures Plasma
#     from a first-login setup wizard (atpootb), and upstream calls out
#     plasma-manager as the thing that fights it. Two writers, one kdeglobals.
#     If declarative Plasma settings are ever wanted back, they have to be
#     reconciled with the wizard rather than layered on top of it.
#
# The shell is a *session*, selected at the login screen and set as the default
# below. Plain Plasma is still installed and still listed in SDDM, which is the
# escape hatch if a Plasma update ever breaks the patched shell.
{
  self,
  inputs,
  ...
}:
let
  # B00merang's Windows 7 GTK theme. AeroThemePlasma explicitly doesn't do GTK
  # -- upstream points at a third-party theme instead -- but leaving GTK apps
  # on the dark Nordic default from modules/desktop.nix would be the one thing
  # on screen still contradicting the rest, so we dress them ourselves.
  gtkTheme =
    pkgs:
    pkgs.runCommand "windows-7-gtk-theme" { } ''
      mkdir -p $out/share/themes
      cp -r ${
        pkgs.fetchFromGitHub {
          owner = "B00merang-Project";
          repo = "Windows-7";
          rev = "943b5307b349d3526068be0fa32f7549ee37ab45";
          hash = "sha256-itEHU/9LeraH0n3a2F/r8FWF8Vj7BoF1FFUW2bLNJH4=";
        }
      } $out/share/themes/Windows-7
    '';
in
{
  # Self-gating: safe to import everywhere, does nothing off a KDE NixOS
  # desktop. Lives in modules/builder.nix's alwaysImport.
  flake.nixosModules.aerothemeplasma =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [ inputs.aerothemeplasma.nixosModules.aerothemeplasma-nix ];

      config =
        lib.mkIf (config.noughty.host.is.nixosDesktop && config.noughty.host.desktop == "kde")
          {
            programs.aeroshell = {
              enable = true;
              # The Windows 7 UAC dialog, replacing polkit-kde-agent.
              polkit.enable = true;
              # Segoe UI, from the MIT-licensed Microsoft repo upstream vendors
              # it from -- not from a Windows ISO. Lucida Console is left off:
              # it only shows on the Plymouth LUKS prompt, and it would have to
              # be copied off a Windows install by hand.
              fonts.segoe.enable = true;
              sessions = {
                wayland.enable = true;
                # Off deliberately, and it does not default off: the option
                # follows services.xserver.enable, which modules/desktop.nix
                # sets on every desktop. Leaving it on would compile a second
                # copy of five KWin C++ effects for a session we don't log
                # into, and KDE drops X11 entirely in Plasma 6.8 anyway.
                x11.enable = false;
              };
              aerothemeplasma = {
                enable = true;
                sddm.enable = true;
                plymouth.enable = true;
              };
            };

            # PlymouthVista needs a Plymouth to theme; nothing else here turns
            # it on. mkDefault so a host can still opt out of the boot splash.
            boot.plymouth.enable = lib.mkDefault true;

            # Log straight into the Windows 7 shell. Plain Plasma stays in the
            # session picker at the login screen.
            #
            # mkOverride 900, not mkDefault: nixos' plasma6.nix mkDefaults this
            # to "plasma", so two defaults would just collide. 900 beats that
            # while still losing to any ordinary definition in a host module --
            # i.e. a host can still pin its own session without mkForce.
            services.displayManager.defaultSession = lib.mkOverride 900 "aerothemeplasma";
          };
    };

  # GTK side. Imported from the gui-nixos bundle, which every NixOS desktop
  # uses, so it gates itself the same way the NixOS half does.
  flake.homeModules.aerothemeplasma =
    {
      config,
      lib,
      pkgs,
      osConfig ? null,
      ...
    }:
    let
      isKde = osConfig == null || (osConfig.noughty.host.desktop or null) == "kde";
      atp = inputs.aerothemeplasma.packages.${pkgs.system};
    in
    {
      config = lib.mkIf isKde {
        gtk = {
          enable = true;
          theme = {
            package = gtkTheme pkgs;
            name = "Windows-7";
          };
          # AeroThemePlasma's own icon set, so GTK and Qt apps agree.
          iconTheme = {
            package = atp.icons;
            name = "Windows 7 Aero";
          };
          gtk3.extraConfig."gtk-application-prefer-dark-theme" = 0;
          gtk4.extraConfig."gtk-application-prefer-dark-theme" = 0;
        };

        # The Aero cursor for GTK/X apps. Plasma's own cursor is set by the
        # setup wizard; this is the half of the system that doesn't read
        # kcminputrc.
        home.pointerCursor = {
          enable = true;
          package = atp.cursors;
          name = "aero-drop";
          size = 30;
          gtk.enable = true;
        };
      };
    };
}
