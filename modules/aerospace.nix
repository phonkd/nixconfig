{ self, inputs, ... }:
{
  flake.darwinModules.aerospace =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    lib.mkIf config.noughty.host.is.darwinDesktop {
      services.aerospace = {
        enable = true;
        settings = {
          after-login-command = [ ];
          after-startup-command = [ ];
          enable-normalization-flatten-containers = true;
          enable-normalization-opposite-orientation-for-nested-containers = true;
          accordion-padding = 30;
          default-root-container-layout = "tiles";
          default-root-container-orientation = "auto";
          on-focused-monitor-changed = [ "move-mouse monitor-lazy-center" ];
          automatically-unhide-macos-hidden-apps = true;
          key-mapping.preset = "qwerty";
          gaps = {
            inner.horizontal = 6;
            inner.vertical = 6;
            outer.left = 6;
            outer.bottom = 6;
            outer.top = 6;
            outer.right = 6;
          };
          mode.main.binding = {
            alt-shift-comma = "layout tiles horizontal vertical";
            alt-comma = "layout accordion horizontal vertical";
            alt-h = "focus left";
            alt-j = "focus down";
            alt-k = "focus up";
            alt-l = "focus right";
            alt-shift-h = "move left";
            alt-shift-j = "move down";
            alt-shift-k = "move up";
            alt-shift-l = "move right";
            alt-slash = "join-with left";
            alt-equal = "resize smart +50";
            # built-in display
            alt-q = "workspace Q";
            alt-w = "workspace W";
            alt-e = "workspace E";
            # external display 2
            alt-a = "workspace A";
            alt-s = "workspace S";
            alt-d = "workspace D";
            # external display 3
            alt-u = "workspace Y";
            alt-i = "workspace X";
            alt-o = "workspace C";
            alt-shift-q = "move-node-to-workspace Q";
            alt-shift-w = "move-node-to-workspace W";
            alt-shift-e = "move-node-to-workspace E";
            alt-shift-a = "move-node-to-workspace A";
            alt-shift-s = "move-node-to-workspace S";
            alt-shift-d = "move-node-to-workspace D";
            alt-shift-u = "move-node-to-workspace Y";
            alt-shift-i = "move-node-to-workspace X";
            alt-shift-o = "move-node-to-workspace C";
            alt-f = "fullscreen";
            alt-v = "exec-and-forget ${pkgs.kitty}/bin/kitty --directory /Users/phonkd";
            alt-y = "exec-and-forget open -a Zen";
            alt-space = "layout floating tiling";
            alt-tab = "workspace-back-and-forth";
            alt-shift-period = "mode service";
            alt-b = ''exec-and-forget osascript -e "tell application \"System Events\" to key code 100"'';
          };
          on-window-detected = [
            {
              "if" = {
                app-id = "com.apple.systempreferences";
                app-name-regex-substring = "settings";
                window-title-regex-substring = "substring";
                workspace = "workspace-name";
              };
              check-further-callbacks = true;
              run = [ "layout floating" ];
            }
            {
              "if" = {
                app-name-regex-substring = "ClipBook";
                window-title-regex-substring = "substring";
              };
              run = [ "layout floating" ];
            }
          ];
          mode.service.binding = {
            esc = [ "reload-config" "mode main" ];
            r = [ "flatten-workspace-tree" "mode main" ];
            f = [ "layout floating tiling" "mode main" ];
            backspace = [ "close-all-windows-but-current" "mode main" ];
            down = "volume down";
            up = "volume up";
            shift-down = [ "volume set 0" "mode main" ];
          };
          workspace-to-monitor-force-assignment = {
            Q = "built-in";
            W = "built-in";
            E = "built-in";
            A = 1;
            S = 1;
            D = 1;
            Y = 3;
            X = 3;
            C = 3;
          };
        };
      };
    };
}
