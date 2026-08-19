{ ... }:

{
  # `claude-zai` -- run Claude Code against Z.AI's GLM models instead of
  # Anthropic's.
  #
  # Z.AI serves an Anthropic-compatible API at api.z.ai/api/anthropic, so the
  # CLI itself needs no patching: point ANTHROPIC_BASE_URL at it, hand it a
  # Z.AI key as ANTHROPIC_AUTH_TOKEN, and map the three model tiers Claude Code
  # asks for onto GLM ones. Values are Z.AI's own documented defaults, see
  # https://docs.z.ai/devpack/tool/claude.
  #
  # Why a launcher and not `env` in ~/.claude/settings.json -- which is the
  # setup Z.AI's docs actually walk you through: that file is read by EVERY
  # Claude Code session on the machine, including the background-agent daemon
  # and every FleetView job. Putting the override there silently moves all of
  # it off the Anthropic subscription, and the daemon is long-running enough
  # that you would not notice until a bill or a quality drop. Keeping it in a
  # function means `claude` is untouched and `claude-zai` is a deliberate act.
  #
  # The key is NOT in the nix store: it is read at call time from Vaultwarden
  # via secretspec (modules/secretspec.nix), so this module is safe to check in.
  flake.homeModules.claude-zai =
    { ... }:
    {
      programs.zsh.siteFunctions.claude-zai = ''
        local key
        # secretspec finds its manifest by walking up from $PWD, and this
        # function is meant to be run from any project directory -- not just
        # inside nixconfig. Pin the manifest to the store copy so the lookup
        # does not depend on where you happen to be standing.
        key=$(SECRETSPEC_FILE=${../secretspec.toml} \
          command secretspec get --reason "claude-zai launcher" ZAI_API_KEY) || {
          print -u2 "claude-zai: could not read ZAI_API_KEY."
          print -u2 "  vault locked?  -> run: bwu"
          print -u2 "  item missing?  -> add a Bitwarden login item named 'Z.AI API Key',"
          print -u2 "                    with the key from https://z.ai/manage-apikey/apikey-list"
          print -u2 "                    as its password."
          return 1
        }
        if [[ -z "$key" ]]; then
          print -u2 "claude-zai: ZAI_API_KEY resolved to an empty value; refusing to start."
          return 1
        fi
        # Prefix assignments rather than `export`: they apply to this one
        # process, so the calling shell is never left quietly pointed at Z.AI.
        ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic" \
        ANTHROPIC_AUTH_TOKEN="$key" \
        ANTHROPIC_DEFAULT_OPUS_MODEL="GLM-4.7" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="GLM-4.7" \
        ANTHROPIC_DEFAULT_HAIKU_MODEL="GLM-4.5-Air" \
        API_TIMEOUT_MS="3000000" \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1" \
          command claude "$@"
      '';
    };
}
