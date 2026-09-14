# Hyprland: a second, fully declarative session on the KDE desktops (blac,
# g14). On z14 there is no KDE at all (`desktop = "hyprland"` in
# lib/registry.nix) and this is the *only* session -- modules/desktop.nix's
# plain-SDDM branch is what gives it a login screen instead.
#
# On blac/g14 this is *additive*. KDE is untouched -- SDDM simply grows a
# "Hyprland" entry next to "Plasma", and every systemd user unit below is
# bound to `hyprland-session.target`, which only Hyprland ever starts. Log in
# to Plasma and nothing here runs. Back it out by dropping the "hyprland" host
# tag in lib/registry.nix.
#
# Three things are mirrored from the Plasma side on purpose, because the point
# is that the two sessions feel the same:
#
#   * Keybindings, from modules/kde.nix -- which in turn mirrors
#     AeroSpace on the Mac. Alt is Option. See the table further down.
#   * A rotating wallpaper, like modules/kde.nix's Plasma slideshow.
#   * ...and the new part: the colour scheme is re-derived from each wallpaper
#     as it changes, and pushed into the shell, the compositor, the launcher,
#     the lock screen and GTK.
#
# The shell is Caelestia (programs.caelestia below), adopted in place of a
# hand-written Quickshell bar -- see plans/caelestia-shell.md. It is a whole
# desktop rather than a bar, so it also owns notifications now; mako is off,
# and the note at services.mako explains why that is a choice rather than an
# oversight.
#
# Why every consumer repaints itself without a reload hack
# --------------------------------------------------------
# The usual way to repaint a shell from a wallpaper is to signal it, or kill
# and respawn it, after rewriting its colours. None of that happens here.
# Caelestia reads its scheme through a FileView that watches the file and
# rebinds, so QML property bindings do the repainting and there is nothing to
# restart -- which is exactly why matugen can keep owning colour generation
# instead of handing it to `caelestia scheme set`. See `caelestiaTemplate`.
#
# Hyprland has a documented reload command (`hyprctl reload`); rofi and
# hyprlock read their config at launch. Every consumer is repainted through a
# first-class feature of that consumer.
#
# Colour generation is matugen (Material You extraction + templating). Two of
# its behaviours are not obvious and were found by running it, not by reading:
#
#   * matugen 4 PROMPTS. Given an image it offers several candidate source
#     colours and waits for an arrow-key pick, so in a systemd unit it dies
#     with "Failed to get source color / IO error: not a terminal".
#     `--source-color-index 0` takes the top candidate and makes it silent.
#   * matugen 4 no longer sets wallpapers. The `wallpaper_tool` key older
#     guides mention is gone from the binary, hence awww (swww) below.
#
# Home Manager's files vs. matugen's files
# ----------------------------------------
# These must not overlap: an HM-managed path is a read-only symlink into the
# store, and matugen writing one would fail every rotation. So matugen only
# ever owns a separate `colors.*` file, which an HM-owned file pulls in by
# absolute path (relative imports would resolve against /nix/store).
#
# GTK is where that would otherwise bite: HM generates gtk-{3,4}.0/gtk.css
# itself as soon as `gtk.gtk3.extraCss` / `gtk.gtk4.theme` are set, so those are
# paths it may claim. (As things stand `gtk.gtk4.theme` is null on these hosts
# -- `gtk.theme` in modules/desktop.nix is a different option -- so today HM
# would not fight us for it. Routing the colours through
# `gtk.gtk{3,4}.extraCss` anyway means the file stays HM's and only the colours
# are ours, which stops being luck the moment someone sets a GTK4 theme.)
#
# The second GTK problem is scope, and it is not hypothetical: gtk.css is
# *user-wide*, while everything else here is per-session. These hosts also run
# Plasma, with a deliberate Windows 7 GTK theme from modules/kde.nix. See
# `clearGtkColors` below for how the wallpaper colours are kept out of it.
{
  self,
  inputs,
  ...
}:
{
  # ---------------------------------------------------------------------------
  # NixOS half: the knobs, the compositor, the fonts. Self-gates on the
  # "hyprland" host tag, so it is safe to sit in modules/builder.nix's
  # alwaysImport or to be named from a registry entry's extraModules.
  # ---------------------------------------------------------------------------
  flake.nixosModules.hyprland =
    {
      config,
      pkgs,
      lib,
      noughtyLib,
      ...
    }:
    let
      enabled = noughtyLib.hostHasTag "hyprland";
    in
    {
      options.noughty.hyprland = {
        wallpaperDir = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          # Same tree the Plasma slideshow uses (noughty.kde.wallpaperDir).
          # Deliberately a separate option rather than a reference to the KDE
          # one: the two sessions should be able to disagree, and this module
          # must not break if the KDE module is renamed or reshaped.
          # Searched recursively, like Plasma's ImageWallpaper::findAll.
          default = "/home/phonkd/Downloads/Walls";
          description = ''
            Directory of wallpapers, searched recursively. Each rotation picks
            one at random and re-derives the whole colour scheme from it.
            Null disables the wallpaper/theming timer entirely.
          '';
        };

        wallpaperInterval = lib.mkOption {
          type = lib.types.ints.positive;
          # Matches noughty.kde.wallpaperInterval. As there, the reason the
          # rotation exists is OLED burn-in, not variety.
          default = 300;
          description = "Seconds between wallpaper (and colour scheme) changes.";
        };

        scale = lib.mkOption {
          type = lib.types.str;
          # 1 = 100%. Deliberately not "auto": Hyprland's auto-scaling picks a
          # fractional factor from the panel's DPI (1.25 or 1.5 on these
          # laptops), and fractional scaling on Wayland costs sharpness in every
          # XWayland app. A string rather than a float so "auto" and "1.25" are
          # both expressible without a type change.
          default = "1";
          description = ''
            Output scale factor for every monitor, as Hyprland's `monitor=`
            fourth field. "1" is 100%; "auto" hands the choice back to Hyprland.
          '';
        };

        layout = lib.mkOption {
          type = lib.types.enum [
            "dwindle"
            "hy3"
          ];
          # hy3 for the session as a whole rather than per host: all three
          # hosts carrying the "hyprland" tag (blac, g14, z14) run it, so three
          # identical host-module overrides would say the same thing three
          # times. The option stays because it is the rollback -- a host that
          # misbehaves sets `noughty.hyprland.layout = "dwindle"` and is back
          # on stock Hyprland, which is byte-for-byte the config it had before
          # hy3 existed.
          #
          # The dwindle branch is NOT vestigial. It carries Hyprland's *native*
          # tabbed groups (see the `group` block in the home half), which cover
          # AeroSpace's accordion with no plugin at all. hy3 is the bigger step
          # -- a real i3 tree, where a tab group is one node type among several
          # and splits are explicit rather than inferred from the focused
          # window's aspect ratio. If that tree turns out not to earn its keep,
          # flipping this default back is the whole retreat.
          default = "hy3";
          description = ''
            Tiling layout for the Hyprland session.

            "dwindle" is Hyprland's built-in automatic halving, plus its native
            tabbed/stacked groups on alt-comma.

            "hy3" loads the hy3 compositor plugin for i3/sway-style explicit
            split containers and tabbed groups. It moves the focus, move,
            close, send-to-workspace and group keybinds onto hy3's own
            dispatchers, and replaces the native group configuration -- hy3
            manages its own tabs and Hyprland's groupbar is unused under it.
          '';
        };

        colorMode = lib.mkOption {
          type = lib.types.enum [
            "dark"
            "light"
          ];
          default = "dark";
          description = "Which Material You scheme matugen derives from the wallpaper.";
        };

        colorScheme = lib.mkOption {
          # matugen's own `--type` values.
          type = lib.types.str;
          default = "scheme-tonal-spot";
          description = ''
            matugen scheme algorithm (`matugen --type`). "scheme-tonal-spot" is
            matugen's default and the most muted; "scheme-vibrant" and
            "scheme-content" track the wallpaper's own colours more closely.
          '';
        };
      };

      config = lib.mkIf (enabled && config.noughty.host.is.nixosDesktop) {
        # The NixOS module is what makes Hyprland a *session*: it installs the
        # wayland-sessions desktop entry the login screen lists, wires the
        # portals, and sets the polkit/pam bits. Home Manager's module below
        # only writes config -- it is given `package = null` for exactly this
        # reason.
        programs.hyprland = {
          enable = true;
          # Deliberately off. withUWSM adds a *second* session entry,
          # "Hyprland (uwsm-managed)", whose whole job is to own the user's
          # systemd session: uwsm starts graphical-session.target and
          # wayland-wm@Hyprland.service itself. That collides head-on with the
          # Home Manager half below, which sets `systemd.enable = true` and so
          # appends its own exec-once that imports the environment and starts
          # hyprland-session.target -- the target every user service in this
          # module is PartOf/WantedBy. Two session managers racing for the same
          # target is why picking that entry gave a session that did not come
          # up. Only one of the two can own it, and HM's is the one the rest of
          # this module is written against, so uwsm goes. With this false the
          # login screen lists exactly one Hyprland, and it works.
          withUWSM = false;
          xwayland.enable = true;
        };

        # Screen locker. The PAM service is what lets hyprlock actually unlock;
        # without it the password is always rejected.
        programs.hyprlock.enable = true;
        security.pam.services.hyprlock = { };

        # Plasma brings its own polkit agent; a bare Hyprland session has none,
        # and without one every pkexec prompt (ProtonVPN, mounting, ...) fails
        # silently. Started from the session, not as a system service.
        security.polkit.enable = true;

        # Fonts. The KDE session gets its own from AeroThemePlasma's Segoe set,
        # which is a Windows 7 look and not what this session wants. These are
        # the ones the bar/rofi/kitty configs in this module actually name:
        #   * JetBrainsMono Nerd Font -- the bar's glyphs (the battery icons in
        #     shell.qml) are Nerd Font private-use codepoints, so without a
        #     patched font the bar is a row of tofu boxes.
        #   * Font Awesome -- the other glyph set these configs draw from.
        #   * Inter -- proportional UI font for rofi/GTK.
        #   * Noto + Noto Emoji + CJK -- fallback coverage, so a window title in
        #     Japanese or an emoji in a notification renders at all.
        fonts.packages = with pkgs; [
          nerd-fonts.jetbrains-mono
          nerd-fonts.symbols-only
          font-awesome
          inter
          noto-fonts
          noto-fonts-cjk-sans
          noto-fonts-color-emoji
        ];

        # Same wiring as flake.nixosModules.gui: `home-manager.users.phonkd` is
        # a submodule, so a second `imports` definition merges with the one the
        # gui bundle already sets rather than replacing it.
        home-manager.users.phonkd.imports = [ self.homeModules.hyprland ];
      };
    };

  # ---------------------------------------------------------------------------
  # Home half: the actual session. Self-gates the same way the KDE home modules
  # do -- on osConfig -- so it is inert if it is ever imported on a host without
  # the tag.
  # ---------------------------------------------------------------------------
  flake.homeModules.hyprland =
    {
      config,
      lib,
      pkgs,
      osConfig ? null,
      ...
    }:
    let
      hostTags = osConfig.noughty.host.tags or [ ];
      enabled = osConfig == null || builtins.elem "hyprland" hostTags;

      # True on the hosts that also run the KDE session (blac, g14). There
      # modules/kde.nix's home module owns `home.pointerCursor` and this one
      # must keep its hands off it; on a Hyprland-only host (z14) kde.nix is
      # inert and nothing sets a cursor at all unless this module does.
      kdeOwnsCursor = (osConfig.noughty.host.desktop or null) == "kde";
      cursorName = "Bibata-Modern-Classic";
      cursorSize = 24;

      cfg = osConfig.noughty.hyprland or { };
      wallpaperDir = cfg.wallpaperDir or null;
      wallpaperInterval = cfg.wallpaperInterval or 300;
      colorMode = cfg.colorMode or "dark";
      colorScheme = cfg.colorScheme or "scheme-tonal-spot";
      scale = cfg.scale or "1";

      layout = cfg.layout or "dwindle";
      hy3 = layout == "hy3";

      # The plugin .so. This is the same path Home Manager's own `plugins`
      # option would derive ($out/lib/lib<pname>.so), and hy3 ships exactly
      # that -- but that option is deliberately not used; see `exec-once`.
      #
      # It comes from nixpkgs, NOT from hy3's flake. That matters: hy3's README
      # tells you to add a `hy3` flake input with
      # `inputs.hyprland.follows = "hyprland"`, which here would build it
      # against this flake's `hyprland` input (Hyprland *master*) while the
      # session actually runs pkgs.hyprland. Hyprland refuses to load a plugin
      # built against a different commit, so that route yields a plugin that
      # silently never loads. pkgs.hyprlandPlugins.hy3 is built against
      # pkgs.hyprland by construction -- verified: the two share a store path
      # reference, and it substitutes from cache.nixos.org rather than building.
      hy3Plugin = "${pkgs.hyprlandPlugins.hy3}/lib/libhy3.so";

      # Absolute, like every other binary named from this config: `exec-once` is
      # run by the compositor, not by a login shell, so nothing guarantees the
      # user profile is on its PATH. (The matugen post_hook further down can say
      # a bare `hyprctl` only because it puts one on PATH itself.)
      hyprctl = "${pkgs.hyprland}/bin/hyprctl";

      # hy3 replaces the dispatchers that have to understand its tree. The
      # stock ones still exist under hy3 but operate on Hyprland's own notion
      # of layout, so leaving any of these unswapped makes the layout misbehave
      # in ways that look like bugs rather than misconfiguration.
      dispatch = name: if hy3 then "hy3:${name}" else name;

      # alt-shift-h/j/k/l is the one that does NOT follow the pattern above.
      # The dwindle side deliberately uses `movewindoworgroup` rather than
      # plain `movewindow`, so the same four keys also move windows in and out
      # of the native tab groups (see the bind's own comment). hy3 has no
      # `orgroup` variant -- `hy3:movewindow` is already tree-aware and does
      # the equivalent -- so the two spellings are named explicitly instead of
      # being derived, to keep `dispatch` from silently dropping the `orgroup`.
      moveWindowDispatch = if hy3 then "hy3:movewindow" else "movewindoworgroup";

      # Layout-specific settings, merged into `settings` below.
      #
      # Deliberately a plain `if`, not `lib.mkIf`: the Home Manager `settings`
      # option is a value type, not a submodule, so a nested mkIf is never
      # resolved -- it would reach toHyprconf as an attrset with
      # `_type = "if"` and be rendered into the config file verbatim.
      layoutSettings =
        if hy3 then
          {
            # Every key here is taken from the plugin binary's own option
            # strings (`strings libhy3.so | grep plugin:hy3`), not from the
            # README -- which is how the `radius`/`rounding` trap below was
            # caught.
            plugin.hy3 = {
              # Stacks on top of general:gaps_in (8), so deliberately smaller
              # than hy3's default of 10: otherwise every grouped node gains a
              # second, wider margin and reads as noticeably airier than the
              # same windows under dwindle.
              group_inset = 6;

              tabs = {
                height = 20;
                padding = 6;
                # `radius`, not `rounding` -- hy3 does not follow Hyprland's
                # own `decoration:rounding` spelling.
                radius = 6;
                border_width = 2;
                render_text = true;
                # Matches the native groupbar's font on the dwindle side, so
                # the two layouts' tab bars are the same object visually.
                text_font = "JetBrainsMono Nerd Font";
                text_height = 11;

                # `colors` is deliberately absent here, exactly as in `general`
                # and `group`: the tab palette is re-derived from the wallpaper
                # and arrives through the `source`d matugen file.
                #
                # This is a safety property, not just consistency. The obvious
                # alternative -- emit `$hy3TabActive` variables from matugen and
                # reference them from here -- breaks on a host where the seeding
                # activation finds no readable wallpaper: it writes an *empty*
                # colours file, and an undefined hyprlang variable is a hard
                # error ("failed to parse $hy3TabActive as a color"), verified
                # with --verify-config. With the keys living in the generated
                # file instead, an empty file simply means hy3 keeps its own
                # defaults and the session still comes up.
              };

              autotile = {
                # hy3 defaults this off, i.e. every split is manual. That is
                # strict i3 behaviour and a real step down from dwindle for
                # casual use, so it is on -- with triggers meaning "only
                # auto-split a node already big enough to be worth splitting".
                enable = true;
                trigger_width = 800;
                trigger_height = 500;
              };
            };
          }
        else
          {
            dwindle = {
              # No `pseudotile` here: Hyprland 0.55 dropped it as a config
              # option, and setting it is a hard error -- "config option
              # <dwindle:pseudotile> does not exist". It is absent from the
              # option list the compositor ships in
              # share/hypr/stubs/hl.meta.lua, which is the authoritative
              # list for this build. Pseudotiling itself is still there as
              # the `pseudo` dispatcher, if you want it on a key.
              preserve_split = true;
            };

            # -------------------------------------------------------------
            # Tabbed / stacked groups -- AeroSpace's accordion, in the one
            # place the Mac layout had something a plain dwindle tree does
            # not.
            #
            # On the Mac, alt-comma folds the focused container into an
            # accordion: the windows stop sharing the screen and take turns
            # in one tile. Hyprland's native groups are the same idea with
            # a tab bar on top -- which is i3's "tabbed", and with
            # `stacked` on, i3's "stacking". No plugin: hy3 would give the
            # full i3 tree (explicit split containers, groups holding
            # sub-splits), but it is an ABI-coupled plugin that has to be
            # rebuilt in lockstep with every Hyprland bump, and none of
            # what it adds beyond this is what the Mac layout does.
            #
            # Colours are deliberately absent here, exactly as in `general`
            # above: the groupbar palette is re-derived from the wallpaper
            # and arrives through the `source`d matugen file.
            group = {
              # Hyprland's default is ON, and it is the wrong default for a
              # layout meant to mirror AeroSpace: with auto_group on, every
              # window opened while a group has focus is silently swallowed
              # into that group. Grouping should only ever happen because
              # the keybind or a drag asked for it.
              auto_group = false;

              groupbar = {
                enabled = true;
                # `stacked` is deliberately NOT set here. It is the one
                # group option owned by the sourced groupbarMode file, so
                # that the toggle keybind can rewrite it; setting it here
                # too would win (hyprland.conf is parsed after its own
                # `source` lines) and pin the mode to whatever this says.
                #
                # The rest is sizing. Hyprland's defaults (14px bar, 8px
                # font) are tuned for a much tighter config than this one
                # -- 3px borders, 8/16 gaps, 12px rounding -- and a bar
                # that thin reads as a stripe rather than a tab.
                height = 20;
                font_family = "JetBrainsMono Nerd Font";
                font_size = 11;
              };
            };

            binds = {
              # What makes alt-h/j/k/l behave like AeroSpace inside an
              # accordion, and the reason this needs no extra "next tab"
              # key: with this on, movefocus cycles through the group's own
              # windows first and only leaves the group once it runs off
              # the end. Off (the default), focus skips straight past the
              # group's other tabs to the next tile, and the tabs are
              # reachable only with the mouse.
              movefocus_cycles_groupfirst = true;
            };
          };

      # Group / split bindings. alt-comma is AeroSpace's `layout accordion` and
      # keeps that meaning under both layouts -- only the machinery behind it
      # changes, so the muscle memory does not.
      #
      # hy3 adds the rest of the i3 tree, which the native groups have no
      # equivalent for. Key space is tight: ALT already owns H J K L F B V M,
      # COMMA, the six workspace letters (Q W E A S D) and the 1/2/3 number
      # row, which leaves C G N P R T U I O X Y Z. Letters rather than
      # AeroSpace's literal punctuation
      # (alt-slash "flip axis") -- on this ch/de_nodeadkeys keyboard `/` is
      # Shift+7, and the module already carries a note at the screenshot binds
      # about keysym-vs-`code:` spelling biting exactly that way. COMMA is
      # safe because it is an unshifted key on this layout; `/` is not.
      groupBinds =
        if hy3 then
          [
            # Fold the focused node into a tab group, and back out again.
            "${mod}, COMMA, hy3:changegroup, toggletab"
            # alt-shift-comma was "tabbed vs stacked" under the native
            # groupbar. hy3 has no stacked mode, so the key is reused for the
            # other half of AeroSpace's layout pair: flip the split axis
            # (AeroSpace's alt-slash).
            "${mod} SHIFT, COMMA, hy3:changegroup, opposite"
            # i3's `split h` / `split v` -- the explicit split containers that
            # are the whole reason for running hy3 over dwindle.
            "${mod}, N, hy3:makegroup, h"
            "${mod} SHIFT, N, hy3:makegroup, v"
            # i3's `focus parent` / `focus child`: walk up and down the tree
            # so a whole container can be moved or tabbed, not just a window.
            "${mod}, P, hy3:changefocus, raise"
            "${mod} SHIFT, P, hy3:changefocus, lower"
            # Cycle tabs within a group. Under dwindle this needs no key --
            # binds:movefocus_cycles_groupfirst puts it on alt-h/l -- but hy3
            # has no equivalent option, so the tabs get their own key.
            "SUPER, Tab, hy3:focustab, r"
            "SUPER SHIFT, Tab, hy3:focustab, l"
            # Temporarily grow a node over its siblings, and back.
            "${mod}, X, hy3:expand, expand"
            "${mod} SHIFT, X, hy3:expand, base"
          ]
        else
          [
            # alt-comma = group / ungroup, mirroring AeroSpace's
            # `layout accordion` on the same key. Tab bar appears, the
            # windows take turns in one tile, alt-h/l walks the tabs
            # (see binds:movefocus_cycles_groupfirst above).
            "${mod}, COMMA, togglegroup,"
            # alt-shift-comma = flip that bar between tabbed and stacked.
            # An exec rather than a dispatcher because Hyprland has no
            # dispatcher for it -- see toggleGroupbarMode for why the
            # mode has to be written to a file as well as set live.
            "${mod} SHIFT, COMMA, exec, ${toggleGroupbarMode}"
          ];

      cfgHome = config.xdg.configHome;

      # -- Keybindings -------------------------------------------------------
      #
      # Straight from modules/kde.nix, which is itself AeroSpace's
      # Option-key layout with Option spelled Alt. `mod` is the knob for the
      # window-management half: set it to SUPER and focus, movement, grouping,
      # fullscreen and the launchers all move off Alt at once, exactly like its
      # KDE counterpart.
      #
      # It is no longer *every* bind, and the workspace keys are the exception
      # -- they sit on SUPER unconditionally now, for the reasons written out
      # at workspaceKeys below. Flipping `mod` to SUPER would collide them with
      # the window-management set rather than move them.
      #
      # The Alt-vs-menu-mnemonics caveat from the KDE module applies here too:
      # on Linux Alt+<letter> is also how Qt/GTK apps reach their menu bars,
      # and a compositor bind wins over the focused app.
      mod = "ALT";

      # The whole number row, 1..9, onto workspaces 1..9 -- and on SUPER, not
      # on `mod`. This is the one part of the keymap that does not follow the
      # knob above, so it is worth saying why out loud.
      #
      # The scheme this replaces put workspaces on three keyboard *rows*
      # (123/QWE/ASD) as a 3x3 grid under Alt. It read well and it cost the
      # number row's Alt bindings, which is what made it untenable: the
      # screenshot keys wanted Alt+Shift+1/2/3, and under the grid that chord
      # was already send-to-workspace. Moving the workspaces one modifier over
      # frees Alt's digits outright rather than carving an exception out of
      # them, and a straight 1..9 needs no mnemonic -- the workspace number is
      # the key you press.
      #
      # Nothing collides on SUPER. Its letters are the ones spoken for (Q close,
      # W wallpaper, E files, D launcher, and the rest below), and this scheme
      # no longer uses letters at all; SUPER+1..9 and SUPER+Shift+1..9 were
      # both free, the latter only because the screenshot binds vacated it in
      # the same change.
      #
      # modules/kde.nix and modules/aerospace.nix both still run the older
      # layouts -- KDE the 123/QWE/ASD grid, the Mac the all-letters QWE/ASD/UIO
      # set that AeroSpace's binder forces. The three sessions agreeing was
      # always a nicety rather than a constraint, and this one is a Hyprland
      # keyboard decision.
      #
      # Spelled `code:` rather than `1`..`9`, and that is not cosmetic. Every
      # one of these keys also carries a SHIFT bind (send-to-workspace), and
      # this is a ch/de_nodeadkeys keyboard where Shift+1 emits `plus` -- the
      # exact trap the screenshot binds carry a note about, and a dead
      # send-to-workspace key would fail silently. `code:` matches the physical
      # key, so it is immune both to that and to any later layout change. The
      # values are the X11 keycodes for AE01..AE09 (evdev code + 8), read off
      # xkb's own keycodes/evdev table rather than remembered.
      workspaceKeys = [
        "code:10"
        "code:11"
        "code:12"
        "code:13"
        "code:14"
        "code:15"
        "code:16"
        "code:17"
        "code:18"
      ];

      workspaceBinds = lib.flatten (
        lib.imap1 (i: key: [
          "SUPER, ${key}, workspace, ${toString i}"
          "SUPER SHIFT, ${key}, ${dispatch "movetoworkspace"}, ${toString i}"
        ]) workspaceKeys
      );

      # Launchers. Absolute store paths, for the same reason the KDE half uses
      # them: `exec` is run by the compositor, not by a login shell, so nothing
      # guarantees the user profile is on its PATH.
      zen = "${inputs.zen-browser.packages.${pkgs.system}.default}/bin/zen";
      kitty = "${config.programs.kitty.package}/bin/kitty";

      # The two audio helpers, from their own files in modules/hyprland/.
      # Both are perSystem packages rather than `writeShellScript` inlined into
      # a bind, because both are far too much logic for a bind line and both
      # are worth being able to run by hand -- `nix run .#hypr-sink-switcher`
      # -- without bringing up a session. import-tree picks their files up
      # automatically; there is no import list to add them to.
      streamVolume = "${self.packages.${pkgs.system}.hypr-stream-volume}/bin/hypr-stream-volume";
      sinkSwitcher = "${self.packages.${pkgs.system}.hypr-sink-switcher}/bin/hypr-sink-switcher";

      # -- Screenshots: capture, then annotate -------------------------------
      #
      # grimblast keeps doing the capturing -- the targets, the freeze, the
      # window snapping -- and satty is bolted on behind it as the annotation
      # step: arrows, boxes, blur, text, highlight and auto-numbered markers
      # drawn over the capture before it goes anywhere. Tool keys inside
      # satty, since they are nowhere in its --help: z arrow, r rectangle,
      # e ellipse, i line, b brush, t text, g highlight, m numbered marker,
      # u blur, c crop, p pointer. Enter commits, Escape discards.
      #
      # The seam is grimblast's own `edit` action rather than a pipe. `edit`
      # writes the capture to a temp file and runs $GRIMBLAST_EDITOR with that
      # path as its final argument, which is exactly the hook this wants. The
      # obvious alternative -- `grimblast save area - | satty --filename -` --
      # is a trap: grimblast's save() ends in `echo "$file"`, so against a `-`
      # target it drops a stray "-\n" onto stdout directly behind the PNG's
      # IEND chunk. Decoders generally skip trailing bytes; nothing promises
      # they must, and a temp file costs nothing.
      #
      # satty then does *both* halves of what `copysave` used to do. The
      # action list is order-sensitive in a way its --help does not admit:
      # satty raises its early-exit flag after running the first action and
      # checks it immediately, so `--early-exit` next to a multi-action list
      # copies to the clipboard, logs "Early exit, ignoring further actions."
      # and never writes the file. Hence no `--early-exit`, and a trailing
      # `exit` inside the list, which runs all three in order.
      #
      # --copy-command rather than satty's native GTK clipboard: a Wayland
      # clipboard offer dies with the process that made it and satty exits
      # straight after copying. wl-copy forks a small daemon that keeps
      # serving the selection, which is also what grimblast does today.
      #
      # Directory and filename format are grimblast's own, so an annotated
      # shot lands beside a plain one under the same naming.
      sattyEdit = pkgs.writeShellScript "satty-edit" ''
        set -u
        dir="''${XDG_SCREENSHOTS_DIR:-''${XDG_PICTURES_DIR:-$HOME}}"
        ${pkgs.coreutils}/bin/mkdir -p "$dir"
        ${pkgs.satty}/bin/satty \
          --filename "$1" \
          --output-filename "$dir/%Y%m%d_%H%M%S.png" \
          --actions-on-enter save-to-clipboard,save-to-file,exit \
          --copy-command ${pkgs.wl-clipboard}/bin/wl-copy
        ${pkgs.coreutils}/bin/rm -f "$1"
      '';

      # grimblast parks `edit`'s temp file in /tmp, which is world readable.
      # $XDG_RUNTIME_DIR is 0700 and goes away with the session, which is a
      # better home for a screenshot nobody has decided to keep yet -- and the
      # wrapper above deletes it either way.
      annotate =
        target:
        "env GRIMBLAST_EDITOR=${sattyEdit} DEFAULT_TMP_EDITOR_DIR=\"$XDG_RUNTIME_DIR\""
        + " ${pkgs.grimblast}/bin/grimblast --freeze edit ${target}";

      # -- Display settings GUI ----------------------------------------------
      #
      # nwg-displays is the arrange-your-monitors dialog Plasma has and a bare
      # compositor does not: position, resolution, refresh rate, scale,
      # rotation, mirroring, applied live via hyprctl and then written out.
      #
      # It persists by *writing Hyprland config*, which is the whole problem:
      # hyprland.conf here is a read-only symlink into the store. Same shape
      # as matugen and the colours, and the same answer -- the tool owns its
      # own file and this config pulls it in by absolute path. It picks the
      # paths up from $XDG_CONFIG_HOME/hypr and creates both files itself if
      # they are missing, so the defaults are already the right ones and only
      # the workspace count needs saying.
      monitorsConf = "${cfgHome}/hypr/monitors.conf";
      workspacesConf = "${cfgHome}/hypr/workspaces.conf";

      # -- matugen templates -------------------------------------------------
      #
      # Each renders one `colors.*` file. They live in the store and are named
      # from ~/.config/matugen/config.toml by absolute path, so the only
      # matugen file in $HOME is that config -- and running `matugen image
      # some.jpg` by hand therefore does exactly what the timer does.
      #
      # `hex_stripped` is the same value without the leading '#', which is what
      # Hyprland's rgb()/rgba() literals want.

      # JSON rather than a stylesheet, because the consumer is QML and QML has
      # JSON.parse. The bar reads this through a FileView and rebinds -- no
      # reload, no signal, nothing to restart. Keys match the fallback palette
      # in shell.qml one for one; see the merge there, which is what stops a
      # half-written or still-empty file from blanking the bar.
      # Caelestia's colour scheme, in Caelestia's own state file. This is what
      # keeps the wallpaper pipeline ours instead of handing colour duty to
      # `caelestia scheme set`: services/Colours.qml reads this path through a
      # FileView with watchChanges + onFileChanged, so a rotation repaints the
      # shell live, exactly like every other consumer here.
      #
      # Two details are load-bearing and both come from reading that loader:
      #
      #   * values are `hex_stripped`. The loader does `#${colour}` itself, so
      #     a leading '#' here yields '##rrggbb' and silently no colour.
      #   * keys are Material 3 roles in camelCase, which is NOT what matugen
      #     calls them -- matugen is snake_case (`on_primary`,
      #     `surface_container_high`). Hence the mapping below rather than a
      #     straight dump. Keys the loader does not know are ignored, and roles
      #     omitted here keep Caelestia's built-in defaults, so a partial map
      #     degrades quietly rather than breaking the shell.
      #
      # Custom named schemes are not an officially supported upstream feature,
      # so this file is undocumented surface -- if a release renames it, the
      # fallback is letting caelestia-cli own colours.
      caelestiaTemplate = pkgs.writeText "matugen-caelestia.json" ''
        {
          "name": "matugen",
          "flavour": "default",
          "mode": "${colorMode}",
          "colours": {
            "background":              "{{colors.background.default.hex_stripped}}",
            "onBackground":            "{{colors.on_background.default.hex_stripped}}",
            "surface":                 "{{colors.surface.default.hex_stripped}}",
            "onSurface":               "{{colors.on_surface.default.hex_stripped}}",
            "surfaceVariant":          "{{colors.surface_variant.default.hex_stripped}}",
            "onSurfaceVariant":        "{{colors.on_surface_variant.default.hex_stripped}}",
            "surfaceContainerLowest":  "{{colors.surface_container_lowest.default.hex_stripped}}",
            "surfaceContainerLow":     "{{colors.surface_container_low.default.hex_stripped}}",
            "surfaceContainer":        "{{colors.surface_container.default.hex_stripped}}",
            "surfaceContainerHigh":    "{{colors.surface_container_high.default.hex_stripped}}",
            "surfaceContainerHighest": "{{colors.surface_container_highest.default.hex_stripped}}",
            "surfaceBright":           "{{colors.surface_bright.default.hex_stripped}}",
            "surfaceDim":              "{{colors.surface_dim.default.hex_stripped}}",
            "surfaceTint":             "{{colors.surface_tint.default.hex_stripped}}",
            "inverseSurface":          "{{colors.inverse_surface.default.hex_stripped}}",
            "inverseOnSurface":        "{{colors.inverse_on_surface.default.hex_stripped}}",
            "primary":                 "{{colors.primary.default.hex_stripped}}",
            "onPrimary":               "{{colors.on_primary.default.hex_stripped}}",
            "primaryContainer":        "{{colors.primary_container.default.hex_stripped}}",
            "onPrimaryContainer":      "{{colors.on_primary_container.default.hex_stripped}}",
            "inversePrimary":          "{{colors.inverse_primary.default.hex_stripped}}",
            "secondary":               "{{colors.secondary.default.hex_stripped}}",
            "onSecondary":             "{{colors.on_secondary.default.hex_stripped}}",
            "secondaryContainer":      "{{colors.secondary_container.default.hex_stripped}}",
            "onSecondaryContainer":    "{{colors.on_secondary_container.default.hex_stripped}}",
            "tertiary":                "{{colors.tertiary.default.hex_stripped}}",
            "onTertiary":              "{{colors.on_tertiary.default.hex_stripped}}",
            "tertiaryContainer":       "{{colors.tertiary_container.default.hex_stripped}}",
            "onTertiaryContainer":     "{{colors.on_tertiary_container.default.hex_stripped}}",
            "error":                   "{{colors.error.default.hex_stripped}}",
            "onError":                 "{{colors.on_error.default.hex_stripped}}",
            "errorContainer":          "{{colors.error_container.default.hex_stripped}}",
            "onErrorContainer":        "{{colors.on_error_container.default.hex_stripped}}",
            "outline":                 "{{colors.outline.default.hex_stripped}}",
            "outlineVariant":          "{{colors.outline_variant.default.hex_stripped}}",
            "shadow":                  "{{colors.shadow.default.hex_stripped}}",
            "scrim":                   "{{colors.scrim.default.hex_stripped}}"
          }
        }
      '';

      hyprTemplate = pkgs.writeText "matugen-hypr.conf" ''
        # Generated by matugen; sourced from hyprland.conf. post_hook runs
        # `hyprctl reload`, so borders repaint without restarting anything.
        $primary = rgb({{colors.primary.default.hex_stripped}})
        $on_primary = rgb({{colors.on_primary.default.hex_stripped}})
        $secondary = rgb({{colors.secondary.default.hex_stripped}})
        $tertiary = rgb({{colors.tertiary.default.hex_stripped}})
        $surface = rgb({{colors.surface.default.hex_stripped}})
        $on_surface = rgb({{colors.on_surface.default.hex_stripped}})
        $outline = rgb({{colors.outline.default.hex_stripped}})
        $shadow = rgb({{colors.shadow.default.hex_stripped}})

        general {
            col.active_border = $primary $tertiary 45deg
            col.inactive_border = rgba({{colors.outline_variant.default.hex_stripped}}66)
        }

        # Tabbed / stacked groups. Split the same way `general` is: the
        # behavioural half lives in hyprland.conf and only the palette is
        # re-derived here, so a group's tab bar follows the wallpaper like
        # every other surface.
        #
        # The group border repeats general's gradient on purpose -- a grouped
        # window is still the focused window, and giving it a second accent
        # would read as a different kind of focus rather than the same one.
        group {
            col.border_active = $primary $tertiary 45deg
            col.border_inactive = rgba({{colors.outline_variant.default.hex_stripped}}66)

            groupbar {
                col.active = $primary
                col.inactive = rgba({{colors.surface_container.default.hex_stripped}}cc)
                text_color = $on_primary
                text_color_inactive = $on_surface
            }
        }

        ${lib.optionalString hy3 (''
          # hy3's tab bar. Same split as `group` directly above --
          # behaviour in hyprland.conf, palette here -- and the roles are
          # deliberately the same ones, so a hy3 tab and a native groupbar tab
          # are the same surface in the same scheme.
          #
          # Only emitted when the layout is actually hy3, for the same reason
          # the `dwindle` and `group` blocks in hyprland.conf are gated: a
          # dwindle host never loads hy3, so these would be dead keys in a
          # generated file. Hyprland tolerates them either way -- `plugin:` is
          # a free-form bucket, verified with --verify-config -- so this is
          # tidiness rather than a correctness fix.
          plugin {
              hy3 {
                  # A nested `colors` section, not Hyprland's `col.` prefix --
                  # hy3's keys are plugin:hy3:tabs:colors:*, taken from the
                  # plugin binary's own option strings rather than its README.
                  tabs {
                      colors {
                          active = $primary
                          active_border = $tertiary
                          active_text = $on_primary
                          # The tab holding keyboard focus inside a group that is
                          # not itself focused: dimmer than active, brighter than
                          # inactive.
                          focused = rgb({{colors.secondary.default.hex_stripped}})
                          focused_border = $tertiary
                          focused_text = $on_primary
                          inactive = rgba({{colors.surface_container.default.hex_stripped}}cc)
                          inactive_border = rgba({{colors.outline_variant.default.hex_stripped}}66)
                          inactive_text = $on_surface
                          urgent = rgb({{colors.error.default.hex_stripped}})
                          urgent_border = rgb({{colors.error.default.hex_stripped}})
                          urgent_text = rgb({{colors.on_error.default.hex_stripped}})
                      }
                  }
              }
          }
        '')}

        decoration {
            shadow {
                color = rgba({{colors.shadow.default.hex_stripped}}99)
            }
        }
      '';

      hyprlockTemplate = pkgs.writeText "matugen-hyprlock.conf" ''
        # Generated by matugen; sourced from hyprlock.conf. hyprlock reads its
        # config when it starts, so the next lock picks these up.
        $lockBackground = rgb({{colors.surface.default.hex_stripped}})
        $lockForeground = rgb({{colors.on_surface.default.hex_stripped}})
        $lockAccent = rgb({{colors.primary.default.hex_stripped}})
        $lockInner = rgb({{colors.surface_container_high.default.hex_stripped}})
        $lockError = rgb({{colors.error.default.hex_stripped}})
      '';

      rofiTemplate = pkgs.writeText "matugen-rofi.rasi" ''
        /* Generated by matugen; @import-ed from rofi's config. rofi reads this
           when it launches, which for a launcher is every time you use it. */
        * {
            background:     {{colors.surface.default.hex}};
            background-alt: {{colors.surface_container.default.hex}};
            foreground:     {{colors.on_surface.default.hex}};
            selected:       {{colors.primary.default.hex}};
            on-selected:    {{colors.on_primary.default.hex}};
            active:         {{colors.tertiary.default.hex}};
            urgent:         {{colors.error.default.hex}};
            outline:        {{colors.outline.default.hex}};
        }
      '';

      # GTK. Only @define-color lines: the actual gtk.css stays HM's (see the
      # header note about GTK4), and these override the named colours the
      # theme's own stylesheet already refers to.
      gtkTemplate = pkgs.writeText "matugen-gtk.css" ''
        /* Generated by matugen; @import-ed from the gtk.css Home Manager owns. */
        @define-color theme_bg_color {{colors.surface.default.hex}};
        @define-color theme_fg_color {{colors.on_surface.default.hex}};
        @define-color theme_base_color {{colors.surface_container_low.default.hex}};
        @define-color theme_text_color {{colors.on_surface.default.hex}};
        @define-color theme_selected_bg_color {{colors.primary.default.hex}};
        @define-color theme_selected_fg_color {{colors.on_primary.default.hex}};
        @define-color borders {{colors.outline_variant.default.hex}};
        @define-color warning_color {{colors.tertiary.default.hex}};
        @define-color error_color {{colors.error.default.hex}};

        /* libadwaita's own names, so GTK4 apps follow too. */
        @define-color window_bg_color {{colors.surface.default.hex}};
        @define-color window_fg_color {{colors.on_surface.default.hex}};
        @define-color view_bg_color {{colors.surface_container_low.default.hex}};
        @define-color view_fg_color {{colors.on_surface.default.hex}};
        @define-color headerbar_bg_color {{colors.surface_container.default.hex}};
        @define-color headerbar_fg_color {{colors.on_surface.default.hex}};
        @define-color popover_bg_color {{colors.surface_container_high.default.hex}};
        @define-color popover_fg_color {{colors.on_surface.default.hex}};
        @define-color accent_bg_color {{colors.primary.default.hex}};
        @define-color accent_fg_color {{colors.on_primary.default.hex}};
        @define-color accent_color {{colors.primary.default.hex}};
        @define-color destructive_bg_color {{colors.error.default.hex}};
        @define-color destructive_fg_color {{colors.on_error.default.hex}};
      '';

      # Where each template lands. Everything under $XDG_CONFIG_HOME so the
      # files survive a reboot and a first login has something to read even
      # before the first rotation (see the seeding activation script below).
      generated = {
        # Under stateHome, not configHome, because that is where Caelestia
        # looks: utils/Paths.qml resolves `state` to
        # $XDG_STATE_HOME/caelestia. It is also the right category -- this file
        # is generated output that changes on every wallpaper rotation, not
        # configuration.
        caelestia = "${config.xdg.stateHome}/caelestia/scheme.json";
        hypr = "${cfgHome}/hypr/colors.conf";
        hyprlock = "${cfgHome}/hypr/hyprlock-colors.conf";
        rofi = "${cfgHome}/rofi/colors.rasi";
        gtk3 = "${cfgHome}/gtk-3.0/colors.css";
        gtk4 = "${cfgHome}/gtk-4.0/colors.css";
      };

      # Deliberately NOT in `generated` above: that attrset is matugen's output
      # and every entry in it is rewritten on each wallpaper rotation. This one
      # is user state -- which way round the groupbar draws -- and nothing but
      # the toggle keybind ever writes it.
      #
      # It has to be a `source`d file rather than a plain `hyprctl keyword`,
      # and that is not a stylistic choice. The wallpaper timer runs `hyprctl
      # reload` every wallpaperInterval seconds (300 by default, see the
      # matugen post_hook), and a reload resets every keyword override back to
      # what the config files say. A mode set with `keyword` alone would
      # therefore revert itself within five minutes. Sourced, it survives --
      # reload re-reads it like any other config.
      groupbarMode = "${cfgHome}/hypr/groupbar-mode.conf";

      # GTK3 apps re-read their CSS when XSETTINGS changes, which is what this
      # toggle provokes. It is the one repaint here that is a nudge rather than
      # a documented reload -- GTK has no "reload your css" command. GTK4 /
      # libadwaita apps ignore it and keep their colours until restarted; new
      # windows of either toolkit are always correct.
      gtkNudge = pkgs.writeShellScript "hyprland-gtk-nudge" ''
        set -u
        gs=${pkgs.glib}/bin/gsettings
        key="org.gnome.desktop.interface gtk-theme"
        current="$($gs get $key 2>/dev/null | tr -d "'")" || exit 0
        [ -n "$current" ] || exit 0
        $gs set $key "''${current}-matugen-nudge" 2>/dev/null || exit 0
        $gs set $key "$current" 2>/dev/null || true
      '';

      # GTK config is *user-wide*, not per-session, and these hosts also run
      # Plasma -- where modules/kde.nix deliberately installs a Windows 7 GTK
      # theme to match AeroThemePlasma. Left alone, the gtk.css imports below
      # would repaint that session's GTK apps in wallpaper colours too, which
      # is a visible regression nobody asked for.
      #
      # So the two GTK colour files are treated as session state: emptied when
      # the Hyprland session stops, refilled by the first wallpaper rotation
      # when it starts (within seconds -- the timer's OnActiveSec is 3). An
      # empty file is still a valid @import target, so Plasma just gets the
      # theme's own colours, exactly as before this module existed.
      #
      # The one hole is an unclean exit (a crash, or pulling the power), which
      # leaves the files populated for the next Plasma login. Recover by
      # emptying them by hand, or by starting and cleanly leaving Hyprland
      # once. Not worth more machinery than that.
      clearGtkColors = pkgs.writeShellScript "hyprland-clear-gtk-colors" ''
        set -u
        for f in ${lib.escapeShellArgs [ generated.gtk3 generated.gtk4 ]}; do
          : > "$f" 2>/dev/null || true
        done
        ${gtkNudge}
      '';

      # Flip the groupbar between tabbed (titles side by side, i3's "tabbed")
      # and stacked (titles listed one per row, i3's "stacking"). Hyprland has
      # one knob for both -- `group:groupbar:stacked` -- so this is a toggle
      # rather than two dispatchers.
      #
      # Current state is read back from the file rather than from `hyprctl
      # getoption`, which keeps the script honest about what will survive the
      # next reload and saves parsing JSON for one integer. A missing or empty
      # file reads as 0, which is both Hyprland's default and what the seeding
      # activation below writes.
      #
      # The file is written *and* the option is set live: writing alone would
      # not show up until the next `hyprctl reload` (up to wallpaperInterval
      # away), and setting alone would not survive it.
      toggleGroupbarMode = pkgs.writeShellScript "hyprland-groupbar-mode" ''
        set -eu
        if ${pkgs.gnugrep}/bin/grep -qs 'stacked = 1' ${lib.escapeShellArg groupbarMode}; then
          next=0
        else
          next=1
        fi
        ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname ${lib.escapeShellArg groupbarMode})"
        ${pkgs.coreutils}/bin/printf 'group {\n    groupbar {\n        stacked = %s\n    }\n}\n' \
          "$next" > ${lib.escapeShellArg groupbarMode}
        ${pkgs.hyprland}/bin/hyprctl keyword group:groupbar:stacked "$next" >/dev/null
      '';

      matugenConfig = {
        config = { };
        templates = {
          caelestia = {
            input_path = "${caelestiaTemplate}";
            output_path = generated.caelestia;
            # No post_hook: the shell's own FileView watches this file.
          };
          hyprland = {
            input_path = "${hyprTemplate}";
            output_path = generated.hypr;
            post_hook = "hyprctl reload || true";
          };
          hyprlock = {
            input_path = "${hyprlockTemplate}";
            output_path = generated.hyprlock;
          };
          rofi = {
            input_path = "${rofiTemplate}";
            output_path = generated.rofi;
          };
          gtk3 = {
            input_path = "${gtkTemplate}";
            output_path = generated.gtk3;
          };
          gtk4 = {
            input_path = "${gtkTemplate}";
            output_path = generated.gtk4;
            post_hook = "${gtkNudge}";
          };
        };
      };

      # -- The rotation itself -----------------------------------------------
      #
      # Set the wallpaper, then re-derive the scheme from that same image.
      # Every binary is an absolute store path: a systemd user unit inherits no
      # PATH worth relying on. hyprctl is the exception -- it is invoked from
      # matugen's post_hook, which runs under a shell, so it is put on PATH
      # explicitly below. (mako used to be here for `makoctl reload`; Caelestia
      # owns notifications now and watches its own scheme file, so neither the
      # binary nor the hook is needed.)
      rotate = pkgs.writeShellScript "hyprland-wallpaper-rotate" ''
        set -u
        export PATH=${
          lib.makeBinPath [
            pkgs.hyprland
            pkgs.glib
            pkgs.coreutils
          ]
        }:"''${PATH:-}"

        dir=${lib.escapeShellArg (toString wallpaperDir)}
        [ -d "$dir" ] || { echo "wallpaper dir $dir does not exist" >&2; exit 0; }

        cache="''${XDG_CACHE_HOME:-$HOME/.cache}/current-wallpaper"
        previous=""
        [ -r "$cache" ] && previous="$(${pkgs.coreutils}/bin/cat "$cache")"

        # -print0/-z throughout: wallpaper filenames here contain spaces.
        # `shuf -n1` over the whole list rather than picking an index, so the
        # set can change under us without an off-by-one. The previous
        # wallpaper (read from the breadcrumb below) is excluded first, so
        # back-to-back rotations -- periodic or via the manual keybind --
        # don't land on the same image twice in a row.
        list() {
          ${pkgs.findutils}/bin/find -L "$dir" -type f \
            \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
               -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.bmp' \) \
            -print0
        }
        image="$(list | ${pkgs.coreutils}/bin/grep -zv -Fx "$previous" \
          | ${pkgs.coreutils}/bin/shuf -z -n1 \
          | ${pkgs.coreutils}/bin/tr -d '\0')"

        # A single-image directory excludes its only candidate above; fall
        # back to the unfiltered listing rather than silently no-op'ing.
        if [ -z "$image" ]; then
          image="$(list | ${pkgs.coreutils}/bin/shuf -z -n1 | ${pkgs.coreutils}/bin/tr -d '\0')"
        fi

        if [ -z "$image" ]; then
          echo "no images under $dir" >&2
          exit 0
        fi

        # A different transition effect each rotation, picked here rather
        # than left to awww's own `--transition-type random`, so the wipe/wave
        # angle gets randomised too -- `random` alone leaves it at its default
        # every time, and would also drag the circle transitions back in.
        #
        # The circle wipes (grow, outer, and their aliases center/any) are
        # deliberately absent: they read as a spotlight sweeping the screen
        # rather than as a wallpaper change. Dropping them also makes
        # --transition-pos dead, as it only steers the circle's centre.
        transitions=(fade left right top bottom wipe wave)
        transition="''${transitions[RANDOM % ''${#transitions[@]}]}"
        angle=$((RANDOM % 360))

        # swww was renamed to awww upstream, and nixpkgs keeps `swww` only as
        # a deprecation alias, so the real name is used throughout. The daemon
        # is a separate unit; if it is not up yet this call fails and the next
        # tick retries, so it is not fatal.
        #
        # Easing and step are both left at awww's defaults on purpose. The
        # default bezier (.54,0,.34,.99) is a conventional ease-in-out and
        # reads better than the hand-rolled fast -> slow -> fast curve that
        # used to be pinned here. --transition-step likewise: pinning it to 2
        # forced a gradual animation but glowed at the moving edge, so pacing
        # is left entirely to --transition-duration.
        ${pkgs.awww}/bin/awww img "$image" \
          --resize crop \
          --transition-type "$transition" \
          --transition-angle "$angle" \
          --transition-duration 1 \
          --transition-fps 60 || true

        # --source-color-index 0 is what makes this non-interactive: matugen 4
        # otherwise offers a list of candidate source colours and blocks on an
        # arrow-key pick, which in a unit shows up as "IO error: not a terminal".
        # </dev/null belt-and-braces for the same reason.
        ${pkgs.matugen}/bin/matugen \
          --quiet \
          --source-color-index 0 \
          --type ${lib.escapeShellArg colorScheme} \
          --mode ${lib.escapeShellArg colorMode} \
          image "$image" < /dev/null

        # Leave a breadcrumb so `awww restore` and anything else that wants to
        # know the current wallpaper can find it.
        ${pkgs.coreutils}/bin/printf '%s\n' "$image" > "''${XDG_CACHE_HOME:-$HOME/.cache}/current-wallpaper"
      '';

      themingEnabled = wallpaperDir != null;
    in
    {
      # Unconditional, like every other import here: the module only declares
      # options, and all of its config hangs off `programs.caelestia.enable`
      # below, which is itself inside `lib.mkIf enabled`. A host without the
      # hyprland tag therefore gets the options and none of the shell.
      imports = [ inputs.caelestia.homeManagerModules.default ];

      config = lib.mkIf enabled (
        lib.mkMerge [
          {
            # ---------------------------------------------------------------
            # Compositor
            # ---------------------------------------------------------------
            wayland.windowManager.hyprland = {
              enable = true;
              # The NixOS module installs Hyprland and the portal; HM only
              # writes the config. This is upstream's documented pairing.
              package = null;
              portalPackage = null;
              systemd.enable = true;
              xwayland.enable = true;

              # hyprlang, not the newer lua config type. Two reasons: every
              # piece of Hyprland documentation is hyprlang, and matugen's
              # generated colour file is hyprlang that gets `source`d -- the
              # lua backend would need it wrapped. `settings` below is format
              # agnostic, so this is one line to change later.
              configType = "hyprlang";

              # nwg-displays' output, and the one place in this file where
              # *where* a `source` lands is the entire point.
              #
              # `settings.source` below would not do. Home Manager hands
              # `source` to toHyprconf's importantPrefixes, which hoists those
              # lines to the very top of the generated file -- correct for the
              # colours, fatal here: the generic `monitor=,preferred,auto,...`
              # rule further down would then be read *after* nwg-displays'
              # per-output lines. `extraConfig` is concatenated last (verified
              # in HM's own hyprland.nix, where the file's text is systemd
              # activation + plugins + settings + submaps + extraConfig), so
              # anything the GUI writes wins over the fallback, which is what
              # keeps that fallback a sane default rather than an override.
              #
              # workspaces.conf is sourced too, not just monitors.conf: the
              # same dialog assigns workspaces to outputs, and leaving that
              # half unsourced would make a working-looking part of the GUI
              # quietly do nothing. Nothing else in this module emits
              # `workspace=` rules, so it has the field to itself.
              #
              # Both are seeded empty at activation -- see
              # home.activation.hyprlandDisplays -- because Hyprland treats a
              # `source` of a missing file as a config error, and nwg-displays
              # only creates them the first time it is actually run.
              extraConfig = ''
                source = ${monitorsConf}
                source = ${workspacesConf}
              '';

              settings = {
                # Colours live in a file matugen rewrites on every wallpaper
                # change; `source` is absolute because this config itself is a
                # store path, so a relative path would resolve into /nix/store.
                # The file is seeded at activation, so it always exists.
                # Second entry is the groupbar tabbed/stacked mode -- user
                # state the toggle keybind writes, sourced for the same reason
                # the colours are: `hyprctl reload` re-reads sourced files and
                # discards anything set with `hyprctl keyword`. Both are seeded
                # at activation, so neither is ever a missing-source error.
                source = [
                  generated.hypr
                ]
                # Native-groupbar state only. hy3 draws its own tabs and has no
                # stacked mode, so under hy3 this file has nothing to say and
                # the keybind that writes it is not bound either.
                ++ lib.optional (!hy3) groupbarMode;

                # ",preferred,auto,<scale>" -- every output, its preferred mode,
                # auto-placed, at noughty.hyprland.scale (1 = 100%).
                monitor = ",preferred,auto,${scale}";

                # The cursor half of `env` is conditional, and the condition is
                # who installed the theme. `home.pointerCursor` is *user-wide*
                # state, so on a KDE host modules/kde.nix owns it
                # (AeroThemePlasma's "aero-drop") and exports XCURSOR_THEME/SIZE
                # as session variables -- Hyprland inherits the same cursor
                # Plasma uses, and naming a second theme here would name one not
                # actually installed. On a Hyprland-only host this module is the
                # one installing it (see `home.pointerCursor` below), so it can
                # safely name it, and does: session variables reach Hyprland
                # only via the login shell that greetd starts it from, and this
                # makes the pointer independent of that path. No HYPRCURSOR_* --
                # bibata ships XCursor only, and pointing hyprcursor at a theme
                # it cannot find is a warning and a fallback, not an upgrade.
                env = [
                  "QT_QPA_PLATFORM,wayland;xcb"
                  "MOZ_ENABLE_WAYLAND,1"
                ]
                ++ lib.optionals (!kdeOwnsCursor) [
                  "XCURSOR_THEME,${cursorName}"
                  "XCURSOR_SIZE,${toString cursorSize}"
                ];

                general = {
                  # Deliberately heavier than Hyprland's defaults. There are no
                  # titlebars here, so the active border -- coloured from the
                  # sourced matugen file -- is the only thing marking focus, and
                  # at 2px that accent is too thin to pick out at a glance. The
                  # gaps go up with it: a thicker frame on every window makes
                  # the old 5/12 spacing look cramped.
                  gaps_in = 8;
                  gaps_out = 16;
                  border_size = 3;
                  # noughty.hyprland.layout. Naming a layout the compositor has not
                  # registered yet is NOT a config error (verified with
                  # --verify-config), which is what makes hy3's deferred plugin
                  # load at `exec-once` survivable.
                  layout = layout;
                  resize_on_border = true;
                  # col.active_border / col.inactive_border deliberately absent:
                  # they come from the sourced colours file.
                };

                decoration = {
                  # Stays comfortably above general:border_size so the corner
                  # arc still reads through the thicker border instead of being
                  # squared off by it.
                  rounding = 12;
                  blur = {
                    enabled = true;
                    size = 5;
                    passes = 2;
                    new_optimizations = true;
                  };
                };

                animations = {
                  enabled = true;
                  bezier = [ "wind, 0.05, 0.9, 0.1, 1.05" ];
                  animation = [
                    "windows, 1, 5, wind"
                    "windowsOut, 1, 5, default, popin 80%"
                    "border, 1, 10, default"
                    "fade, 1, 5, default"
                    "workspaces, 1, 5, default"
                  ];
                };

                # `dwindle` / `group` / `binds` (for the native layout) and
                # `plugin.hy3` (for hy3) are merged in from `layoutSettings` at
                # the end of this block. Exactly one of the two sets is ever
                # written -- this module does not carry dead config for the
                # layout that is not in use.

                input = {
                  # Swiss German, no dead keys -- carried over from the old
                  # Hyprland config in git history. Plasma gets this from its
                  # own keyboard settings, which is why there is no equivalent
                  # line in the KDE modules.
                  kb_layout = "ch";
                  kb_variant = "de_nodeadkeys";
                  follow_mouse = 1;
                  touchpad = {
                    natural_scroll = false;
                    disable_while_typing = false;
                    # macOS trackpad semantics: a physical click with two
                    # fingers down is a right click, three a middle click.
                    # libinput calls this the "clickfinger" click method; its
                    # default is "button areas", where right-click lives in
                    # the bottom-right corner of the pad and two fingers just
                    # click left. Tapping already behaved the Mac way --
                    # tap-to-click is on and libinput's tap button map is
                    # 1/2/3 fingers = left/right/middle -- so this only closes
                    # the gap for the pad's physical button.
                    clickfinger_behavior = true;
                  };
                };

                misc = {
                  disable_hyprland_logo = true;
                  disable_splash_rendering = true;
                  vrr = 1;
                  # Nothing here should paint a wallpaper -- swww owns it.
                  force_default_wallpaper = 0;
                };

                # -------------------------------------------------------------
                # Keybindings -- the KDE set, verbatim where KDE has an
                # equivalent action. See modules/kde.nix for the
                # reasoning behind each choice; only the differences are noted
                # here.
                # -------------------------------------------------------------
                bind = [
                  # alt-h/j/k/l = focus left/down/up/right
                  "${mod}, H, ${dispatch "movefocus"}, l"
                  "${mod}, J, ${dispatch "movefocus"}, d"
                  "${mod}, K, ${dispatch "movefocus"}, u"
                  "${mod}, L, ${dispatch "movefocus"}, r"

                  # alt-shift-h/j/k/l = move the window. The KDE half had to
                  # spell this as quick-tile, because KWin has no tiling-WM
                  # "move node". Hyprland does, so this is a move -- which is
                  # what the AeroSpace original actually does.
                  #
                  # `movewindoworgroup` rather than plain `movewindow`, so the
                  # same four keys also get windows in and out of the tab
                  # groups below: it moves *into* the neighbour if that
                  # neighbour is a group, *out of* the current group if the
                  # window is in one, and otherwise is exactly `movewindow`.
                  # So nothing about the ungrouped case changes.
                  "${mod} SHIFT, H, ${moveWindowDispatch}, l"
                  "${mod} SHIFT, J, ${moveWindowDispatch}, d"
                  "${mod} SHIFT, K, ${moveWindowDispatch}, u"
                  "${mod} SHIFT, L, ${moveWindowDispatch}, r"
                ]
                # The group / split keys, which differ per layout -- spliced in
                # here rather than appended at the end purely so the generated
                # file keeps its existing order: on a dwindle host the rendered
                # hyprland.conf is then byte-for-byte what it was before this
                # option existed.
                ++ groupBinds
                ++ [

                  # alt-f = fullscreen
                  "${mod}, F, fullscreen, 0"

                  # Meta+Q = close window, as in the KDE half. Alt+Q was a
                  # workspace key when this landed, which is why it is not on
                  # `mod`; the workspaces have since moved to SUPER's number
                  # row and freed the letter, but the reason to leave this
                  # alone is now muscle memory rather than a collision.
                  "SUPER, Q, ${dispatch "killactive"},"

                  # Launchers: alt-b/v -- two of the three apps KDE and
                  # AeroSpace launch. Spotify was the third, on alt-m, and is
                  # gone from here: alt-m now carries per-stream volume (see
                  # the bindel block below), which is the key it was asked for.
                  #
                  # Dropping it costs nothing. Super+D's `combi` searches open
                  # windows before .desktop entries, so typing "spotify" raises
                  # the running instance and, with none running, falls through
                  # to drun and starts one -- see the combi-modes comment in
                  # programs.rofi.extraConfig. The package is installed
                  # independently of this binding, by
                  # users.users.phonkd.packages in modules/desktop.nix, so
                  # dropping the last `pkgs.spotify` reference from this module
                  # does not take Spotify out of the closure.
                  "${mod}, B, exec, ${zen}"
                  "${mod}, V, exec, ${kitty}"

                  # --- Below here: things Plasma provides for free and a bare
                  # --- compositor does not, so they have no counterpart in
                  # --- modules/kde.nix.

                  # Launcher on Super+D -- the key the pre-GNOME Hyprland config
                  # in this repo's history used ($mainMod, D, exec, $menu), so
                  # it is the muscle memory that predates the KDE session.
                  # Deliberately NOT Alt+Space: that is KRunner's key on the
                  # Plasma side, and Alt is already the workspace modifier here.
                  #
                  # `combi` rather than `drun`: it searches open windows *and*
                  # .desktop entries in one list, so the launcher doubles as a
                  # window switcher and picking an app that is already running
                  # raises it instead of starting a second copy. The sub-modes
                  # and their order live in programs.rofi.extraConfig below.
                  "SUPER, D, exec, ${pkgs.rofi}/bin/rofi -show combi"
                  # Float toggle -- AeroSpace's alt-space, which KDE could not
                  # have because KRunner owns that key. Super+Space here.
                  "SUPER, SPACE, togglefloating,"
                  "SUPER, E, exec, ${pkgs.nautilus}/bin/nautilus"
                  "SUPER, L, exec, ${pkgs.hyprlock}/bin/hyprlock"
                  "SUPER SHIFT, E, exit,"
                  # Screenshots -- Spectacle's job on the Plasma side. Three
                  # targets on Super+Shift+1/2/3, screen -> window -> region,
                  # narrowing as the number goes up, each one landing in satty
                  # to be annotated before it is committed (see `annotate` and
                  # `sattyEdit` above for the arrow/box/blur half and for why
                  # the pipeline is shaped the way it is). `--freeze` holds the
                  # screen still while you select, so menus and hover states
                  # can be captured.
                  #
                  # The annotate step is a deliberate behaviour change and the
                  # one thing here that can lose a capture: satty commits on
                  # Enter and *discards* on Escape, where `copysave` was
                  # unconditional and instant. Plain Print below is kept on the
                  # old no-GUI path precisely so that instant route still
                  # exists -- annotation is the considered shot, Print is the
                  # reflex one.
                  #
                  # On Alt+Shift, and on `code:` rather than the keysyms
                  # `1`/`2`/`3`. The keysym spelling is a live trap on this
                  # ch/de_nodeadkeys keyboard, where Shift+1 emits `plus`:
                  # Hyprland normally still matches the base-level keysym for a
                  # SHIFT bind, but when it does not the bind is simply dead and
                  # says nothing about it. `code:10`/`11`/`12` are the physical
                  # AE01..AE03 keys and cannot be wrong, which is the same call
                  # the workspace binds above made.
                  #
                  # These were on Super+Shift until the workspace keys took the
                  # number row; they moved here, and the workspaces moved to
                  # Super, in one change -- the two halves swapped modifiers
                  # rather than either one carving an exception out of the
                  # other. Alt+Shift+3 for a region also puts the considered
                  # screenshot a finger-roll from macOS's Cmd+Shift+3.
                  #
                  # Alt+Shift+1: the monitor the mouse is on.
                  "${mod} SHIFT, code:10, exec, ${annotate "output"}"
                  # Alt+Shift+2: pick a window. grimblast dropped its `window`
                  # target ("now included in 'area'"), so this is `area` with
                  # slurp restricted to the window rectangles grimblast already
                  # feeds it -- `slurp -r` is "restrict selection to predefined
                  # boxes". SLURP_ARGS is grimblast's own documented hook for
                  # this, not a wrapper around it. The practical difference from
                  # plain `area` is that you cannot free-drag: every selection
                  # snaps to exactly one window.
                  "${mod} SHIFT, code:11, exec, SLURP_ARGS=-r ${annotate "area"}"
                  # Alt+Shift+3: free region (single-clicking a window still
                  # grabs that window, which is grimblast's own behaviour).
                  "${mod} SHIFT, code:12, exec, ${annotate "area"}"
                  # PrtSc keeps the old instant path: straight to the clipboard
                  # and to disk, no editor, nothing to confirm. Shift+PrtSc is
                  # the same region grab routed through satty, so the annotated
                  # flow is also reachable from the obvious key.
                  ", Print, exec, ${pkgs.grimblast}/bin/grimblast --freeze copysave area"
                  "SHIFT, Print, exec, ${annotate "area"}"
                  # Display arrangement GUI -- Win+P, the key Windows puts the
                  # projector/display switcher on. `-n 9` because this config
                  # has nine workspaces, not nwg-displays' default ten.
                  "SUPER, P, exec, ${pkgs.nwg-displays}/bin/nwg-displays -n 9"
                  "SUPER, C, exec, ${pkgs.hyprpicker}/bin/hyprpicker -a"
                  "SUPER, V, exec, ${pkgs.cliphist}/bin/cliphist list | ${pkgs.rofi}/bin/rofi -dmenu | ${pkgs.cliphist}/bin/cliphist decode | ${pkgs.wl-clipboard}/bin/wl-copy"
                  # Force a wallpaper + colour scheme change now, instead of
                  # waiting out the timer.
                  "SUPER, W, exec, ${pkgs.systemd}/bin/systemctl --user start hyprland-wallpaper.service"

                  # Audio output switcher, on alt-0. Alt's digits are free now
                  # that the workspaces sit on SUPER, so this no longer has to
                  # dodge them -- but 0 stays the right key regardless: the
                  # workspace set runs 1..9 and there is no workspace 10, so
                  # the number row's last key is the one that never gets
                  # claimed on either modifier.
                  #
                  # `code:19` is AE10, the physical 0. No SHIFT here, so the
                  # keysym `0` would in fact have worked -- the Shift+1-emits-
                  # `plus` trap needs a SHIFT bind to bite -- but spelling one
                  # key of the number row differently from the other nine is
                  # the kind of detail that goes wrong later.
                  #
                  # `bind`, not `bindel`: this opens a menu, and repeating it
                  # while the key is held would stack a second rofi on the first.
                  "${mod}, code:19, exec, ${sinkSwitcher}"
                ]
                ++ workspaceBinds;

                # Media and brightness keys. `bindel` repeats while held and
                # works on the lock screen.
                bindel = [
                  # Device volume: the output as a whole.
                  "SUPER, M, exec, ${pkgs.wireplumber}/bin/wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%+"
                  "SUPER SHIFT, M, exec, ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"

                  # Application volume: the same M key on the other modifier,
                  # moving every playback *stream* instead of the device. This
                  # is the fader pavucontrol shows per-app, so Spotify can be
                  # turned down without turning the laptop down -- and, unlike
                  # the device binds above, it keeps working when a stream is
                  # routed through the EasyEffects sink rather than straight at
                  # the default output. See modules/hyprland/stream-volume.nix
                  # for which nodes count as an application stream and why.
                  "${mod}, M, exec, ${streamVolume} up"
                  "${mod} SHIFT, M, exec, ${streamVolume} down"
                  ", XF86AudioMute, exec, ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
                  ", XF86AudioMicMute, exec, ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
                  "SUPER, I, exec, ${pkgs.brightnessctl}/bin/brightnessctl set 5%+"
                  "SUPER SHIFT, i, exec, ${pkgs.brightnessctl}/bin/brightnessctl set 5%-"
                ];

                bindl = [
                  "SUPER, B, exec, ${pkgs.playerctl}/bin/playerctl play-pause"
                  "SUPER, N, exec, ${pkgs.playerctl}/bin/playerctl next"
                  "SUPER SHIFT, N, exec, ${pkgs.playerctl}/bin/playerctl previous"
                ];

                # Drag to move/resize, as on the KDE side.
                bindm = [
                  "SUPER, mouse:272, movewindow"
                  "SUPER, mouse:273, resizewindow"
                ];

                # Hyprland 0.55 rule grammar: `match:<field> <value>` selectors
                # first, then `<property> <value>`. This replaced the older
                # `windowrulev2 = <property>, <field>:<value>` form -- note the
                # properties are snake_case now too (`suppress_event`, not
                # `suppressevent`; `stay_focused`, not `stayfocused`), and the
                # old spellings are a hard config error, not a deprecation
                # warning: they failed with "invalid field type suppressevent"
                # and "invalid field stayfocused: missing a value".
                #
                # Verified, not inferred. `Hyprland --verify-config -c <file>`
                # parses a config and prints the errors without starting a
                # compositor, which is the cheapest way to check this file after
                # a Hyprland bump:
                #
                #   Hyprland --verify-config -c ~/.config/hypr/hyprland.conf
                #
                # These three rules (and everything else here, including the
                # colours file `source`d above) return "config ok" on 0.55.4.
                # The grammar also matches the lua form in the compositor's own
                # shipped share/hypr/hyprland.lua, where the first of these is
                # `match = { class = ".*" }` with `suppress_event = "maximize"`,
                # and a later example sets `float = true` as a property.
                windowrule = [
                  "match:class .*, suppress_event maximize"
                  # polkit prompts (hyprpolkitagent): float them and keep focus,
                  # or the password field loses the keyboard to whatever is
                  # underneath.
                  "match:title (Authentication Required), float on"
                  "match:title (Authentication Required), stay_focused on"
                ];

                # What turns Caelestia's transparency into glass rather than a
                # washed-out slab -- appearance.transparency below sets the
                # alpha, and this is what puts something behind it. The shell
                # names its surfaces `caelestia-bar`, `caelestia-launcher`,
                # `caelestia-sidebar`, `caelestia-border` and so on, hence the
                # prefix match rather than one rule per component.
                #
                # `ignore_alpha` is the half that matters for burn-in: it tells
                # Hyprland not to blur pixels below that alpha, and the bar's
                # surface is fully transparent whenever it is hidden. Without
                # it a blurred strip would sit at the top of the screen all
                # day, which is the exact always-on artefact hiding the bar
                # exists to avoid.
                #
                # Grammar is Hyprland 0.55's, same rewrite the windowrules
                # above went through and the same hard-error-not-a-warning
                # behaviour: the older `blur, <namespace>` and
                # `ignorealpha 0.3, <namespace>` spellings fail with "invalid
                # field blur: missing a value" and "invalid field type
                # ignorealpha". Selector first, snake_case property second,
                # namespace matched as a regex. Field names come from the
                # compositor's own shipped share/hypr/stubs/hl.meta.lua
                # (HL.LayerRuleSpec).
                layerrule = [
                  "match:namespace ^caelestia-.*, blur on"
                  "match:namespace ^caelestia-.*, ignore_alpha 0.3"
                ];

                exec-once = [
                  # Clipboard history, feeding the Super+V picker above.
                  "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.cliphist}/bin/cliphist store"
                  "${pkgs.wl-clipboard}/bin/wl-paste --type image --watch ${pkgs.cliphist}/bin/cliphist store"
                  # Polkit agent -- see the NixOS half.
                  "${pkgs.hyprpolkitagent}/bin/hyprpolkitagent"
                ]
                # hy3 is a compositor plugin, and in hyprlang mode a plugin can
                # only be loaded from `exec-once` -- i.e. *after* the config has
                # been parsed. That ordering is the one real hazard in the whole
                # layout switch, so it was measured rather than assumed, with
                # `Hyprland --verify-config` (the workflow the windowrule note
                # further down already prescribes):
                #
                #   * `general:layout = hy3` naming a layout that is not
                #     registered yet is NOT an error. Hyprland accepts it and
                #     picks the layout up when the plugin registers it.
                #   * the whole `plugin { hy3 { ... } }` block is NOT an error
                #     either -- `plugin:` is a free-form bucket, so unknown
                #     subkeys are tolerated and applied once the plugin lands.
                #   * `bind = ..., hy3:movefocus, l` IS a hard error:
                #     "Invalid dispatcher, requested "hy3:movefocus" does not
                #     exist". Dispatchers resolve at parse time, and a bind
                #     naming an unknown one is *dropped*, not deferred.
                #
                # So without the `&& hyprctl reload` below the session would
                # come up with every hy3 bind missing and a config-error banner,
                # and would only heal at the next wallpaper rotation -- whose
                # post_hook happens to run `hyprctl reload`, up to
                # noughty.hyprland.wallpaperInterval seconds later. Chaining the
                # reload onto the load makes that immediate and deterministic.
                #
                # One command rather than two exec-once entries on purpose:
                # separate entries are ordered by *spawn* only, so a standalone
                # reload could re-parse before the load had finished registering
                # the dispatchers. `config-only` keeps it from re-running
                # monitor detection, which is what Home Manager's own onChange
                # reload uses too.
                #
                # This is also why `wayland.windowManager.hyprland.plugins` is
                # not used: it emits the bare `hyprctl plugin load` line with
                # nothing to sequence a reload after it.
                ++ lib.optional hy3 "${hyprctl} plugin load ${hy3Plugin} && ${hyprctl} reload config-only";
              }
              // layoutSettings;
            };

            # ---------------------------------------------------------------
            # Bar / shell
            # ---------------------------------------------------------------
            # Caelestia, in place of the hand-written Quickshell bar this used
            # to carry (commit 1201b63, if it ever needs to come back).
            #
            # It is a whole desktop rather than a bar, so most of what follows
            # is handing its extra halves back to the things this module
            # already runs. plans/caelestia-shell.md records what it insists on
            # owning, what it gives up, and the one thing it will not give up
            # (notifications -- see services.mako below).
            programs.caelestia = {
              enable = true;

              systemd = {
                enable = true;
                # Only ever start under Hyprland. The module's default is
                # config.wayland.systemd.target, i.e. graphical-session.target,
                # which the Plasma session reaches too -- that would drop this
                # shell on top of the Plasma panel.
                target = "hyprland-session.target";
              };

              settings = {
                bar = {
                  # The reason adopting this is worth anything at all: upstream
                  # already implements the hide-until-approached behaviour the
                  # hand-written bar existed to provide. `persistent` defaults
                  # to TRUE, so this is the line that keeps an OLED panel dark.
                  persistent = false;
                  showOnHover = true;
                };

                appearance.transparency = {
                  # Off by default upstream, which is precisely the complaint
                  # that started this ("not really good looking, not
                  # transparent"). Blur comes from the layerrules on the
                  # caelestia-* namespaces in the compositor section above.
                  enabled = true;
                  base = 0.6;
                  layers = 0.2;
                };

                # Caelestia draws its own wallpaper otherwise --
                # background.wallpaperEnabled defaults true -- which would sit
                # on top of the one swww is rotating. False drops its
                # background layer to WlrLayer.Bottom with a transparent
                # colour, so the wallpaper this module already manages shows
                # through untouched.
                background.wallpaperEnabled = false;

                general.idle = {
                  # hypridle owns idle here and hyprlock owns locking. Left
                  # alone Caelestia brings a SECOND idle stack -- its defaults
                  # are lock at 180s, dpms off at 300s, suspend-then-hibernate
                  # at 600s -- and the two would race to blank the screen. An
                  # empty timeout list is how you tell it to stay out of that.
                  timeouts = [ ];
                  lockBeforeSleep = false;
                };
              };
            };

            # ---------------------------------------------------------------
            # Notifications, launcher, lock screen, idle
            # ---------------------------------------------------------------
            # mako is OFF, and this is the one thing adopting Caelestia
            # genuinely costs.
            #
            # Caelestia force-loads its notification service on shell init --
            # modules/ServiceLoader.qml names `Notifs;` unconditionally, unlike
            # `VPN` right below it, which is gated on a config key -- and
            # services/Notifs.qml stands up a NotificationServer. So it claims
            # org.freedesktop.Notifications, and there is no setting that stops
            # it. Two daemons cannot both hold that bus name.
            #
            # Leaving both enabled would not error, which is exactly why it is
            # the wrong answer: whichever unit registers first silently wins
            # and the other's notifications vanish. A start-order race that
            # works until it doesn't is worse than a deliberate choice, so this
            # is the deliberate choice -- Caelestia draws notifications now.
            #
            # The matugen `mako` template and its `makoctl reload` post-hook
            # went with it. `git revert` of this commit brings back mako, the
            # template and the hand-written bar together.
            services.mako.enable = false;

            programs.rofi = {
              enable = true;
              package = pkgs.rofi;
              # Kept in step with the `font` in the matugen theme below, which
              # is what actually renders. 13 rather than 12 because the panel
              # runs at scale 1 (noughty.hyprland.scale) on ~162 DPI, so every
              # px is literal.
              font = "Inter 13";
              extraConfig = {
                # `modes` is rofi 2.0's spelling; `modi` is the pre-2.0 alias
                # and still parses, but `rofi -dump-config` writes `modes`, so
                # use the name the binary itself prints.
                modes = "combi,drun,run,window";
                # What Super+D actually shows (see the bind below). Order is
                # load-bearing: combi concatenates each sub-mode's matches in
                # *this* order rather than interleaving them, so an already
                # running window always sorts above the .desktop entry that
                # would start a second copy. Type "spotify", hit Enter, and you
                # land on the running Spotify -- rofi activates the window
                # through wlr-foreign-toplevel and Hyprland follows it to
                # whatever workspace it lives on. With nothing running, the
                # same keystrokes fall through to `drun` and launch it.
                #
                # `window` mode works here only because nixpkgs merged
                # rofi-wayland into `rofi` (2025-09-06) and 2.0 speaks
                # foreign-toplevel natively; the old X11 build saw XWayland
                # windows only, which on this desktop is none of them.
                combi-modes = "window,drun,run";
                show-icons = true;
                drun-display-format = "{name}";
                # Class then title, e.g. `spotify   Spotify Premium`. rofi's
                # default also has a `{w}` desktop-number field, which is
                # always empty on Wayland -- foreign-toplevel carries no
                # workspace -- and leaves a ragged gap at the start of the row.
                window-format = "{c}   {t}";
              };
              # A theme *name*, not a path: HM turns this into `@theme
              # "matugen"` in config.rasi, which rofi resolves through its
              # normal theme search path -- and that includes
              # $XDG_DATA_HOME/rofi/themes, where the file below lands. Passing
              # a string also stops HM from trying to generate a theme file of
              # its own, so there is exactly one writer.
              theme = "matugen";
            };

            programs.hyprlock = {
              enable = true;
              settings = {
                source = [ generated.hyprlock ];
                general = {
                  hide_cursor = true;
                };
                background = [
                  {
                    # The live wallpaper, so the lock screen matches the
                    # desktop it locked.
                    path = "screenshot";
                    blur_passes = 3;
                    blur_size = 8;
                  }
                ];
                input-field = [
                  {
                    size = "300, 50";
                    outline_thickness = 2;
                    dots_center = true;
                    outer_color = "$lockAccent";
                    inner_color = "$lockInner";
                    font_color = "$lockForeground";
                    fail_color = "$lockError";
                    placeholder_text = "";
                    position = "0, -40";
                    halign = "center";
                    valign = "center";
                  }
                ];
                label = [
                  {
                    text = "$TIME";
                    font_size = 64;
                    font_family = "Inter";
                    color = "$lockForeground";
                    position = "0, 120";
                    halign = "center";
                    valign = "center";
                  }
                ];
              };
            };

            services.hypridle = {
              enable = true;
              settings = {
                general = {
                  lock_cmd = "${pkgs.procps}/bin/pidof hyprlock || ${pkgs.hyprlock}/bin/hyprlock";
                  before_sleep_cmd = "${pkgs.systemd}/bin/loginctl lock-session";
                  after_sleep_cmd = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
                };
                listener = [
                  {
                    timeout = 300;
                    on-timeout = "${pkgs.brightnessctl}/bin/brightnessctl -s set 10%";
                    on-resume = "${pkgs.brightnessctl}/bin/brightnessctl -r";
                  }
                  {
                    timeout = 600;
                    on-timeout = "${pkgs.systemd}/bin/loginctl lock-session";
                  }
                  {
                    timeout = 900;
                    on-timeout = "${pkgs.hyprland}/bin/hyprctl dispatch dpms off";
                    on-resume = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
                  }
                ];
              };
            };

            home.packages = with pkgs; [
              # Tools the bindings above reach for, plus the ones you want in
              # $PATH when you are poking at a Wayland session by hand.
              rofi
              grimblast
              slurp
              # satty is the annotation editor the screenshot binds hand their
              # capture to; swappy stays as the incumbent it replaces there,
              # since it is still a perfectly good `grimblast edit` target and
              # costs nothing to keep. satty wins the bind because swappy has
              # no highlighter and no numbered-marker tool, and exposes
              # copy-then-save only through its global config file rather than
              # per-invocation flags.
              satty
              swappy
              # The display arrangement GUI on Super+P. In $PATH as well as in
              # the bind so `nwg-displays --help` and its one-shot companions
              # (nwg-displays-apply) are reachable from a terminal.
              nwg-displays
              hyprpicker
              cliphist
              wl-clipboard
              brightnessctl
              pavucontrol
              playerctl
              awww
              matugen
              nwg-look
              wlogout
              hyprpolkitagent
            ];

            # Cursor theme -- but only where nobody else defines one. On
            # blac/g14 modules/kde.nix owns this (AeroThemePlasma's
            # "aero-drop") and a second unconditional definition here would
            # collide with it, which is why this used to be absent entirely.
            # That was wrong for a Hyprland-only host: with kde.nix inert,
            # *nothing* set a cursor, so no cursor theme was installed for the
            # user and XCURSOR_THEME went unset. Clients then ask for a
            # "default" theme that is not on disk and simply draw no pointer --
            # which is how this was found, staring at a login screen with an
            # invisible mouse.
            home.pointerCursor = lib.mkIf (!kdeOwnsCursor) {
              enable = true;
              package = pkgs.bibata-cursors;
              name = cursorName;
              size = cursorSize;
              gtk.enable = true;
              # Writes ~/.icons/default/index.theme and the Xcursor.* Xresources
              # -- where XWayland clients look, which GTK/Qt-on-Wayland do not.
              x11.enable = true;
            };
          }

          # -------------------------------------------------------------------
          # Wallpaper rotation + wallpaper-derived colours. Split out so that
          # setting noughty.hyprland.wallpaperDir = null leaves a perfectly
          # usable static-colour session.
          # -------------------------------------------------------------------
          (lib.mkIf themingEnabled {
            xdg.configFile."matugen/config.toml".source =
              (pkgs.formats.toml { }).generate "matugen-config.toml" matugenConfig;

            # The "matugen" theme named above. Named colours only -- every
            # literal comes from the file matugen rewrites, imported by
            # absolute path because this theme is a store symlink and a
            # relative import would resolve next to it in /nix/store.
            # $XDG_DATA_HOME/rofi/themes is one of rofi's own theme
            # directories, which is how `@theme "matugen"` finds it.
            xdg.dataFile."rofi/themes/matugen.rasi".text = ''
              @import "${generated.rofi}"

              /* Every widget rofi draws is styled explicitly. The first cut of
                 this theme set only window/inputbar/listview/element and looked
                 bad for three specific reasons, all of which are defaults you
                 have to opt out of rather than things you add:
                   - `element` was styled but `element-text`/`element-icon` were
                     not, so the text kept its own opaque background and sat
                     top-aligned next to the icon instead of centred on it;
                   - `element selected` is loose syntax. rofi's states are
                     two-part (<row state>.<mode>), and without the normal/
                     active/urgent variants the selection colour only applied
                     to some rows;
                   - no `mainbox`, `prompt` or `entry` rules, so the search line
                     ran into the edge of the window at rofi's default padding.
              */
              * {
                  font:             "Inter 13";
                  background-color: transparent;
                  text-color:       @foreground;
              }

              window {
                  width:            32%;
                  border:           2px;
                  border-color:     @selected;
                  border-radius:    16px;
                  background-color: @background;
                  padding:          0;
              }

              mainbox {
                  padding:  16px;
                  spacing:  14px;
                  children: [ inputbar, listview ];
              }

              inputbar {
                  background-color: @background-alt;
                  border-radius:    12px;
                  padding:          12px 14px;
                  spacing:          10px;
                  children:         [ prompt, entry ];
              }

              /* Same reasoning as the element states: rofi's default theme
                 gives prompt/entry a text-color from its own light palette, so
                 both are set explicitly rather than left to inherit. */
              prompt {
                  background-color: transparent;
                  text-color:       @selected;
                  vertical-align:   0.5;
              }

              entry {
                  background-color:  transparent;
                  text-color:        @foreground;
                  placeholder:       "Search";
                  placeholder-color: @outline;
                  vertical-align:    0.5;
              }

              listview {
                  lines:        7;
                  columns:      1;
                  spacing:      4px;
                  scrollbar:    true;
                  fixed-height: false;
              }

              scrollbar {
                  handle-color:  @selected;
                  handle-width:  4px;
                  border-radius: 4px;
              }

              element {
                  padding:       10px 12px;
                  spacing:       12px;
                  border-radius: 10px;
                  children:      [ element-icon, element-text ];
              }

              /* <row state>.<mode>. "normal" here is the mode, not the state.
                 background-color is spelled out on EVERY state, which is the
                 actual fix for rows rendering as white blocks: rofi's built-in
                 theme carries `element normal.normal { background-color:
                 var(normal-background) }`, and that palette is Solarized
                 *light* (background is rgba(253,246,227)). A plain
                 `element { background-color: transparent }` does not beat it —
                 a state rule is more specific — and `element selected` is not
                 even valid state syntax, so the old theme only ever recoloured
                 the border. Setting each state explicitly leaves nothing to
                 fall back to. */
              element normal.normal    { background-color: transparent; text-color: @foreground; }
              element alternate.normal { background-color: transparent; text-color: @foreground; }
              element normal.active    { background-color: transparent; text-color: @active; }
              element normal.urgent    { background-color: transparent; text-color: @urgent; }
              element alternate.active { background-color: transparent; text-color: @active; }
              element alternate.urgent { background-color: transparent; text-color: @urgent; }
              element selected.normal  { background-color: @selected; text-color: @on-selected; }
              element selected.active  { background-color: @active;   text-color: @background; }
              element selected.urgent  { background-color: @urgent;   text-color: @background; }

              element-icon {
                  size:           28px;
                  text-color:     inherit;
                  vertical-align: 0.5;
              }

              element-text {
                  text-color:     inherit;
                  vertical-align: 0.5;
              }

              message {
                  padding:          10px;
                  border-radius:    10px;
                  background-color: @background-alt;
              }

              textbox { text-color: @foreground; }
            '';

            # GTK: HM keeps ownership of gtk.css (it writes that file itself
            # for GTK4 whenever a theme is set), and these imports point it at
            # the colours matugen owns. `lines` merges, so this appends to
            # anything another module has put in extraCss.
            #
            # The import is unconditional because gtk.css is user-wide, but the
            # *target* is session-scoped -- see clearGtkColors above. Under
            # Plasma the imported file is empty and this is a no-op.
            gtk.gtk3.extraCss = ''
              @import url("file://${generated.gtk3}");
            '';
            gtk.gtk4.extraCss = ''
              @import url("file://${generated.gtk4}");
            '';

            # Empties the GTK colour files when the Hyprland session ends, so
            # Plasma keeps its own GTK theme. Nothing to do on start: the
            # wallpaper timer refills them moments later. RemainAfterExit is
            # what makes ExecStop run at session teardown rather than
            # immediately after ExecStart returns.
            systemd.user.services.hyprland-gtk-colors = {
              Unit = {
                Description = "Scope the wallpaper-derived GTK colours to the Hyprland session";
                PartOf = [ "hyprland-session.target" ];
              };
              Service = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${pkgs.coreutils}/bin/true";
                ExecStop = "${clearGtkColors}";
              };
              Install.WantedBy = [ "hyprland-session.target" ];
            };

            # The wallpaper daemon. Bound to hyprland-session.target, so it
            # never comes up under Plasma.
            systemd.user.services.awww-daemon = {
              Unit = {
                Description = "awww (swww) wallpaper daemon";
                PartOf = [ "hyprland-session.target" ];
                After = [ "hyprland-session.target" ];
              };
              Service = {
                # Not oneshot: this is the daemon that holds the layer-shell
                # surface. `--no-cache` because the wallpaper is chosen fresh
                # on every rotation and a restored cached one would briefly
                # contradict the colours on screen.
                ExecStart = "${pkgs.awww}/bin/awww-daemon --no-cache";
                Restart = "on-failure";
                RestartSec = 2;
              };
              Install.WantedBy = [ "hyprland-session.target" ];
            };

            systemd.user.services.hyprland-wallpaper = {
              Unit = {
                Description = "Pick a wallpaper and re-derive the colour scheme from it";
                PartOf = [ "hyprland-session.target" ];
                After = [ "awww-daemon.service" ];
                Requires = [ "awww-daemon.service" ];
              };
              Service = {
                Type = "oneshot";
                ExecStart = "${rotate}";
              };
            };

            systemd.user.timers.hyprland-wallpaper = {
              Unit.Description = "Rotate the wallpaper (and the colour scheme with it)";
              Timer = {
                # A couple of seconds after the session comes up, then every
                # interval. AccuracySec keeps it from being coalesced into a
                # ragged schedule; Persistent is deliberately absent, since a
                # missed rotation while logged out is not worth catching up.
                OnActiveSec = 3;
                OnUnitActiveSec = wallpaperInterval;
                AccuracySec = "5s";
              };
              Install.WantedBy = [ "hyprland-session.target" ];
            };

            # nwg-displays' two files, seeded empty for exactly the reason the
            # colour files below are seeded: `extraConfig` `source`s them, and
            # Hyprland calls a missing `source` a config error. nwg-displays
            # does create them itself, but only when it is first run, which on
            # a fresh host is strictly after the first login that has to parse
            # this config.
            #
            # Empty is the right seed rather than a copy of the fallback
            # `monitor=` rule: an empty file says "the GUI has not been used
            # here", which leaves `monitor=,preferred,auto,<scale>` in the
            # generated config as the thing actually in charge. As with the
            # colours, an existing file is never touched -- the GUI's output
            # is user state and an activation must not clobber it.
            home.activation.hyprlandDisplays = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
              if [ -z "''${DRY_RUN:-}" ]; then
                for f in ${lib.escapeShellArgs [ monitorsConf workspacesConf ]}; do
                  if [ ! -e "$f" ]; then
                    verboseEcho "Seeding $f for nwg-displays"
                    $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$f")"
                    $DRY_RUN_CMD ${pkgs.coreutils}/bin/touch "$f"
                  fi
                done
              fi
            '';

            # Seed every generated file, so the very first Hyprland login --
            # before the timer has ever fired -- finds them present. Without
            # this, Hyprland reports a config error for the missing `source`
            # and rofi refuses its theme. (The bar is the one consumer that
            # copes on its own -- see the fallback palette in shell.qml.)
            #
            # Only ever creates what is missing: a real rotation's output must
            # never be clobbered by an activation. Uses matugen itself rather
            # than a checked-in palette, so the seed is a genuine scheme --
            # and falls back to writing empty files if no wallpaper is
            # readable yet, which is enough for every consumer to parse.
            home.activation.hyprlandColors = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
              if [ -z "''${DRY_RUN:-}" ]; then
                # The groupbar mode file is `source`d too, so it has the same
                # must-exist-or-it-is-a-config-error property as the colour
                # files -- but it is user state, not matugen output, so it is
                # seeded on its own terms: written once with Hyprland's own
                # default (tabbed), and never touched again. The toggle keybind
                # owns it from then on.
                if [ ! -e ${lib.escapeShellArg groupbarMode} ]; then
                  verboseEcho "Seeding the Hyprland groupbar mode (tabbed)"
                  $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p \
                    "$(${pkgs.coreutils}/bin/dirname ${lib.escapeShellArg groupbarMode})"
                  $DRY_RUN_CMD ${pkgs.coreutils}/bin/printf \
                    'group {\n    groupbar {\n        stacked = 0\n    }\n}\n' \
                    > ${lib.escapeShellArg groupbarMode}
                fi

                seeded=0
                for f in ${lib.escapeShellArgs (lib.attrValues generated)}; do
                  if [ ! -e "$f" ]; then
                    seeded=1
                  fi
                done

                if [ "$seeded" = 1 ]; then
                  verboseEcho "Seeding Hyprland colour files from a wallpaper"
                  for f in ${lib.escapeShellArgs (lib.attrValues generated)}; do
                    $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$f")"
                  done

                  seed="$(${pkgs.findutils}/bin/find -L ${lib.escapeShellArg (toString wallpaperDir)} \
                      -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
                                 -o -iname '*.webp' \) -print0 2>/dev/null \
                    | ${pkgs.coreutils}/bin/head -z -n1 \
                    | ${pkgs.coreutils}/bin/tr -d '\0')"

                  if [ -n "$seed" ]; then
                    # post_hooks would try to reload a compositor that is not
                    # running during activation, so they are tolerated failing;
                    # matugen itself still writes every template.
                    ${pkgs.matugen}/bin/matugen --quiet --source-color-index 0 \
                      --type ${lib.escapeShellArg colorScheme} \
                      --mode ${lib.escapeShellArg colorMode} \
                      image "$seed" < /dev/null || true
                  fi

                  # Whatever matugen did or did not manage, guarantee the files
                  # exist -- an absent one is a startup error for its consumer,
                  # an empty one is not.
                  for f in ${lib.escapeShellArgs (lib.attrValues generated)}; do
                    [ -e "$f" ] || ${pkgs.coreutils}/bin/touch "$f"
                  done

                  # ...except the GTK pair, which must start out EMPTY. gtk.css
                  # is user-wide, so a seeded-with-colours file would recolour
                  # the Plasma session's GTK apps from the next login onwards,
                  # before Hyprland had ever been used. They are filled in by
                  # the first wallpaper rotation inside a Hyprland session and
                  # emptied again when it ends (see clearGtkColors).
                  ${pkgs.coreutils}/bin/truncate -s 0 \
                    ${lib.escapeShellArgs [ generated.gtk3 generated.gtk4 ]} || true
                fi
              fi
            '';

            # Load hy3 into an ALREADY-RUNNING session.
            #
            # `exec-once` covers a fresh login and nothing else -- it does not
            # re-run on `hyprctl reload`, by design. So rebuilding while logged
            # into Hyprland lands the new config in a session where the plugin
            # was never loaded: Home Manager's own onChange reload re-parses it,
            # `general:layout = hy3` is accepted (an unregistered layout is not
            # an error), and every `hy3:` bind is rejected with "Invalid
            # dispatcher" and dropped. The visible result is a config-error
            # banner plus dead alt-keys until the next logout/login, which is a
            # miserable way to find out.
            #
            # This closes that gap: load the plugin, then reload so the binds
            # register. Both are safe to repeat -- a second load is refused with
            # "Cannot load a plugin twice!" and exit 0, leaving the one
            # instance alone.
            #
            # Runs after `writeBoundary`, i.e. after linkGeneration has already
            # fired Home Manager's onChange reload, so the ordering is
            # load-then-reload and the binds land. The XDG_RUNTIME_DIR dance and
            # the instance loop are lifted from HM's own reloadConfig: an
            # activation has no session environment to inherit, and there may be
            # more than one compositor running.
            home.activation.hyprlandHy3Plugin = lib.mkIf hy3 (
              lib.hm.dag.entryAfter [ "writeBoundary" ] ''
                if [ -z "''${DRY_RUN:-}" ]; then
                  XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}"
                  export XDG_RUNTIME_DIR
                  if [ -d "/tmp/hypr" ] || [ -d "$XDG_RUNTIME_DIR/hypr" ]; then
                    for i in $(${hyprctl} instances -j 2>/dev/null \
                      | ${pkgs.jq}/bin/jq -r '.[].instance' 2>/dev/null); do
                      verboseEcho "Loading hy3 into Hyprland instance $i"
                      ${hyprctl} -i "$i" plugin load ${hy3Plugin} >/dev/null 2>&1 || true
                      ${hyprctl} -i "$i" reload config-only >/dev/null 2>&1 || true
                    done
                  fi
                fi
              ''
            );
          })
        ]
      );
    };
}
