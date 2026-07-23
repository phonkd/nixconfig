#!/usr/bin/env bash
# cc-sync: deterministic projection of in-flight nixconfig work onto the
# SilverBullet "Engineering" page. NO LLM — the cheap main model wouldn't
# reliably follow the filtering, so this is a plain script run via
# `hermes cron ... --no-agent --script cc-sync.sh`. Sole writer of that page.
#
# Two sources only (deploy-stage detection was dropped on purpose — see
# plans/hermes-task-calendar.md): unexecuted plans + open PRs. On success it
# PUTs the page and prints a one-line summary; if the page is unchanged it
# prints nothing (empty stdout => cron delivers nothing).
set -uo pipefail

REPO="phonkd/nixconfig"
SB="http://127.0.0.1:9121"
TOKEN_FILE="/run/secrets/silverbullet-token"

# The `--no-agent` cron subprocess does NOT inherit the hermes-agent
# service's EnvironmentFile vars, so gh would run unauthenticated. Pull the
# token straight from its sops secret if it isn't already in the env.
if [ -z "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ] && [ -r /run/secrets/hermes-github ]; then
  set -a; . /run/secrets/hermes-github; set +a
fi

command -v gh   >/dev/null || { echo "cc-sync: gh missing"   >&2; exit 1; }
command -v curl >/dev/null || { echo "cc-sync: curl missing" >&2; exit 1; }
[ -r "$TOKEN_FILE" ] || { echo "cc-sync: no silverbullet token" >&2; exit 1; }
TOKEN="$(cat "$TOKEN_FILE")"

# --- gather sources; abort (leave page untouched) if GitHub is unreachable ---
plan_names="$(gh api "repos/$REPO/contents/plans" --jq '.[].name' 2>/dev/null)" \
  || { echo "cc-sync: gh plans list failed" >&2; exit 1; }
prs="$(gh pr list --repo "$REPO" --state open --json number,title \
        --jq '.[] | "- [ ] review & merge PR #\(.number): \(.title) #cc"' 2>/dev/null)" \
  || { echo "cc-sync: gh pr list failed" >&2; exit 1; }

# --- build the page body ---
tmp="$(mktemp)"
{
  echo "# Engineering"
  echo
  echo "<!-- Rewritten by cc-sync (deterministic script, sole writer). Don't"
  echo "edit by hand — act on the plan/PR; this page follows reality next tick."
  echo "Projection of unexecuted plans + open PRs only; no deploy detection. -->"
  echo

  # Plans whose status is NOT finished.
  while IFS= read -r name; do
    case "$name" in *.md) ;; *) continue ;; esac
    body="$(gh api "repos/$REPO/contents/plans/$name" --jq '.content' 2>/dev/null \
              | tr -d '\n' | base64 -d 2>/dev/null)" || continue
    status_line="$(printf '%s\n' "$body" | grep -im1 'status' || true)"
    # Finished states are excluded; everything else (incl. no status) is shown.
    if printf '%s' "$status_line" \
         | grep -qiE 'done|deployed|superseded|complete|abandon|shipped|dropped'; then
      continue
    fi
    echo "- [ ] execute plan ${name%.md} #cc"
  done <<< "$plan_names"

  # Open PRs.
  [ -n "$prs" ] && printf '%s\n' "$prs"
} > "$tmp"

# --- write only if changed ---
cur="$(curl -s -H "Authorization: Bearer $TOKEN" "$SB/.fs/Engineering.md" 2>/dev/null || true)"
new="$(cat "$tmp")"
if [ "$new" = "$cur" ]; then
  rm -f "$tmp"
  exit 0    # unchanged -> silent
fi

code="$(curl -sS -X PUT "$SB/.fs/Engineering.md" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: text/markdown" \
          --data-binary @"$tmp" -o /dev/null -w '%{http_code}')"
rm -f "$tmp"
if [ "$code" != "200" ]; then
  echo "cc-sync: PUT failed (HTTP $code)" >&2
  exit 1
fi
plans_n="$(printf '%s\n' "$new" | grep -c 'execute plan')"
prs_n="$(printf '%s\n' "$new" | grep -c 'review & merge')"
echo "cc-sync: updated Engineering — ${plans_n} plan(s), ${prs_n} open PR(s)"
