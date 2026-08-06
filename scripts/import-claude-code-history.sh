#!/usr/bin/env bash
set -euo pipefail

source_root="${1:-$HOME/.claude/projects}"
destination="${2:-.claude-history}"
project_prefix='-Users-phonkd-git-nixconfig'

mkdir -p "$destination/sessions"

index="$destination/index.md"
{
  echo '# Imported Claude Code history'
  echo
  echo 'Generated from Claude Code JSONL transcripts. Tool calls, tool results, and internal bookkeeping are omitted.'
  echo
  echo '| Date | Session | Source project | First user message |'
  echo '|---|---|---|---|'
} > "$index"

find "$source_root" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' \
  -path "$source_root/$project_prefix*/*" -print0 \
  | sort -z \
  | while IFS= read -r -d '' transcript; do
      project="$(basename "$(dirname "$transcript")")"
      source_name="$(basename "$transcript")"
      session_id="${source_name%%.jsonl}"
      output="$destination/sessions/$session_id.md"

      jq -rs --arg project "$project" --arg session "$session_id" '
        def text_content:
          if (.message.content | type) == "string" then .message.content
          elif (.message.content | type) == "array" then
            [.message.content[]? | select(.type == "text") | .text] | join("\n\n")
          else ""
          end;
        [.[] | select(.type == "user" or .type == "assistant")
          | {role: .message.role, text: text_content, timestamp: .timestamp}
          | select(.text != "")
        ] as $messages
        | "# Claude Code session `\($session)`\n\n"
          + "- Source project: `\($project)`\n"
          + "- Started: \(($messages[0].timestamp // "unknown"))\n\n"
          + ($messages | map(
              "## " + (if .role == "user" then "User" else "Assistant" end)
              + (if .timestamp then " — " + .timestamp else "" end)
              + "\n\n" + .text + "\n"
            ) | join("\n"))
      ' "$transcript" > "$output"

      meta="$(jq -rs '
        def text_content:
          if (.message.content | type) == "string" then .message.content
          elif (.message.content | type) == "array" then
            [.message.content[]? | select(.type == "text") | .text] | join(" ")
          else "" end;
        [.[] | select(.type == "user")
          | {text: text_content, timestamp: .timestamp}
          | select(.text != "")][0]
        | [(.timestamp // "unknown" | split("T")[0]),
           (.text // "(no user message)" | gsub("[\\r\\n|]+"; " ") | .[0:100])]
        | @tsv
      ' -r "$transcript")"
      date="${meta%%$'\t'*}"
      first_message="${meta#*$'\t'}"
      printf '| %s | [%s](sessions/%s.md) | `%s` | %s |\n' \
        "$date" "$session_id" "$session_id" "$project" "$first_message" >> "$index"
    done

session_count="$(find "$destination/sessions" -type f -name '*.md' | wc -l | tr -d ' ')"
printf '\nImported %s sessions.\n' "$session_count" >> "$index"
echo "Imported $session_count sessions into $destination"
