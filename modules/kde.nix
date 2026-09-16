# Everything KDE, in one file.
#
# The KDE desktops (blac, g14 -- `desktop = "kde"` in lib/registry.nix) used to
# be configured from four modules plus a handful of stanzas inside
# modules/desktop.nix, and the four cross-referenced each other in nearly every
# comment. They are all here now, in the order the machine meets them:
#
#   1. `linver` -- the `winver` clone, packaged (perSystem) so it can be built
#      on its own with `nix build .#linver`.
#   2. The NixOS half (`nixosModules.kde`): the session itself -- SDDM, Plasma
#      6, AeroThemePlasma's patched shell, and the KConfig files that cascade
#      from /etc/xdg. Also the only place `noughty.kde.*` is *declared*.
#   3. The Home Manager half (`homeModules.kde`): everything that has to be
#      written into $HOME or spoken to a running shell -- GTK theming, the
#      global shortcuts, the Linver window rule, and the wallpaper/panel
#      layout.
#
# What stayed outside: modules/desktop.nix keeps the DE-agnostic desktop
# baseline (pipewire, networkmanager, the package list, quiet boot) and the
# gnome branch of the display-manager choice. Anything that reads "only true on
# KDE" belongs here instead.
#
# Two constraints shape almost every decision below, so they are stated once:
#
#   * plasma-manager is deliberately absent from this repo. AeroThemePlasma
#     configures Plasma from a first-login setup wizard (atpootb), and upstream
#     calls out plasma-manager as the thing that fights it. Two writers, one
#     kdeglobals. Declarative Plasma settings here have to be reconciled with
#     the wizard rather than layered on top of it.
#
#   * Which mechanism a setting uses is decided by who owns the file:
#       - /etc/xdg/<file>rc  -- an ordinary KConfig file cascades through
#         XDG_CONFIG_DIRS, so this is a *default* the System Settings dialog
#         can still override into ~/.config. Used for dolphinrc, ksmserverrc.
#       - kwriteconfig6 from an activation script -- for files KDE owns and
#         rewrites (kglobalshortcutsrc, kwinrc, kwinrulesrc), where a home
#         value shadows the system one key by key and a store symlink would
#         make the file read-only.
#       - plasmashell's D-Bus scripting API -- for shell *layout* (wallpaper,
#         panels), which is runtime state, not a config file we may name.
#       - home.file symlinks -- only where nothing ever writes back
#         (the kglobalaccel launcher drop-ins).
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
  # ======================================================================
  # Linver -- wackyideas' clone of Windows' `winver` dialog, from the same
  # author as AeroThemePlasma. Upstream calls it out as the intended companion
  # to ATP, and it is the last obvious "not Windows" tell left in the rice:
  # the About box. https://gitgud.io/wackyideas/linver
  #
  # Upstream's install path is `sh install.sh` (qmake6 + `sudo make install`
  # into /usr/bin) and `sh add_rule.sh` (a KWin rule bolted into
  # ~/.config/kwinrulesrc with a freshly generated uuid). Neither is usable as
  # written here -- the first writes outside the store, the second is not
  # idempotent -- so both halves are rebuilt: a qmake derivation here and an
  # activation script keyed on a fixed uuid in the home module below.
  # ======================================================================
  perSystem =
    { pkgs, ... }:
    {
      # Exposed as a package rather than built inline in the home module so it
      # can be built and run on its own (`nix build .#linver`) without
      # evaluating a whole host closure -- see the verification rule in the
      # `nixconfig` skill.
      packages.linver = pkgs.callPackage (
        {
          stdenv,
          fetchgit,
          qt6,
          makeDesktopItem,
          copyDesktopItems,
          lib,
        }:
        stdenv.mkDerivation {
          pname = "linver";
          # No tags or releases upstream; master moves a few times a year.
          # Date is the pinned commit's, per nixpkgs' unstable convention.
          version = "0-unstable-2026-01-04";

          # fetchgit, not fetchFromGitLab: gitgud.io is a GitLab instance but
          # its tarball endpoint sits behind the same bot check that blocks
          # plain HTTP fetches of the web UI. A git clone goes through, and
          # the hash below is the one `nix flake prefetch git+https://...`
          # reports for exactly this rev.
          src = fetchgit {
            url = "https://gitgud.io/wackyideas/linver.git";
            rev = "087f2746703d9c885de2e1a4f6360314283703f4";
            hash = "sha256-QeoXvKWuSCzH82krr6AnBpqwKFBhPaQiGEmy+N1Qz+g=";
          };

          nativeBuildInputs = [
            qt6.qmake
            qt6.wrapQtAppsHook
            copyDesktopItems
          ];
          # linver.pro asks for QT += core gui widgets, and nothing else --
          # every branding image is baked into the binary through basebrd.qrc,
          # so there is no runtime data directory to install.
          buildInputs = [ qt6.qtbase ];

          # linver.pro hardcodes `target.path = /usr/bin`, so `make install`
          # would try to write outside the store. The binary is the entire
          # payload; install it by hand and skip the install target.
          installPhase = ''
            runHook preInstall
            install -Dm755 linver $out/bin/linver
            runHook postInstall
          '';

          # Upstream ships no .desktop file, which would leave the thing
          # launchable only from a terminal -- useless for an ornament. The
          # StartupWMClass has to stay `linver`: it is what KWin matches the
          # caption-button rule on below, and what the task manager groups by.
          desktopItems = [
            (makeDesktopItem {
              name = "linver";
              desktopName = "Linver";
              genericName = "About Windows";
              comment = "Display Windows version information";
              exec = "linver";
              icon = "computer";
              categories = [
                "System"
                "Qt"
              ];
              startupWMClass = "linver";
              # So typing "winver" into KRunner finds it, the same way it
              # would on the OS being imitated.
              keywords = [
                "winver"
                "about"
                "version"
              ];
            })
          ];

          meta = {
            description = "Windows-style `winver` dialog for KDE Plasma";
            homepage = "https://gitgud.io/wackyideas/linver";
            license = lib.licenses.gpl3Only;
            mainProgram = "linver";
            platforms = lib.platforms.linux;
          };
        }
      ) { };
    };

  # ======================================================================
  # NixOS half -- the session, and the /etc/xdg KConfig defaults.
  #
  # Self-gating, so it is safe in modules/builder.nix's alwaysImport: the
  # option declarations are unconditional (blac.nix cannot set an option
  # nothing has declared, even on a host where the rest is inert) and every
  # bit of config hangs off nixosDesktop AND desktop == "kde".
  # ======================================================================
  flake.nixosModules.kde =
    { config, lib, ... }:
    {
      imports = [ inputs.aerothemeplasma.nixosModules.aerothemeplasma-nix ];

      # Per-host knobs for the shell layout. The work is in the home module.
      options.noughty.kde = {
        wallpaperDir = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          # The slideshow plugin walks subdirectories itself, so pointing at
          # the top of a tree is enough -- ImageWallpaper::findAll keeps a
          # visit queue and appends every directory it meets. There is no
          # "recursive" key to set; it is the only behaviour it has.
          default = "/home/phonkd/Downloads/Walls";
          description = ''
            Directory of wallpapers for the KDE slideshow, searched
            recursively. Null leaves the wallpaper alone entirely.
          '';
        };

        wallpaperInterval = lib.mkOption {
          type = lib.types.ints.positive;
          # Plasma's own default is 900. Shorter here because the reason the
          # slideshow exists is OLED burn-in, not variety.
          default = 300;
          description = "Seconds between wallpaper changes.";
        };

        panelAutoHide = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Auto-hide the Plasma panel(s). Off by default and switched on
            per-host: a permanently-lit taskbar is the worst burn-in offender
            on an OLED panel, and only some of the desktops have one.

            Deliberately not derived from noughty.host.formFactor. That would
            read as "desktops hide their taskbar, laptops don't", which is not
            the rule -- the rule is "this screen is OLED".
          '';
        };
      };

      config = lib.mkIf (config.noughty.host.is.nixosDesktop && config.noughty.host.desktop == "kde") {
        # --- Display manager + desktop manager ------------------------
        # The gnome branch of this choice stays in modules/desktop.nix;
        # both are driven by noughty.host.desktop from the registry, so
        # hosts never hand-wire SDDM/GDM.
        services.displayManager.sddm = {
          enable = true;
          wayland.enable = true;
        };
        services.desktopManager.plasma6.enable = true;

        # --- AeroThemePlasma: the Windows 7 shell ----------------------
        # This replaces the hand-drawn Aero7 theme that used to live in
        # modules/win7/. That one was a Plasma *theme*: an Aurorae frame, a
        # panel background, a colour scheme, and plasma-manager pointing
        # Plasma at them. AeroThemePlasma is a Plasma *shell* -- it ships
        # its own start menu, taskbar, system tray, volume flyout, Aero
        # Peek, Flip3D, the UAC dialog and the boot splash, and to do that
        # it rebuilds libplasma and plasma-workspace with the aeroshell
        # patches applied. The result is much closer to Windows 7 than
        # anything a theme can reach.
        #
        # The packaging is upstream (github:nyakase/aerothemeplasma-nix);
        # this only decides what we switch on. The flake input is pinned to
        # the Plasma 6.6 series on purpose -- see the comment on the
        # `aerothemeplasma` input in flake.nix. It is not a stale pin
        # waiting to be bumped, it tracks our nixpkgs' Plasma version.
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
        # (modules/desktop.nix's quiet-boot kernel params assume it.)
        boot.plymouth.enable = lib.mkDefault true;

        # Log straight into the Windows 7 shell. Plain Plasma stays in the
        # session picker at the login screen, which is the escape hatch if
        # a Plasma update ever breaks the patched shell.
        #
        # mkOverride 900, not mkDefault: nixos' plasma6.nix mkDefaults this
        # to "plasma", so two defaults would just collide. 900 beats that
        # while still losing to any ordinary definition in a host module --
        # i.e. a host can still pin its own session without mkForce.
        services.displayManager.defaultSession = lib.mkOverride 900 "aerothemeplasma";

        # --- KDE logs in to an empty desktop ---------------------------
        # Plasma's default is loginMode=restorePreviousLogout: it saves the
        # window list on logout and reopens the lot at the next login.
        # Turned off here -- a login should start clean, not resurrect
        # whatever was on screen when the machine was shut down.
        #
        # Values are ksmserver's own (`emptySession`,
        # `restorePreviousLogout`, `restoreSavedSession`), verified against
        # the strings in plasma-workspace's ksmserver and
        # plasma-fallback-session-restore binaries rather than from memory
        # -- the latter is the Wayland path that actually does the
        # reopening in Plasma 6.
        #
        # /etc/xdg, not ~/.config, per the cascade rule at the top of this
        # file: System Settings' "Desktop Session" page can still override
        # it into ~/.config/ksmserverrc. It also stays out of ksmserver's
        # way -- that file is rewritten at every logout with the
        # saved-session groups, and a home.file symlink into the store
        # would make it read-only.
        environment.etc."xdg/ksmserverrc".text = ''
          [General]
          loginMode=emptySession
        '';

        # --- Dolphin ---------------------------------------------------
        # AeroThemePlasma dresses the shell, not the apps, and upstream
        # ships nothing for the file manager -- so out of the box you get
        # Windows 7 icons and Aero widgets wrapped around Dolphin's own
        # layout, which reads as neither. These are the settings that close
        # most of that gap; the ones that can't be closed from config (the
        # sidebar's "Places/Remote/Devices" headings, the toolbar layout)
        # are hardcoded in KIO and Dolphin's ui.rc respectively.
        #
        # /etc/xdg again, so every line below is a *default*: Dolphin's
        # settings dialog still works and whatever the user changes lands
        # in ~/.config/dolphinrc and wins. Writing the home file instead
        # would freeze the dialog's output. The one Dolphin setting that
        # cannot come from here is the default view mode -- see
        # `dolphinViewProps` in the home module.
        environment.etc."xdg/dolphinrc".text = ''
          [General]
          # Explorer has no tabs, and opens on one folder rather than
          # restoring the last session.
          RememberOpenedTabs=false
          # One view for every folder, the way Explorer's "Apply to Folders"
          # leaves it. Also load-bearing: the default view mode itself is
          # seeded into ~/.local/share/dolphin/view_properties/global,
          # which Dolphin only reads while this is on.
          GlobalViewProps=true
          # Explorer's status bar spans the window; Dolphin's default is a
          # small floating overlay in the corner.
          ShowStatusBar=1
          # No hover check-circle on items -- Windows 7 has that off too.
          ShowSelectionToggle=false
          # Explorer walks into a .zip like a folder.
          BrowseThroughArchives=true

          [DetailsMode]
          # 16px rows with no thumbnail inflation, i.e. Explorer's Details
          # view. Dolphin's own preview size here is 48.
          IconSize=16
          PreviewSize=16
          # Explorer's Details view has no tree expanders on folders.
          ExpandableFolders=false
        '';
      };
    };

  # ======================================================================
  # Home Manager half -- everything that lands in $HOME or is spoken to a
  # running shell. Imported from the gui-nixos bundle
  # (modules/hosts/types/gui/default.nix), which every NixOS desktop uses, so
  # it self-gates on the desktop being KDE exactly like the NixOS half.
  # ======================================================================
  flake.homeModules.kde =
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

      # kwriteconfig6/kreadconfig6, used by all three activation scripts below.
      kconfig = pkgs.kdePackages.kconfig;
      shortcutsFile = "${config.xdg.configHome}/kglobalshortcutsrc";
      kwinrcFile = "${config.xdg.configHome}/kwinrc";
      kwinrulesFile = "${config.xdg.configHome}/kwinrulesrc";

      # --- Dolphin's default view mode --------------------------------------
      # ViewMode 1 is Details; the roles are Explorer's columns, in Explorer's
      # order. Version 4 is Dolphin's current view-properties format -- without
      # it the file reads as pre-migration and Dolphin rewrites the roles.
      dolphinViewProps = pkgs.writeText "dolphin-global-view-properties" ''
        [Dolphin]
        Version=4
        ViewMode=1
        VisibleRoles=Details_text,Details_modificationtime,Details_type,Details_size
      '';

      # --- Global shortcuts -------------------------------------------------
      # Mirrors the AeroSpace bindings from the Mac (modules/aerospace.nix) so
      # the same fingers do the same things on both. Alt here is what Option is
      # there: Alt+H/J/K/L to move focus, Alt+Shift+... to throw the window,
      # Alt+<letter> for a workspace, Alt+B/V/M to launch.
      #
      # Two mechanisms, because KDE stores the two halves in different places
      # and only one of them can be handed a file from the nix store:
      #
      #   * App launchers are *.desktop drop-ins in
      #     $XDG_DATA_DIRS/kglobalaccel/, each carrying X-KDE-Shortcuts. This is
      #     a first-class kglobalacceld feature
      #     (GlobalShortcutsRegistry::loadShortcuts scans that directory and
      #     registers a "_launch" action per file), and it is exactly how
      #     Dolphin gets Meta+E. Being drop-ins they can be plain home.file
      #     symlinks into the store -- nothing ever writes back to them, so
      #     this half is genuinely declarative. Note NoDisplay=true would make
      #     kglobalacceld skip the file, so these entries are "visible"; they
      #     live outside share/applications/ and so still never reach the app
      #     menu.
      #
      #   * KWin's own actions (focus, quick tile, virtual desktops,
      #     fullscreen) have no such drop-in path: their bindings live in
      #     ~/.config/kglobalshortcutsrc, which kglobalacceld owns and
      #     rewrites. /etc/xdg cascade is no help either -- kglobalacceld
      #     writes every action it knows into the *home* file on first run, and
      #     a home value shadows the system one key by key. So this half is an
      #     activation script that edits the home file in place with
      #     kwriteconfig6, the same way plasma-manager does it, and it lands at
      #     the next login.
      #
      # Deliberately not mapped, because KDE has no equivalent or the key is
      # worth more as its KDE default: alt-comma/alt-shift-comma (tiling
      # layouts), alt-slash (join-with), alt-equal (resize), alt-tab (KDE's
      # window switcher, vs AeroSpace's workspace-back-and-forth), alt-space
      # (KRunner, vs float toggle) and the whole `service` mode.
      #
      # Caveat worth knowing when editing the table: on Linux, Alt+<letter> is
      # also how Qt/GTK apps reach their menu mnemonics (Alt+F for File, Alt+E
      # for Edit, ...), and a global shortcut wins over the focused app. macOS
      # has no such convention, which is why this collision doesn't exist on
      # the AeroSpace side. `mod` below is the single knob: set it to "Meta"
      # and the entire set moves off Alt in one go. The one binding that
      # doesn't hang off `mod` is Meta+Q (close window) -- see the note on it
      # in the table.

      # The modifier the whole set hangs off. "Alt" = AeroSpace's Option.
      mod = "Alt";

      # AeroSpace's workspace keys, in AeroSpace's own order (built-in
      # display, then external 2, then external 3), onto KDE virtual desktops
      # 1..9. The Mac spreads these across three monitors; a single-screen
      # KDE host just gets nine desktops in a 3x3 grid.
      #
      # Three physical keyboard rows, top to bottom: the number row, then QWE,
      # then ASD. This used to be QWE/ASD/UIO -- the rows moved down one so
      # the 3x3 grid of desktops matches the 3x3 block of keys, instead of the
      # third row sitting off to the right of the other two.
      #
      # Mirrored in modules/hyprland.nix, and *deliberately not* in
      # modules/aerospace.nix. AeroSpace cannot bind this set, which is where
      # the all-letters QWE/ASD/UIO scheme came from in the first place: the
      # Mac's constraint used to set the layout for all three. It no longer
      # does. The two Linux sessions share a keyboard and now share these
      # keys; the Mac keeps the letters. So this list and Hyprland's move
      # together, and AeroSpace's stays where it is on purpose.
      #
      # Qt key sequences here, so plain "1"/"2"/"3" -- the `code:` spelling
      # the Hyprland half needs for the SHIFT variants on this
      # ch/de_nodeadkeys keyboard has no equivalent in kglobalshortcutsrc.
      workspaceKeys = [
        "1"
        "2"
        "3"
        "Q"
        "W"
        "E"
        "A"
        "S"
        "D"
      ];
      desktopCount = builtins.length workspaceKeys;
      desktopRows = 3;

      perDesktop =
        prefix: action:
        lib.listToAttrs (
          lib.imap1 (
            i: key: lib.nameValuePair "${action} ${toString i}" "${mod}+${prefix}${key}"
          ) workspaceKeys
        );

      # Action names are kglobalshortcutsrc's [kwin] keys verbatim -- they are
      # the registration ids kwin uses, not display strings, so they have to
      # match exactly.
      kwinShortcuts = {
        # alt-h/j/k/l = focus left/down/up/right
        "Switch Window Left" = "${mod}+H";
        "Switch Window Down" = "${mod}+J";
        "Switch Window Up" = "${mod}+K";
        "Switch Window Right" = "${mod}+L";
        # alt-shift-h/j/k/l = move the window. KWin has no tiling-WM "move
        # node", so this is quick-tile: the closest thing to shoving a window
        # to an edge that KWin ships.
        "Window Quick Tile Left" = "${mod}+Shift+H";
        "Window Quick Tile Bottom" = "${mod}+Shift+J";
        "Window Quick Tile Top" = "${mod}+Shift+K";
        "Window Quick Tile Right" = "${mod}+Shift+L";
        # alt-f = fullscreen
        "Window Fullscreen" = "${mod}+F";
        # Meta+Q = close window. Deliberately *not* on `mod`: this is the
        # Cmd+Q finger from the Mac landing on the key Windows/KDE users
        # reach for, and Alt+Q is already a workspace key below. KDE's own
        # Alt+F4 survives -- setShortcut appends the defaults.
        "Window Close" = "Meta+Q";
      }
      // perDesktop "" "Switch to Desktop"
      // perDesktop "Shift+" "Window to Desktop";

      # Launchers. Absolute store paths rather than bare command names: these
      # are run by KIO's ApplicationLauncherJob, not by a login shell, so
      # nothing guarantees the user profile is on its PATH.
      launchers = {
        # alt-b = Zen (alt-b opens Zen.app on the Mac)
        zen = {
          name = "Zen Browser";
          exec = "${inputs.zen-browser.packages.${pkgs.system}.default}/bin/zen";
          key = "${mod}+B";
        };
        # alt-v = terminal. Same as AeroSpace, where alt-v opens a *new*
        # kitty window; kitty is not single-instance here either.
        kitty = {
          name = "kitty";
          exec = "${config.programs.kitty.package}/bin/kitty";
          key = "${mod}+V";
        };
        # alt-m = music. Tidal on the Mac, Spotify on the NixOS desktops.
        spotify = {
          name = "Spotify";
          exec = "${pkgs.spotify}/bin/spotify";
          key = "${mod}+M";
        };
      };

      # Bindings KDE ships that would fight one of ours. kglobalacceld keeps
      # both registrations when two components claim the same key and the
      # loser is decided at load order, so the collision has to be resolved
      # here rather than left to chance. Keyed by kglobalshortcutsrc group
      # (the component), valued by the action names to clear.
      clearedShortcuts = {
        # Meta+Q is Plasma's Activity Switcher out of the box, which is what
        # "Window Close" above wants. Activities are unused here; the switcher
        # is still reachable from the desktop context menu.
        plasmashell = [ "manage activities" ];
      };

      setShortcutCalls = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          action: keys: "  setShortcut ${lib.escapeShellArg action} ${lib.escapeShellArg keys}"
        ) kwinShortcuts
      );

      clearShortcutCalls = lib.concatStringsSep "\n" (
        lib.flatten (
          lib.mapAttrsToList (
            component:
            map (action: "  clearShortcut ${lib.escapeShellArg component} ${lib.escapeShellArg action}")
          ) clearedShortcuts
        )
      );

      # --- Linver's window rule ---------------------------------------------
      # Fixed rather than generated. Upstream's add_rule.sh calls uuidgen, so
      # re-running it would append a second identical rule; a constant makes
      # the activation below idempotent and lets an edit here rewrite the
      # existing rule in place instead of stacking a new one.
      linverRuleUuid = "b1f5c2a7-3d94-4e18-9c6b-7a0e2f8d41c3";
      linverRuleDescription = "LINVER_RULES";

      # --- Plasma shell layout ----------------------------------------------
      # The wallpaper slideshow and panel visibility, applied through
      # plasmashell's own scripting API.
      #
      # Why not a config file: writing the appletsrc directly is worse than it
      # looks. The shell package names the file, and AeroThemePlasma ships its
      # *own* shell -- the live file on a KDE host here is
      # `plasma-io.gitgud.wackyideas.desktop-appletsrc`, not
      # `plasma-org.kde.plasma.desktop-appletsrc` (which sits nearly empty).
      # Hardcoding either filename breaks the moment you pick the other session
      # at the login screen. On top of that the containment numbers are runtime
      # state -- the desktop happens to be [Containments][1] and the panel
      # [Containments][2] today -- so a static file would have to guess them.
      #
      # The scripting API has neither problem. `desktops()` and `panels()` are
      # resolved by the running shell against whatever containments it actually
      # has, and plasmashell writes its own config afterwards. It is the same
      # interface `plasma-apply-wallpaperimage` uses. Verified against
      # aeroshell: the patched binary still owns the `org.kde.plasmashell` bus
      # name.
      #
      # The cost of that choice is that this needs a *running* shell, so it is
      # a systemd user service hooked to graphical-session.target rather than
      # an HM activation script. It re-applies at every login, which is the
      # point: these are declared settings, not seeded defaults like the
      # Dolphin view properties above. Change them here, not in System Settings
      # -- a change made in the GUI survives until the next login and then goes
      # back.
      kdeCfg = osConfig.noughty.kde or { };
      wallpaperDir = kdeCfg.wallpaperDir or null;
      wallpaperInterval = kdeCfg.wallpaperInterval or 300;
      panelAutoHide = kdeCfg.panelAutoHide or false;

      # Keys are org.kde.slideshow's own, from its contents/config/main.xml:
      #   SlidePaths     StringList  directories to search
      #   SlideInterval  int         seconds
      #   SlideshowMode  int         SortingMode::Mode -- 0 is Random
      #   FillMode       int         Qt image fill -- 2 is PreserveAspectCrop
      # Random ordering matters here: alphabetical would put the same image on
      # screen at the same point of every session.
      wallpaperJs = lib.optionalString (wallpaperDir != null) ''
        var slidePaths = ${builtins.toJSON [ wallpaperDir ]};
        var ds = desktops();
        for (var i = 0; i < ds.length; i++) {
            ds[i].wallpaperPlugin = "org.kde.slideshow";
            ds[i].currentConfigGroup = ["Wallpaper", "org.kde.slideshow", "General"];
            ds[i].writeConfig("SlidePaths", slidePaths);
            ds[i].writeConfig("SlideInterval", ${toString wallpaperInterval});
            ds[i].writeConfig("SlideshowMode", 0);
            ds[i].writeConfig("FillMode", 2);
        }
      '';

      # Only emitted when the option is on. The `false` case deliberately does
      # *not* force panels back to always-visible: this module has no opinion
      # about g14's taskbar, so it should not quietly undo a manual change
      # there at every login.
      #
      # "autohide" is matched case-insensitively by Panel::setHiding; the other
      # accepted spellings are "dodgewindows" and "windowsgobelow".
      panelJs = lib.optionalString panelAutoHide ''
        var ps = panels();
        for (var j = 0; j < ps.length; j++) {
            ps[j].hiding = "autohide";
        }
      '';

      # No IIFE and no helper functions on purpose. Containment.wallpaperPlugin
      # is only pushed onto the real containment in the JS wrapper's
      # *destructor*, so the assignments have to be plain top-level statements
      # whose objects the engine tears down when the script ends.
      shellScript = wallpaperJs + panelJs;

      applyShellLayout = pkgs.writeShellScript "kde-plasma-shell-layout" ''
        set -u
        script=${lib.escapeShellArg shellScript}

        # plasmashell registers its bus name a little after
        # graphical-session.target is reached, so the call is retried rather
        # than ordered after a unit -- the unit name differs per session
        # (plasma-aeroshell.service under AeroThemePlasma,
        # plasma-plasmashell.service under stock Plasma) and ordering after a
        # unit that does not exist on this host would be a silent no-op.
        #
        # Retrying the call itself is safe: there is no D-Bus activation file
        # for org.kde.plasmashell, so a call made too early fails with
        # ServiceUnknown instead of launching a second, stock shell.
        # Bash arithmetic rather than `seq`: a systemd user unit gets no
        # inherited PATH worth relying on, and every other command here is an
        # absolute store path for the same reason.
        attempt=0
        while [ "$attempt" -lt 60 ]; do
          if ${pkgs.systemd}/bin/busctl --user call \
              org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell \
              evaluateScript s "$script" >/dev/null; then
            exit 0
          fi
          attempt=$((attempt + 1))
          ${pkgs.coreutils}/bin/sleep 2
        done

        echo "plasmashell did not answer on D-Bus within 120s" >&2
        exit 1
      '';
    in
    {
      config = lib.mkIf isKde {
        home.packages = [ self.packages.${pkgs.system}.linver ];

        # --- GTK ----------------------------------------------------------
        # AeroThemePlasma covers Qt/Plasma; this is the half of the system
        # that doesn't read kdeglobals.
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

        # The libadwaita half of the line above: GTK4 apps ignore
        # gtk-application-prefer-dark-theme and read this instead (see the
        # long note in modules/desktop.nix). Without it an Aero-themed Plasma
        # session still handed EasyEffects and friends a dark stylesheet.
        #
        # The key is user-wide, not per-session, so on these hosts it reaches
        # the Hyprland session too; modules/hyprland.nix scopes it back for
        # the duration of that session, exactly as it already does for the
        # wallpaper-derived GTK colours.
        dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-light";

        # The Aero cursor for GTK/X apps. Plasma's own cursor is set by the
        # setup wizard; this is again the half that doesn't read kcminputrc.
        home.pointerCursor = {
          enable = true;
          package = atp.cursors;
          name = "aero-drop";
          size = 30;
          gtk.enable = true;
        };

        # --- Launcher shortcuts (declarative drop-ins) ----------------------
        home.file = lib.mapAttrs' (
          id: l:
          lib.nameValuePair ".local/share/kglobalaccel/launch-${id}.desktop" {
            text = ''
              [Desktop Entry]
              Type=Application
              Name=${l.name}
              Exec=${l.exec}
              X-KDE-Shortcuts=${l.key}
            '';
          }
        ) launchers;

        # --- Dolphin's default view mode ------------------------------------
        # Explorer opens folders in Details view; Dolphin opens them in a grid
        # of 96px icons, which is the loudest thing left saying "not Windows".
        #
        # This one setting can't come from /etc/xdg like the rest of dolphinrc:
        # view properties live in a .directory file that Dolphin opens by
        # absolute path, and KConfig doesn't cascade a path it was handed. So it
        # gets seeded instead of managed -- written once if absent, never
        # touched again. Switch Dolphin to Icons view and it stays switched,
        # which is the whole point of not making this a home.file.
        home.activation.kdeDolphinView = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          viewProps="${config.xdg.dataHome}/dolphin/view_properties/global/.directory"
          if [ ! -e "$viewProps" ] && [ -z "''${DRY_RUN:-}" ]; then
            verboseEcho "Seeding Dolphin's default view properties"
            mkdir -p "$(dirname "$viewProps")"
            # Dated now, not at build time: Dolphin discards view properties
            # older than dolphinrc's ViewPropsTimestamp, which the setup wizard
            # stamps on first login.
            {
              cat ${dolphinViewProps}
              ${pkgs.coreutils}/bin/date '+Timestamp=%Y,%-m,%-d,%-H,%-M,%-S.000'
            } > "$viewProps"
          fi
        '';

        # --- KWin/kglobalacceld shortcuts -----------------------------------
        # kglobalshortcutsrc entries are "shortcuts,defaults,friendlyName" and
        # kglobalacceld drops any entry that isn't exactly those three fields
        # (Component::loadSettings), so both trailing fields are read back and
        # written out again rather than invented. Field 2 in particular is
        # KWin's own default, which is what the "Reset to Defaults" button in
        # System Settings restores -- clobbering it would quietly break that.
        #
        # The declared binding is *prepended* to KDE's defaults rather than
        # replacing them, so Meta+Alt+Left still moves focus and Meta+Left
        # still tiles. Idempotent: the new value is always derived from field
        # 2, never from the previous run's field 1.
        home.activation.kdeShortcuts = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          if [ -z "''${DRY_RUN:-}" ]; then
            verboseEcho "Applying KDE global shortcuts (AeroSpace parity)"

            tab="$(printf '\t')"
            kread=${kconfig}/bin/kreadconfig6
            kwrite=${kconfig}/bin/kwriteconfig6

            setShortcut() {
              action="$1"
              want="$2"
              current="$($kread --file ${shortcutsFile} --group kwin --key "$action" || true)"
              # cut -f3- keeps a friendly name that contains a comma intact;
              # KDE doesn't ship any, but the entry would be dropped if we
              # split it into four fields.
              defaults="$(printf '%s' "$current" | cut -d, -f2)"
              friendly="$(printf '%s' "$current" | cut -d, -f3-)"

              merged="$want"
              if [ -n "$defaults" ] && [ "$defaults" != none ]; then
                old_ifs="$IFS"
                IFS="$tab"
                for key in $defaults; do
                  if [ -n "$key" ] && [ "$key" != "$want" ]; then
                    merged="$merged$tab$key"
                  fi
                done
                IFS="$old_ifs"
              fi

              $kwrite --file ${shortcutsFile} --group kwin --key "$action" \
                "$merged,''${defaults:-none},$friendly"
            }

            # Same three-field shape, but field 1 becomes the literal "none"
            # (kglobalacceld's spelling for "unbound"). Fields 2 and 3 are read
            # back and rewritten so "Reset to Defaults" still restores the key.
            # A missing entry is left alone: kglobalacceld hasn't written that
            # component's defaults yet, and inventing an entry with an empty
            # friendly name is worse than picking it up on the next activation.
            clearShortcut() {
              component="$1"
              action="$2"
              current="$($kread --file ${shortcutsFile} --group "$component" --key "$action" || true)"
              [ -n "$current" ] || return 0
              defaults="$(printf '%s' "$current" | cut -d, -f2)"
              friendly="$(printf '%s' "$current" | cut -d, -f3-)"

              $kwrite --file ${shortcutsFile} --group "$component" --key "$action" \
                "none,''${defaults:-none},$friendly"
            }

          ${setShortcutCalls}

          ${clearShortcutCalls}

            # The workspace keys above address nine virtual desktops, and KDE
            # ships with one -- without this most of them would be dead keys.
            # Only Number and Rows are set: KWin generates the per-desktop
            # Id_N uuids itself for any it finds missing (VirtualDesktopManager::load).
            $kwrite --file ${kwinrcFile} --group Desktops --key Number ${toString desktopCount}
            $kwrite --file ${kwinrcFile} --group Desktops --key Rows ${toString desktopRows}
          fi
        '';

        # --- Linver's KWin window rule --------------------------------------
        # The real winver has a close button and nothing else. KWin decides
        # which caption buttons a window gets from whether the window is
        # minimizable, so the dialog needs a window rule forcing that off.
        #
        # An activation script, for the same reason as the shortcuts above:
        # kwinrulesrc is owned and rewritten by KWin and the System Settings
        # rules editor, and the [General] rules key is a single comma-separated
        # list -- a home value shadows an /etc/xdg one wholesale, so the
        # cascade trick used for dolphinrc and ksmserverrc cannot add one entry
        # to a list. Editing in place with kwriteconfig6 is what the rules KCM
        # itself does.
        home.activation.kdeLinverWindowRule = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          if [ -z "''${DRY_RUN:-}" ]; then
            verboseEcho "Applying the Linver KWin window rule"

            kread=${kconfig}/bin/kreadconfig6
            kwrite=${kconfig}/bin/kwriteconfig6

            # The rule body. Rewritten every activation so changes here land,
            # which is safe precisely because the uuid is fixed.
            #   minimizerule=2  -- 2 is KWin's "Force" rule type, and the
            #     absent `minimize` key reads back as false, so the window is
            #     forced non-minimizable and loses the button.
            #   wmclassmatch=1  -- 1 is "Exact Match", against the
            #     StartupWMClass set on the desktop entry in the package above.
            $kwrite --file ${kwinrulesFile} --group ${linverRuleUuid} --key Description ${linverRuleDescription}
            $kwrite --file ${kwinrulesFile} --group ${linverRuleUuid} --key clientmachine localhost
            $kwrite --file ${kwinrulesFile} --group ${linverRuleUuid} --key minimizerule 2
            $kwrite --file ${kwinrulesFile} --group ${linverRuleUuid} --key wmclass linver
            $kwrite --file ${kwinrulesFile} --group ${linverRuleUuid} --key wmclassmatch 1

            # [General] rules is the ordered list of active rule groups and
            # count is its length. Append the uuid only if it isn't already
            # there; the commas around both sides stop a substring from
            # matching a longer uuid.
            rules="$($kread --file ${kwinrulesFile} --group General --key rules || true)"
            case ",$rules," in
              *,${linverRuleUuid},*) ;;
              *)
                if [ -n "$rules" ]; then
                  rules="$rules,${linverRuleUuid}"
                else
                  rules="${linverRuleUuid}"
                fi
                ;;
            esac

            # count is derived from the list rather than incremented, so a
            # count that has drifted out of step with rules gets corrected
            # instead of carried forward. KWin ignores any entry past count.
            count="$(printf '%s' "$rules" | tr ',' '\n' | grep -c .)"

            $kwrite --file ${kwinrulesFile} --group General --key rules "$rules"
            $kwrite --file ${kwinrulesFile} --group General --key count "$count"
          fi
        '';

        # --- Shell layout (wallpaper slideshow, panel visibility) ------------
        # Skipped entirely when both knobs are off: an empty script would make
        # plasmashell evaluate nothing 60 times over.
        systemd.user.services = lib.mkIf (shellScript != "") {
          kde-plasma-shell-layout = {
            Unit = {
              Description = "Apply declarative Plasma shell layout (wallpaper, panel visibility)";
              PartOf = [ "graphical-session.target" ];
              After = [ "graphical-session.target" ];
            };
            Service = {
              Type = "oneshot";
              ExecStart = "${applyShellLayout}";
            };
            Install.WantedBy = [ "graphical-session.target" ];
          };
        };
      };
    };
}
