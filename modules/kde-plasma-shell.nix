# Declarative bits of the Plasma shell *layout* -- the wallpaper slideshow and
# panel visibility -- applied through plasmashell's own scripting API.
#
# Why not a config file, and why not plasma-manager:
#
#   * plasma-manager is deliberately absent from this repo. See the long note
#     in modules/aerothemeplasma.nix: AeroThemePlasma configures Plasma from a
#     first-login wizard (atpootb) and upstream calls out plasma-manager as the
#     thing that fights it. Two writers, one kdeglobals.
#
#   * Writing the appletsrc directly is worse than it looks. The shell package
#     names the file, and AeroThemePlasma ships its *own* shell -- the live
#     file on a KDE host here is `plasma-io.gitgud.wackyideas.desktop-appletsrc`,
#     not `plasma-org.kde.plasma.desktop-appletsrc` (which sits nearly empty).
#     Hardcoding either filename breaks the moment you pick the other session
#     at the login screen. On top of that the containment numbers are runtime
#     state -- the desktop happens to be [Containments][1] and the panel
#     [Containments][2] today -- so a static file would have to guess them.
#
#   * The scripting API has neither problem. `desktops()` and `panels()` are
#     resolved by the running shell against whatever containments it actually
#     has, and plasmashell writes its own config afterwards. It is the same
#     interface `plasma-apply-wallpaperimage` uses. Verified against aeroshell:
#     the patched binary still owns the `org.kde.plasmashell` bus name.
#
# The cost of that choice is that this needs a *running* shell, so it is a
# systemd user service hooked to graphical-session.target rather than an HM
# activation script. It re-applies at every login, which is the point: these
# are declared settings, not seeded defaults like the Dolphin view properties
# in modules/aerothemeplasma.nix. Change them here, not in System Settings --
# a change made in the GUI survives until the next login and then goes back.
{ ... }:
{
  # NixOS half: only declares the knobs, so a host module can set them.
  # Lives in modules/builder.nix's alwaysImport for exactly that reason --
  # blac.nix cannot set an option nothing has declared.
  flake.nixosModules.kde-plasma-shell =
    { lib, ... }:
    {
      options.noughty.kde = {
        wallpaperDir = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          # The slideshow plugin walks subdirectories itself, so pointing at
          # the top of a tree is enough -- ImageWallpaper::findAll keeps a
          # visit queue and appends every directory it meets. There is no
          # "recursive" key to set; it is the only behaviour it has.
          default = "/home/phonkd/Downloads/Phonkds Wallpapers-20260829_215113";
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
    };

  # Home half: does the work. Self-gates on KDE the same way
  # modules/kde-shortcuts.nix and modules/aerothemeplasma.nix do -- imported
  # from the gui-nixos bundle, inert on a non-KDE desktop.
  flake.homeModules.kde-plasma-shell =
    {
      lib,
      pkgs,
      osConfig ? null,
      ...
    }:
    let
      isKde = osConfig == null || (osConfig.noughty.host.desktop or null) == "kde";
      cfg = osConfig.noughty.kde or { };
      wallpaperDir = cfg.wallpaperDir or null;
      wallpaperInterval = cfg.wallpaperInterval or 300;
      panelAutoHide = cfg.panelAutoHide or false;

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
      script = wallpaperJs + panelJs;

      apply = pkgs.writeShellScript "kde-plasma-shell-layout" ''
        set -u
        script=${lib.escapeShellArg script}

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
      config = lib.mkIf (isKde && script != "") {
        systemd.user.services.kde-plasma-shell-layout = {
          Unit = {
            Description = "Apply declarative Plasma shell layout (wallpaper, panel visibility)";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${apply}";
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };
      };
    };
}
