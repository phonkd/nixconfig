#!/usr/bin/env bash
# Version snapshot + diff report behind the weekly flake.lock update PR
# (.github/workflows/flake-update.yml). Runs the same on the Mac.
#
#   scripts/flake-versions.sh snapshot OUT.json
#       Evaluate every nixos/darwin host of this checkout, as currently locked,
#       and write {"hosts": {"<host>": {"<pname>": {kind, versions}}},
#       "failed": [hosts that did not evaluate]}.
#
#   scripts/flake-versions.sh report BEFORE.json AFTER.json OLD.lock NEW.lock
#       Print the PR body as markdown: software whose version changed
#       (paperless-ngx 2.14.1 -> 2.15.0), then the flake inputs that moved.
#
# blac and g14 import /etc/nixos/hardware-configuration.nix, so they cannot
# evaluate on a CI runner; they end up in "failed" and the report names them.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
flake="git+file://$root"
# actions/checkout clones with depth 1, and nix refuses a shallow repo as a
# flake unless the ref says so.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  flake+="?shallow=1"
fi

snapshot() {
  local out=$1 tmp kind host
  local -a failed=()
  tmp=$(mktemp -d)
  for kind in nixos darwin; do
    for host in $(nix eval --json "$flake#${kind}Configurations" --apply builtins.attrNames | jq -r '.[]'); do
      echo "::group::evaluating $kind $host" >&2
      if nix eval --impure --json --expr \
        "import $root/scripts/flake-versions.nix { flakeRef = \"$flake\"; host = \"$host\"; kind = \"$kind\"; }" \
        >"$tmp/$host.json"; then
        :
      else
        failed+=("$host")
        rm -f "$tmp/$host.json"
      fi
      echo "::endgroup::" >&2
    done
  done

  for f in "$tmp"/*.json; do
    jq --arg h "$(basename "$f" .json)" '{($h): .}' "$f"
  done | jq -s --args '{hosts: add, failed: $ARGS.positional}' "${failed[@]}" >"$out"
  rm -rf "$tmp"
}

report() {
  jq -nr \
    --slurpfile before "$1" --slurpfile after "$2" \
    --slurpfile oldlock "$3" --slurpfile newlock "$4" '
    ($before[0]) as $b | ($after[0]) as $a
    # Compare only hosts that evaluated both times; otherwise a host that
    # failed once would show all of its software as added or removed.
    | ([$b.hosts, $a.hosts] | map(keys) | .[0] - (.[0] - .[1])) as $hosts

    | def software($snap):
        [$snap.hosts | to_entries[] | select(.key | IN($hosts[]))
         | .key as $h | .value | to_entries[]
         | {name: .key, kind: .value.kind, versions: .value.versions, host: $h}]
        | group_by(.name)
        | map({key: .[0].name, value: {
            kind: (if any(.[]; .kind == "service") then "service" else "package" end),
            versions: (map(.versions[]) | unique),
            hosts: (map(.host) | unique)}})
        | from_entries;

      def bump($old; $new):
        if ($old | length) == 0 then "new"
        elif ($new | length) == 0 then "removed"
        elif ($old + $new | any(test("unstable|-pre|git"))) then "unstable"
        else
          [($old | last | split(".")), ($new | last | split("."))] as [$o, $n]
          | (first(range(0; [$o, $n] | map(length) | max) | select($o[.] != $n[.])) // 3) as $i
          | if $i == 0 then "**major**" elif $i == 1 then "minor" else "patch" end
        end;

      def table($rows):
        "| Name | Version | Bump | Hosts |",
        "|---|---|---|---|",
        ($rows[] | "| \(.name) | \(.old | join(", ") | if . == "" then "—" else . end) → \(.new | join(", ") | if . == "" then "—" else . end) | \(.bump) | \(.hosts | join(", ")) |");

      def lockinputs($lock):
        $lock.nodes as $n
        | $lock.nodes[$lock.root].inputs
        | with_entries(select(.value | type == "string") | .value = $n[.value]);

      def inputurl($o; $n):
        $n.locked as $l
        | if $l.type == "github" then "https://github.com/\($l.owner)/\($l.repo)/compare/\($o.locked.rev)...\($l.rev)"
          elif $l.type == "gitlab" then "https://gitlab.com/\($l.owner)/\($l.repo)/-/compare/\($o.locked.rev)...\($l.rev)"
          else null end;

      def day: if . == null then "—" else todate[:10] end;

    software($b) as $sb | software($a) as $sa
    | [($sb + $sa) | keys[] as $k
       | {name: $k,
          kind: (($sa[$k] // $sb[$k]).kind),
          old: ($sb[$k].versions // []),
          new: ($sa[$k].versions // []),
          hosts: (($sa[$k] // $sb[$k]).hosts)}
       | select(.old != .new)
       | .bump = bump(.old; .new)] as $changed
    | ($changed | map(select(.kind == "service"))) as $svc
    | ($changed | map(select(.kind == "package"))) as $pkg
    | 400 as $cap

    | lockinputs($oldlock[0]) as $li | lockinputs($newlock[0]) as $ln
    | [$ln | to_entries[] | .key as $k
       | select($li[$k].locked.rev != .value.locked.rev)
       | {name: $k, old: $li[$k], new: .value}] as $inputs

    | "## Software versions",
      "",
      "Compared on: \($hosts | join(", "))" + (if ($a.failed | length) > 0 then " · not evaluable in CI: \($a.failed | join(", "))" else "" end),
      "",
      "### Services (\($svc | length) changed)",
      "",
      (if ($svc | length) == 0 then "_No enabled service changed version._" else table($svc) end),
      "",
      "### Packages (\($pkg | length) changed)",
      "",
      "System and home-manager packages.",
      "",
      "<details><summary>Show packages</summary>",
      "",
      (if ($pkg | length) == 0 then "_No package changed version._" else table($pkg[:$cap]) end),
      (if ($pkg | length) > $cap then "", "_…and \(($pkg | length) - $cap) more._" else empty end),
      "",
      "</details>",
      "",
      "## Flake inputs (\($inputs | length) updated)",
      "",
      "| Input | Locked | Diff |",
      "|---|---|---|",
      ($inputs[] | "| \(.name) | \(.old.locked.lastModified | day) → \(.new.locked.lastModified | day) | \(inputurl(.old; .new) as $u | if $u then "[compare](\($u))" else "—" end) |")
  '
}

case ${1:-} in
  snapshot) snapshot "$2" ;;
  report) report "$2" "$3" "$4" "$5" ;;
  *)
    echo "usage: $0 snapshot OUT.json | report BEFORE.json AFTER.json OLD.lock NEW.lock" >&2
    exit 2
    ;;
esac
