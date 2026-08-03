{ inputs, ... }:

{
  flake.homeModules.terminal =
    { pkgs, lib, ... }:
    let
      # Fuzzy tab picker that spans every running kitty. Each kitty window here
      # is its own process with its own control socket, so the usual pickers
      # (built-in select_tab, kitty-tab-switcher) only ever see the OS window
      # they were launched from; this one walks all the sockets.
      #
      # writeShellScriptBin rather than writeShellApplication: the latter forces
      # `set -o errexit`, which would kill the script when fzf exits non-zero
      # (Esc with no selection) or when a grep finds nothing.
      kitty-tab-search = pkgs.writeShellScriptBin "kitty-tab-search" ''
        # kitty's remote-control protocol is version-matched, and the kitty that
        # actually runs on this Mac is the Homebrew cask in /Applications, not
        # pkgs.kitty. So: our own tools first, then the inherited PATH (whose
        # `kitten` belongs to the running kitty), and pkgs.kitty only as a
        # last-resort fallback for a machine without one installed.
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
          font_size = 16;
          clipboard_control = "write-clipboard write-primary read-clipboard no-append";
          # Smoother redraws for fast-updating TUIs like cava.
          repaint_delay = 6;
          input_delay = 1;
          sync_to_monitor = "yes";
          # Translucent background with strong macOS blur behind it.
          background_opacity = "0.6";
          background_blur = 64;
          # One control socket per kitty process, named after its pid, so
          # kitty-tab-search can enumerate every instance. socket-only leaves
          # the escape-code control channel closed — anything that can write to
          # the tty would otherwise be able to drive the terminal.
          allow_remote_control = "socket-only";
          listen_on = "unix:/tmp/kitty-{kitty_pid}";
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
