# KDE global shortcuts, mirroring the AeroSpace bindings from the Mac
# (modules/aerospace.nix) so the same fingers do the same things on both.
# Alt here is what Option is there: Alt+H/J/K/L to move focus, Alt+Shift+…
# to throw the window, Alt+<letter> for a workspace, Alt+B/V/M to launch.
#
# Two mechanisms, because KDE stores the two halves in different places and
# only one of them can be handed a file from the nix store:
#
#   * App launchers are *.desktop drop-ins in
#     $XDG_DATA_DIRS/kglobalaccel/, each carrying X-KDE-Shortcuts. This is a
#     first-class kglobalacceld feature (GlobalShortcutsRegistry::loadShortcuts
#     scans that directory and registers a "_launch" action per file), and it
#     is exactly how Dolphin gets Meta+E. Being drop-ins they can be plain
#     home.file symlinks into the store -- nothing ever writes back to them,
#     so this half is genuinely declarative. Note NoDisplay=true would make
#     kglobalacceld skip the file, so these entries are "visible"; they live
#     outside share/applications/ and so still never reach the app menu.
#
#   * KWin's own actions (focus, quick tile, virtual desktops, fullscreen)
#     have no such drop-in path: their bindings live in
#     ~/.config/kglobalshortcutsrc, which kglobalacceld owns and rewrites.
#     /etc/xdg cascade is no help either -- kglobalacceld writes every action
#     it knows into the *home* file on first run, and a home value shadows the
#     system one key by key. So this half is an activation script that edits
#     the home file in place with kwriteconfig6, the same way plasma-manager
#     does it, and it lands at the next login.
#
# Deliberately not mapped, because KDE has no equivalent or the key is worth
# more as its KDE default: alt-comma/alt-shift-comma (tiling layouts),
# alt-slash (join-with), alt-equal (resize), alt-tab (KDE's window switcher,
# vs AeroSpace's workspace-back-and-forth), alt-space (KRunner, vs float
# toggle) and the whole `service` mode.
#
# Caveat worth knowing when editing the table: on Linux, Alt+<letter> is also
# how Qt/GTK apps reach their menu mnemonics (Alt+F for File, Alt+E for Edit,
# …), and a global shortcut wins over the focused app. macOS has no such
# convention, which is why this collision doesn't exist on the AeroSpace side.
# `mod` below is the single knob: set it to "Meta" and the entire set moves
# off Alt in one go.
{ inputs, ... }:
{
  # Self-gating on KDE the same way modules/aerothemeplasma.nix is: imported
  # from the gui-nixos bundle, does nothing on a non-KDE desktop.
  flake.homeModules.kde-shortcuts =
    {
      config,
      lib,
      pkgs,
      osConfig ? null,
      ...
    }:
    let
      isKde = osConfig == null || (osConfig.noughty.host.desktop or null) == "kde";

      # The modifier the whole set hangs off. "Alt" = AeroSpace's Option.
      mod = "Alt";

      # AeroSpace's workspace letters, in AeroSpace's own order (built-in
      # display, then external 2, then external 3), onto KDE virtual desktops
      # 1..9. The Mac spreads these across three monitors; a single-screen
      # KDE host just gets nine desktops in a 3x3 grid.
      workspaceKeys = [
        "Q"
        "W"
        "E"
        "A"
        "S"
        "D"
        "U"
        "I"
        "O"
      ];
      desktopCount = builtins.length workspaceKeys;
      desktopRows = 3;

      perDesktop =
        prefix: action:
        lib.listToAttrs (
          lib.imap1 (i: key: lib.nameValuePair "${action} ${toString i}" "${mod}+${prefix}${key}") workspaceKeys
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

      kconfig = pkgs.kdePackages.kconfig;
      shortcutsFile = "${config.xdg.configHome}/kglobalshortcutsrc";
      kwinrcFile = "${config.xdg.configHome}/kwinrc";

      setShortcutCalls = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          action: keys: "  setShortcut ${lib.escapeShellArg action} ${lib.escapeShellArg keys}"
        ) kwinShortcuts
      );
    in
    {
      config = lib.mkIf isKde {
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

          ${setShortcutCalls}

            # The workspace keys above address nine virtual desktops, and KDE
            # ships with one -- without this most of them would be dead keys.
            # Only Number and Rows are set: KWin generates the per-desktop
            # Id_N uuids itself for any it finds missing (VirtualDesktopManager::load).
            $kwrite --file ${kwinrcFile} --group Desktops --key Number ${toString desktopCount}
            $kwrite --file ${kwinrcFile} --group Desktops --key Rows ${toString desktopRows}
          fi
        '';
      };
    };
}
