# `claude-codex` -- run the normal Claude Code CLI on the ChatGPT/Codex
# subscription instead of the Anthropic one.
#
# Claude Code only ever speaks the Anthropic Messages API, so the switch is a
# local router (upstream: fcakyon/claude-code-with-codex, a fork of
# raine/claude-code-proxy) that Claude Code is pointed at with
# ANTHROPIC_BASE_URL. It dispatches per model name: `claude-*` is relayed
# untouched to api.anthropic.com on the subscription token Claude Code already
# sends, `gpt-*` is translated to the OpenAI Responses API and sent to the
# Codex backend. It stores no Anthropic credentials of its own.
#
# The ChatGPT side reuses the Codex CLI's own login at ~/.codex/auth.json --
# nothing to declare here, no sops secret, and deliberately so: the router
# refreshes that token and writes it back, so a nix-managed copy would go
# stale or clobber a refresh (same reasoning as hermes' auth.json on
# 204-agent). `codex login` is the only enrolment step.
#
# ANTHROPIC_BASE_URL is set per-invocation by the shell function below rather
# than in ~/.claude/settings.json, which is what upstream's README suggests:
# the settings.json route sends *every* `claude` session through the proxy,
# including ordinary Anthropic ones, for no benefit. Plain `claude` stays
# completely untouched; only `claude-codex` opts in.
{
  self,
  inputs,
  ...
}:
{
  perSystem =
    { pkgs, lib, ... }:
    {
      packages.claude-codex = pkgs.rustPlatform.buildRustPackage {
        pname = "claude-codex";
        # Tracks the tag pinned in flake.nix; bump both together.
        version = "0.3.1";
        src = inputs.claude-codex;
        cargoLock.lockFile = "${inputs.claude-codex}/Cargo.lock";

        # TLS is rustls throughout (reqwest/tokio-rustls with default-features
        # off), so there's no openssl/pkg-config to wire up on either platform.

        # Upstream's integration tests drive the real Codex and Anthropic
        # endpoints with a live login -- no network or credentials in the
        # sandbox, and nothing here patches them out.
        doCheck = false;

        meta = {
          description = "Anthropic-API router that runs Claude Code on a ChatGPT/Codex subscription";
          homepage = "https://github.com/fcakyon/claude-code-with-codex";
          license = lib.licenses.mit;
          platforms = lib.platforms.linux ++ lib.platforms.darwin;
          mainProgram = "claude-codex";
        };
      };
    };

  # Imported from the cross-platform `gui` type: both the NixOS desktops (where
  # `claude` and `codex` come from the claude-code-nix input and unstable) and
  # the Mac (where both are homebrew casks) have the two CLIs on PATH.
  flake.homeModules.claude-codex =
    { pkgs, ... }:
    {
      home.packages = [ self.packages.${pkgs.system}.claude-codex ];

      # A function, not a shellAlias: it has to bring the router up first. The
      # binary and the function share the name `claude-codex` on purpose --
      # hence `command` on every internal call, or the function recurses (same
      # pattern as `jj` in modules/shell.nix).
      programs.zsh.siteFunctions.claude-codex = ''
        local port=''${CLAUDE_CODEX_PORT:-18765}
        local url="http://127.0.0.1:$port"
        local log=''${XDG_STATE_HOME:-$HOME/.local/state}/claude-codex.log

        # Liveness by connect, not by status: the router has no health route
        # and 404s on /, but plain `curl` (no -f) still exits 0 on a 404 and
        # only fails when nothing is listening.
        if ! curl -s -o /dev/null --max-time 2 "$url"; then
          if ! command claude-codex codex auth status >/dev/null 2>&1; then
            print -u2 "claude-codex: no ChatGPT/Codex login found -- run \`codex login\` first"
            return 1
          fi
          mkdir -p "''${log:h}"
          # &! is background+disown: the router outlives this shell, so the
          # next `claude-codex` in any terminal reuses it.
          PORT=$port command claude-codex serve >>"$log" 2>&1 &!
          local i
          for i in {1..100}; do
            curl -s -o /dev/null --max-time 1 "$url" && break
            sleep 0.1
          done
          if ! curl -s -o /dev/null --max-time 1 "$url"; then
            print -u2 "claude-codex: router never came up on port $port -- see $log"
            return 1
          fi
        fi

        # ANTHROPIC_MODEL is what actually moves inference to ChatGPT; without
        # it Claude Code asks for a claude-* model and the router dutifully
        # relays that to Anthropic. `[1m]` is Claude Code's large-context
        # opt-in, stripped by the router before the model id goes on the wire.
        # `claude-codex models` lists the ids; override with CLAUDE_CODEX_MODEL.
        #
        # Deliberately NOT setting ANTHROPIC_AUTH_TOKEN/ANTHROPIC_API_KEY:
        # either one overrides the Claude subscription login and makes the
        # claude-* route 401, which is the escape hatch when a Codex model
        # chokes mid-session.
        ANTHROPIC_BASE_URL="$url" \
        ANTHROPIC_MODEL="''${CLAUDE_CODEX_MODEL:-gpt-5.6-sol[1m]}" \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
          command claude "$@"
      '';
    };
}
