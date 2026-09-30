{ inputs, ... }:

{
  flake.homeModules.terminal =
    { pkgs, lib, ... }:
    let
      # Fuzzy tab picker spanning every running kitty: each is its own process
      # with its own control socket, so the usual pickers (select_tab,
      # kitty-tab-switcher) only see the OS window they were launched from --
      # this one walks all the sockets.
      #
      # writeShellScriptBin, not writeShellApplication: the latter's
      # `set -o errexit` would kill the script on fzf's non-zero exit (Esc,
      # no selection) or an empty grep.
      kitty-tab-search = pkgs.writeShellScriptBin "kitty-tab-search" ''
        # kitty's remote-control protocol is version-matched, and the kitty
        # running on this Mac is the Homebrew cask in /Applications, not
        # pkgs.kitty -- our tools go first, then the inherited PATH (`kitten`
        # from the running kitty), with pkgs.kitty only as a last resort.
        export PATH=${
          lib.makeBinPath [
            pkgs.jq
            pkgs.fzf
            pkgs.gawk
            pkgs.gnused
            pkgs.coreutils
          ]
        }:"$PATH":${lib.makeBinPath [ pkgs.kitty ]}
        ${builtins.readFile ./kitty-tab-search.sh}
      '';
    in
    {
      home.packages = [ kitty-tab-search ];

      programs.kitty = {
        enable = true;
        package = pkgs.kitty;
        themeFile = "cherry-midnight";
        settings = {
          pixel_scroll = "yes";
          # Cursor trail: streaks to the new position instead of teleporting.
          # The 3 is the *trigger* threshold in ms (not animation length) so
          # TUIs that reposition the cursor constantly (nvim's statusline,
          # fzf, cava) don't smear; decay is the fastest/slowest fade pair,
          # in seconds. cursor_trail_start_threshold stays at its default (2
          # cells) since typing advances one cell at a time.
          cursor_trail = 3;
          cursor_trail_decay = "0.1 0.4";
          font_size = 16;
          clipboard_control = "write-clipboard write-primary read-clipboard no-append";
          repaint_delay = 6;
          input_delay = 1;
          sync_to_monitor = "yes";
          confirm_os_window_close = 0;
          background_opacity = "0.6";
          background_blur = 64;
          # One control socket per kitty process (named by pid) so
          # kitty-tab-search can enumerate every instance; socket-only closes
          # the escape-code channel so nothing that can write to the tty can
          # drive the terminal.
          allow_remote_control = "socket-only";
          listen_on = "unix:/tmp/kitty-{kitty_pid}";
        } // lib.optionalAttrs pkgs.stdenv.isLinux {
          # Hyprland quarters scroll deltas; keep kitty's previous wheel and
          # touchpad scroll distance on Linux. The Mac keeps kitty defaults.
          wheel_scroll_multiplier = 20.0;
          touch_scroll_multiplier = 4.0;
        };
        keybindings = {
          "cmd+left" = "send_text all \\x01";
          "cmd+right" = "send_text all \\x05";
          # New tabs/windows inherit the active tab's working directory
          # (relies on shell integration's OSC 7 cwd reporting below).
          "cmd+t" = "new_tab_with_cwd";
          "cmd+enter" = "new_window_with_cwd";
          "cmd+n" = "new_os_window_with_cwd";
          # Overlay so fzf gets a tty; the script reaches other instances over
          # their sockets, so it needs no remote-control grant of its own.
          "cmd+shift+f" = "launch --type=overlay ${kitty-tab-search}/bin/kitty-tab-search";
        };
        shellIntegration.enableZshIntegration = true;
      };
  };
}
