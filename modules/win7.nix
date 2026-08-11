# Windows 7 for Plasma 6.
#
# Nothing here is downloaded from a theme store. The window decoration, the
# taskbar, the task buttons, the colour scheme, the start orb and the wallpaper
# are all drawn in this repo, under modules/win7/, and packaged below. The two
# things we do fetch are B00merang's Windows-7 GTK theme and icon set (so GTK
# apps and file icons match) and Microsoft's own open-source Selawik, which is
# metric-compatible with Segoe UI.
#
# Split of responsibilities:
#
#   nixosModules.win7  installs the artwork and fonts SYSTEM-wide. This is not
#                      cosmetic: Plasma discovers Aurorae themes, Plasma styles
#                      and colour schemes through XDG_DATA_DIRS, and a session
#                      launched by SDDM cannot be relied on to have picked up
#                      ~/.nix-profile/share. /run/current-system/sw/share is
#                      always there.
#   homeModules.win7   selects them, via plasma-manager, plus the panel layout
#                      and the GTK side.
#
# Applies to every KDE desktop in the registry (g14 and blac today), gated on
# noughty.host.desktop == "kde".
#
# Not covered, in case it comes up later: the SDDM login screen keeps Breeze's
# background (a themed one needs a QML SDDM theme, not a config setting), and
# the Windows 7 sound scheme is not redistributable.
{ self, inputs, ... }:
let
  # Built the same way from both the NixOS and the Home Manager side. Nix
  # dedupes them by derivation hash, so the store paths the HM module bakes
  # into config (wallpaper, start orb) are the ones NixOS installed.
  themes = pkgs: {
    # Everything hand-drawn in this repo, in the layouts KDE expects to find
    # it: an Aurorae theme, a Plasma style, a colour scheme, an icon and a
    # rendered wallpaper.
    aero7 = pkgs.runCommand "aero7-theme" { nativeBuildInputs = [ pkgs.librsvg ]; } ''
      aurorae=$out/share/aurorae/themes/Aero7
      install -Dm644 ${./win7/aurorae/metadata.desktop} $aurorae/metadata.desktop
      install -Dm644 ${./win7/aurorae/Aero7rc}          $aurorae/Aero7rc
      install -Dm644 ${./win7/aurorae/decoration.svg}   $aurorae/decoration.svg
      install -Dm644 ${./win7/aurorae/close.svg}        $aurorae/close.svg
      install -Dm644 ${./win7/aurorae/maximize.svg}     $aurorae/maximize.svg
      install -Dm644 ${./win7/aurorae/minimize.svg}     $aurorae/minimize.svg
      install -Dm644 ${./win7/aurorae/restore.svg}      $aurorae/restore.svg

      style=$out/share/plasma/desktoptheme/Aero7
      install -Dm644 ${./win7/plasma/metadata.json} $style/metadata.json
      install -Dm644 ${./win7/plasma/widgets/panel-background.svg} $style/widgets/panel-background.svg
      install -Dm644 ${./win7/plasma/widgets/tasks.svg}            $style/widgets/tasks.svg
      # A panel set to a specific opacity looks for art under opaque/ or
      # translucent/ before falling back to widgets/. Our glass is the same
      # either way, so point all three at it.
      for variant in opaque translucent; do
        install -Dm644 ${./win7/plasma/widgets/panel-background.svg} $style/$variant/widgets/panel-background.svg
        install -Dm644 ${./win7/plasma/widgets/tasks.svg}            $style/$variant/widgets/tasks.svg
      done

      install -Dm644 ${./win7/Aero7.colors} $out/share/color-schemes/Aero7.colors
      install -Dm644 ${./win7/start-orb.svg} \
        $out/share/icons/hicolor/scalable/apps/win7-start-orb.svg

      # Rasterised here rather than shipped as an SVG wallpaper: the source
      # leans on Gaussian blur, which librsvg honours and Qt does not.
      mkdir -p $out/share/wallpapers
      rsvg-convert -w 3840 -h 2160 -o $out/share/wallpapers/aero7.png ${./win7/wallpaper.svg}
    '';

    # GTK apps (and anything else reading an icon theme) so they stop looking
    # like the odd ones out. B00merang's index.theme names both "Windows-7".
    gtkTheme = pkgs.stdenvNoCC.mkDerivation {
      pname = "windows-7-gtk-theme";
      version = "0-unstable-2024-09-15";
      src = pkgs.fetchFromGitHub {
        owner = "B00merang-Project";
        repo = "Windows-7";
        rev = "943b5307b349d3526068be0fa32f7549ee37ab45";
        hash = "sha256-itEHU/9LeraH0n3a2F/r8FWF8Vj7BoF1FFUW2bLNJH4=";
      };
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        mkdir -p $out/share/themes/Windows-7
        cp -a . $out/share/themes/Windows-7
        runHook postInstall
      '';
    };

    iconTheme = pkgs.stdenvNoCC.mkDerivation {
      pname = "windows-7-icon-theme";
      version = "0-unstable-2025-12-24";
      src = pkgs.fetchFromGitHub {
        owner = "B00merang-artwork";
        repo = "Windows-7";
        rev = "b1577ced806262ae0caad89ed183d1d5b0336852";
        hash = "sha256-0NPPArVPYReUNElmLKxuw1zIiiVBDq++xMPGU4GGRR0=";
      };
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        mkdir -p $out/share/icons/Windows-7
        cp -a . $out/share/icons/Windows-7
        # Two bits of upstream breakage, both of which fail the build rather
        # than degrade quietly:
        #
        #   1. banshee, banshee-panel and mozilla-firefox were committed as
        #      symlinks whose "target" is raw PNG bytes, so they dangle, and
        #      nixpkgs' noBrokenSymlinks check rejects them.
        #   2. Four icons have spaces in their filenames ("Community Help.png"
        #      and friends). An icon name cannot contain a space under the
        #      icon-theme spec, nothing can reference them, and they make
        #      gtk-update-icon-cache emit a cache it then rejects as invalid,
        #      which fails the whole system-path build.
        find $out/share/icons/Windows-7 -xtype l -delete
        find $out/share/icons/Windows-7 -name '* *' -delete
        runHook postInstall
      '';
    };

    # Selawik: Microsoft's own open-source, metric-compatible stand-in for
    # Segoe UI. The release zip carries the built fonts; the git tree only has
    # UFO/Glyphs sources, which would mean a full font build for nothing.
    selawik = pkgs.stdenvNoCC.mkDerivation {
      pname = "selawik";
      version = "1.01";
      src = pkgs.fetchurl {
        url = "https://github.com/microsoft/Selawik/releases/download/1.01/Selawik_Release.zip";
        hash = "sha256-P2LFHgXjtaHmJBz5KjcfC+LqEYOqh7MHGLvUCDKo1CM=";
      };
      nativeBuildInputs = [ pkgs.unzip ];
      sourceRoot = ".";
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        install -Dm644 -t $out/share/fonts/truetype *.ttf
        runHook postInstall
      '';
    };
  };
