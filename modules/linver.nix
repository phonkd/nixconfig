# Linver -- wackyideas' clone of Windows' `winver` dialog, from the same
# author as AeroThemePlasma (modules/aerothemeplasma.nix). Upstream calls it
# out as the intended companion to ATP, and it is the last obvious "not
# Windows" tell left in the rice: the About box.
#
# https://gitgud.io/wackyideas/linver
#
# Upstream's install path is `sh install.sh` (qmake6 + `sudo make install`
# into /usr/bin) and `sh add_rule.sh` (a KWin rule bolted into
# ~/.config/kwinrulesrc with a freshly generated uuid). Neither is usable as
# written here -- the first writes outside the store, the second is not
# idempotent -- so both halves are rebuilt below: a qmake derivation and an
# activation script keyed on a fixed uuid.
{ self, ... }:
{
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

  # Self-gating on KDE exactly like modules/aerothemeplasma.nix and
  # modules/kde-shortcuts.nix: imported from the gui-nixos bundle, inert on a
  # non-KDE desktop.
  flake.homeModules.linver =
    {
      config,
      lib,
      pkgs,
      osConfig ? null,
      ...
    }:
    let
      isKde = osConfig == null || (osConfig.noughty.host.desktop or null) == "kde";

      # Fixed rather than generated. Upstream's add_rule.sh calls uuidgen, so
      # re-running it would append a second identical rule; a constant makes
      # the activation below idempotent and lets an edit here rewrite the
      # existing rule in place instead of stacking a new one.
      ruleUuid = "b1f5c2a7-3d94-4e18-9c6b-7a0e2f8d41c3";
      ruleDescription = "LINVER_RULES";

      kconfig = pkgs.kdePackages.kconfig;
      rulesFile = "${config.xdg.configHome}/kwinrulesrc";
    in
    {
      config = lib.mkIf isKde {
        home.packages = [ self.packages.${pkgs.system}.linver ];

        # The real winver has a close button and nothing else. KWin decides
        # which caption buttons a window gets from whether the window is
        # minimizable, so the dialog needs a window rule forcing that off.
        #
        # An activation script, for the reason spelled out at length in
        # modules/kde-shortcuts.nix: kwinrulesrc is owned and rewritten by
        # KWin and the System Settings rules editor, and the [General] rules
        # key is a single comma-separated list -- a home value shadows an
        # /etc/xdg one wholesale, so the cascade trick used for dolphinrc and
        # ksmserverrc cannot add one entry to a list. Editing in place with
        # kwriteconfig6 is what the rules KCM itself does.
        home.activation.linverWindowRule = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
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
            #     StartupWMClass set on the desktop entry above.
            $kwrite --file ${rulesFile} --group ${ruleUuid} --key Description ${ruleDescription}
            $kwrite --file ${rulesFile} --group ${ruleUuid} --key clientmachine localhost
            $kwrite --file ${rulesFile} --group ${ruleUuid} --key minimizerule 2
            $kwrite --file ${rulesFile} --group ${ruleUuid} --key wmclass linver
            $kwrite --file ${rulesFile} --group ${ruleUuid} --key wmclassmatch 1

            # [General] rules is the ordered list of active rule groups and
            # count is its length. Append the uuid only if it isn't already
            # there; the commas around both sides stop a substring from
            # matching a longer uuid.
            rules="$($kread --file ${rulesFile} --group General --key rules || true)"
            case ",$rules," in
              *,${ruleUuid},*) ;;
              *)
                if [ -n "$rules" ]; then
                  rules="$rules,${ruleUuid}"
                else
                  rules="${ruleUuid}"
                fi
                ;;
            esac

            # count is derived from the list rather than incremented, so a
            # count that has drifted out of step with rules gets corrected
            # instead of carried forward. KWin ignores any entry past count.
            count="$(printf '%s' "$rules" | tr ',' '\n' | grep -c .)"

            $kwrite --file ${rulesFile} --group General --key rules "$rules"
            $kwrite --file ${rulesFile} --group General --key count "$count"
          fi
        '';
      };
    };
}
