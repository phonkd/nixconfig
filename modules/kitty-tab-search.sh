#!/usr/bin/env bash
# kitty-tab-search — fuzzy-find any kitty tab across *every* running kitty instance.
#
# Each kitty process is its own instance with its own control socket, so the
# usual tab pickers (built-in select_tab, kitty-tab-switcher) only ever see the
# OS window they were invoked from. This walks every socket matching
# listen_on's {kitty_pid} pattern and merges the results.
#
#   default   fast: match on tab title, cwd and the command running right now
#   ctrl-r    deep: dumps every window's scrollback once, then match on that
#             (the "search by ran command" mode; it is the expensive one)
#   ctrl-t    back to tab mode
#   enter     focus that tab
#
# Wired up in modules/terminal.nix. Needs allow_remote_control + listen_on.

set -uo pipefail

SOCKET_GLOB="${KITTY_TAB_SEARCH_SOCKETS:-/tmp/kitty-*}"
SCROLLBACK_LINES="${KITTY_TAB_SEARCH_LINES:-5000}"
KITTEN="${KITTY_TAB_SEARCH_KITTEN:-kitten}"
SEP=$'\t'

sockets() {
	local s
	for s in $SOCKET_GLOB; do
		[[ -S $s ]] && printf '%s\n' "$s"
	done
}

# TSV: socket, os-window id, tab id, window id, display
list_tabs() {
	local sock
	for sock in $(sockets); do
		"$KITTEN" @ --to "unix:$sock" ls 2>/dev/null | jq -r --arg sock "$sock" '
			.[] | .id as $os | .tabs[] |
			(.windows[0] // {}) as $w |
			[ $sock, ($os|tostring), (.id|tostring), (($w.id // 0)|tostring),
			  ((if .is_active then "*" else " " end)
			   + " " + (.title // "?")
			   + "  │ " + (($w.cwd // "") | sub("^" + env.HOME; "~"))
			   # kitty wraps every shell in login + its own kitten; those say
			   # nothing about what the tab is doing, so drop them.
			   + "  │ " + (($w.foreground_processes // [])
			                | map(.cmdline // [] | join(" "))
			                | map(select(. != "" and (test("kitty\\.app|/usr/bin/login|/bin/login") | not)))
			                | unique | join(", "))
			  )
			] | @tsv'
	done
}

# TSV: socket, os-window id, tab id, window id, display — one row per scrollback line
list_deep() {
	local sock
	for sock in $(sockets); do
		"$KITTEN" @ --to "unix:$sock" ls 2>/dev/null | jq -r --arg sock "$sock" '
			.[] | .id as $os | .tabs[] | .id as $tab | .title as $title |
			.windows[] | [ $sock, ($os|tostring), ($tab|tostring), (.id|tostring), $title ] | @tsv' |
		while IFS=$SEP read -r s os tab win title; do
			"$KITTEN" @ --to "unix:$s" get-text --extent all --match "id:$win" 2>/dev/null |
				tail -n "$SCROLLBACK_LINES" |
				sed 's/[[:space:]]*$//' |
				awk -v pfx="$s$SEP$os$SEP$tab$SEP$win$SEP$title  │ " 'NF { print pfx $0 }'
		done
	done
}

# focus the tab described by a selected row
jump() {
	local sock os tab win
	IFS=$SEP read -r sock os tab win _ <<<"$1"
	[[ -n ${sock:-} ]] || return 1
	"$KITTEN" @ --to "unix:$sock" focus-tab --match "id:$tab" >/dev/null 2>&1
	# macOS: a separate kitty process is a separate app instance, so switching
	# its tab does not bring it forward. Ask the window server to raise that pid.
	if [[ $OSTYPE == darwin* ]]; then
		local pid
		pid=$(lsof -t "$sock" 2>/dev/null | head -1)
		[[ -n ${pid:-} ]] && osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1
	fi
}

case "${1:-}" in
--list) list_tabs; exit 0 ;;
--deep) list_deep; exit 0 ;;
--jump) jump "$2"; exit 0 ;;
esac

if [[ -z $(sockets) ]]; then
	cat >&2 <<-EOF
		kitty-tab-search: no kitty control sockets matching $SOCKET_GLOB

		modules/terminal.nix should be setting:
		    allow_remote_control socket-only
		    listen_on unix:/tmp/kitty-{kitty_pid}

		Windows opened before that landed have no socket — restart them.
	EOF
	exit 1
fi

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

selection=$(
	"$self" --list | fzf \
		--delimiter="$SEP" --with-nth=5.. --nth=5.. \
		--ansi --no-sort --cycle \
		--prompt='tab > ' \
		--header=$'enter: focus  │  ctrl-r: search scrollback  │  ctrl-t: back to tabs' \
		--preview="$KITTEN @ --to unix:{1} get-text --extent all --match id:{4} 2>/dev/null | tail -n 60" \
		--preview-window='down,60%,wrap' \
		--bind="ctrl-r:change-prompt(cmd > )+reload($self --deep)" \
		--bind="ctrl-t:change-prompt(tab > )+reload($self --list)"
)

[[ -n ${selection:-} ]] && "$self" --jump "$selection"
exit 0