in
{
  flake.nixosModules.win7 =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      t = themes pkgs;
    in
    lib.mkIf (config.noughty.host.is.nixosDesktop && config.noughty.host.desktop == "kde") {
      environment.systemPackages = [
        t.aero7
        t.gtkTheme
        t.iconTheme
        # DMZ-White: the closest thing packaged to the Windows pointer set, and
        # what B00merang's own index.theme asks for.
        pkgs.vanilla-dmz
      ];
      fonts.packages = [ t.selawik ];

      # SDDM runs before the user session, so it reads none of the Home Manager
      # config below. These two keep the login screen from being a jump cut.
      services.displayManager.sddm.settings.Theme = {
        CursorTheme = "DMZ-White";
        Font = "Selawik";
      };
    };

  flake.homeModules.win7 =
    {
      pkgs,
      lib,
      config,
      osConfig ? null,
      ...
    }:
    let
      t = themes pkgs;
      # The `gui-nixos` HM bundle is imported by every NixOS desktop, so gate
      # here rather than there. osConfig is absent under standalone Home
      # Manager, where there is no registry to ask.
      isKde = osConfig == null || (osConfig.noughty.host.desktop or null) == "kde";
    in
    {
      imports = [ inputs.plasma-manager.homeModules.plasma-manager ];

      config = lib.mkIf isKde {
        programs.plasma = {
          enable = true;

          workspace = {
            theme = "Aero7"; # Plasma style: the taskbar and task buttons
            colorScheme = "Aero7"; # application palette
            iconTheme = "Windows-7";
            cursor = {
              theme = "DMZ-White";
              size = 24;
            };
            windowDecorations = {
              library = "org.kde.kwin.aurorae";
              # Aurorae themes are addressed by this __aurorae__svg__ prefix plus
              # the theme directory name; a bare "Aero7" silently does nothing.
              theme = "__aurorae__svg__Aero7";
            };
            wallpaper = "${t.aero7}/share/wallpapers/aero7.png";
            # Plasma's blue boot splash would announce KDE before the desktop
            # even appears.
            splashScreen.theme = "None";
          };

          fonts =
            let
              ui = size: {
                family = "Selawik";
                pointSize = size;
              };
            in
            {
              general = ui 10;
              small = ui 8;
              toolbar = ui 10;
              menu = ui 10;
              windowTitle = ui 10;
            };

          # One bottom taskbar: orb, pinned/running apps as icons, tray, a
          # two-line clock, and the sliver of "show desktop" at the far right.
          panels = [
            {
              location = "bottom";
              height = 40;
              floating = false;
              opacity = "translucent";
              widgets = [
                { kickoff.icon = "${t.aero7}/share/icons/hicolor/scalable/apps/win7-start-orb.svg"; }
                {
                  iconTasks = {
                    iconsOnly = true;
                    launchers = [
                      "applications:org.kde.dolphin.desktop"
                      "applications:org.kde.konsole.desktop"
                      # Resolved at runtime, so it survives whatever the default
                      # browser happens to be instead of hardcoding a desktop id.
                      "preferred://browser"
                    ];
                    appearance = {
                      showTooltips = true;
                      highlightWindows = true;
                      indicateAudioStreams = true;
                    };
                    behavior = {
                      grouping.method = "byProgramName";
                      # Windows 7 fans a grouped button out into thumbnails.
                      grouping.clickAction = "showPresentWindowsEffect";
                      minimizeActiveTaskOnClick = true;
                    };
                  };
                }
                "org.kde.plasma.marginsseparator"
                "org.kde.plasma.systemtray"
                {
                  digitalClock = {
                    date = {
                      enable = true;
                      position = "belowTime";
                      format = "shortDate";
                    };
                    time = {
                      showSeconds = "never";
                      format = "24h";
                    };
                  };
                }
                "org.kde.plasma.showdesktop"
              ];
            }
          ];

          kwin = {
            # Aero put nothing on the left: the app icon there is a menu button
            # Aurorae draws from the window icon, which our theme has no art for.
            titlebarButtons = {
              left = [ ];
              right = [
                "minimize"
                "maximize"
                "close"
              ];
            };
            # The glass only reads as glass if there is something behind it.
            effects.blur = {
              enable = true;
              strength = 10;
            };
            # Windows 7 keeps its titlebar when maximized.
            borderlessMaximizedWindows = false;
          };

          configFile.kwinrc = {
            Plugins = {
              # Background contrast is the other half of Aero glass: blur alone
              # leaves the frame washed out over bright wallpapers.
              contrastEnabled = true;
              wobblywindowsEnabled = false;
            };
            # Alt+Tab as a strip of live window thumbnails.
            TabBox.LayoutName = "thumbnail_grid";
            # Aero Snap. On by default, but this is the behaviour being imitated,
            # so it should not be left to chance.
            Windows = {
              ElectricBorderMaximize = true;
              ElectricBorderTiling = true;
            };
          };
        };

        # GTK apps follow along. The dark Nordic defaults in modules/desktop.nix
        # are mkDefault precisely so this can take over.
        gtk = {
          theme = {
            name = "Windows-7";
            package = t.gtkTheme;
          };
          iconTheme = {
            name = "Windows-7";
            package = t.iconTheme;
          };
          gtk3.extraConfig."gtk-application-prefer-dark-theme" = 0;
          gtk4.extraConfig."gtk-application-prefer-dark-theme" = 0;
        };

        home.pointerCursor = {
          enable = true;
          package = pkgs.vanilla-dmz;
          name = "DMZ-White";
          size = 24;
          gtk.enable = true;
        };
      };
    };
}
