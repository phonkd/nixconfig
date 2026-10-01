#!/usr/bin/env bash
# Move modules/homelab/global-secrets/secret.yaml into clan's sops store
# (plans/clan-lol-migration.md, Phase 2), and prove nothing changed.
#
# Output is secret NAMES and statuses only -- never values, and never hashes of
# values (a hash of a short password is brute-forceable). Plaintext only ever
# exists in a private /dev/shm directory that is removed on exit, and anything
# clan prints is scrubbed of every known value before it is shown.
#
# Run inside `nix develop` (clan, sops, jq, age), from the repo:
#
#   plan              read-only: what goes where, plus a config baseline
#   migrate           write sops/ and stage it -- does not commit
#   validate          store round-trip + per-host config diff vs the baseline
#   snapshot HOST...  record HOST's /run/secrets (root-only file on HOST)
#   verify HOST...    compare HOST's /run/secrets against that snapshot
#
# Order: plan, migrate, validate, commit, snapshot all, deploy each, verify each.
#
# Only the six deploy-rs servers get links. z14, blac and the Mac keep reading
# secret.yaml directly, which stays in place: clan declares a secret on a host
# only if it is linked to that host (nixosModules/clanCore/sops.nix).
set -euo pipefail
umask 077

REPO=$(git rev-parse --show-toplevel)
SRC=modules/homelab/global-secrets/secret.yaml
ADMIN=phonkd
HOSTS=(201-mono 203-media 204-agent 205-builder ext-mail observability)
export SOPS_AGE_KEY_FILE=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/clan-secrets-migrate/$(printf %s "$REPO" | sha256sum | cut -c1-12)

# config.sops reduced to metadata. sopsFile becomes the sha256 of the
# encrypted file, which the caller maps back to "src" or "clan:<name>".
APPLY='sops: {
  secrets = builtins.mapAttrs (n: s: {
    inherit (s) key format owner group mode path neededForUsers restartUnits;
    reloadUnits = s.reloadUnits or [ ];
    src = builtins.hashFile "sha256" s.sopsFile;
  }) sops.secrets;
  templates = builtins.mapAttrs (n: t: {
    inherit (t) owner group mode path;
    content = builtins.hashString "sha256" t.content;
  }) sops.templates;
}'

WORK=
cleanup() { if [ -n "$WORK" ]; then rm -rf -- "$WORK"; fi; }
trap cleanup EXIT
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

# Decrypt SRC into the private work dir, and derive the redaction patterns.
open_src() {
  [ -n "$WORK" ] && return
  WORK=$(mktemp -d /dev/shm/clan-secrets-migrate.XXXXXX)
  sops -d --output-type json "$REPO/$SRC" >"$WORK/src.json" 2>"$WORK/err" ||
    die "could not decrypt $SRC with $SOPS_AGE_KEY_FILE"
  jq -r '.[]' "$WORK/src.json" | awk 'length($0) >= 4' >"$WORK/patterns"
}

# Replace every known value with <redacted>, line by line.
redact() {
  awk 'NR == FNR { p[++n] = $0; next }
       { for (i = 1; i <= n; i++)
           while ((j = index($0, p[i])) > 0)
             $0 = substr($0, 1, j - 1) "<redacted>" substr($0, j + length(p[i]))
         print }' "$WORK/patterns" -
}

# clan, with its output scrubbed. Never pass --debug: it echoes stdin.
clan_q() {
  if ! clan "$@" --flake "$REPO" >"$WORK/clan.log" 2>&1; then
    say "clan $1 $2 $3 failed:"; redact <"$WORK/clan.log" | tail -20
    exit 1
  fi
  grep -i 'warn' "$WORK/clan.log" | redact || true
}

pubkey() { age-keygen -y "$SOPS_AGE_KEY_FILE"; }
src_hash() { git -C "$REPO" show "$1:$SRC" | sha256sum | cut -d' ' -f1; }
sops_meta() { # sops_meta <flakeref> <host>
  nix eval --json "$1#nixosConfigurations.\"$2\".config.sops" --apply "$APPLY" 2>/dev/null
}

cmd_plan() {
  mkdir -p "$STATE/baseline"
  local start pub rcpt
  start=$(git -C "$REPO" rev-parse HEAD)
  pub=$(pubkey)
  rcpt=$(grep -oE 'age1[0-9a-z]{58}' "$REPO/$SRC" | sort -u)
  [ "$rcpt" = "$pub" ] || die "$SRC's recipients are not exactly the local key ($pub)"

  open_src
  local bad
  bad=$(jq -r 'to_entries[] | select((.value|type) != "string" or .value == "") | .key' "$WORK/src.json")
  [ -z "$bad" ] || die "non-string or empty values (clan would skip or open \$EDITOR): $bad"

  printf '%s\n' "$start" >"$STATE/start"
  printf '%s\n' "$pub" >"$STATE/pub"
  src_hash "$start" >"$STATE/srchash"
  jq -r 'keys[]' "$WORK/src.json" >"$STATE/keys"
  : >"$STATE/plan.tsv"

  local h n
  for h in "${HOSTS[@]}"; do
    sops_meta "git+file://$REPO?rev=$start" "$h" >"$STATE/baseline/$h.json" ||
      die "could not evaluate $h"
    jq -r --arg s "$(cat "$STATE/srchash")" '.secrets | to_entries[]
      | select(.value.src == $s) | [.key, .value.key] | @tsv' "$STATE/baseline/$h.json" |
      while IFS=$'\t' read -r name key; do
        if [ "$name" != "$key" ]; then say "SKIP     $h: $name reads key $key (name != key)"; continue; fi
        printf '%s\t%s\n' "$h" "$name" >>"$STATE/plan.tsv"
      done
    n=$(awk -v h="$h" '$1 == h' "$STATE/plan.tsv" | wc -l)
    say "$(printf '%-14s %2d from secret.yaml, %2d from elsewhere (untouched)' "$h" "$n" \
      "$(jq --arg s "$(cat "$STATE/srchash")" '[.secrets[] | select(.src != $s)] | length' "$STATE/baseline/$h.json")")"
  done
  say "secrets in $SRC: $(wc -l <"$STATE/keys"), links planned: $(wc -l <"$STATE/plan.tsv")"
  say "used by no server (imported, linked nowhere): $(cut -f2 "$STATE/plan.tsv" | sort -u | comm -13 - "$STATE/keys" | tr '\n' ' ')"
  say "plan written to $STATE"
}

cmd_migrate() {
  [ -f "$STATE/plan.tsv" ] || die "run plan first"
  local start pub h s
  start=$(cat "$STATE/start"); pub=$(cat "$STATE/pub")
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$start" ] || die "HEAD moved since plan; re-run plan"
  git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet || die "working tree not clean"
  [ ! -e "$REPO/sops" ] || die "$REPO/sops already exists"

  open_src
  cd "$REPO"
  say "registering admin user $ADMIN"
  clan_q secrets users add "$ADMIN" "$pub"
  for h in "${HOSTS[@]}"; do
    say "registering machine $h (shared key, as today)"
    clan_q secrets machines add "$h" "$pub"
  done
  say "importing $(wc -l <"$STATE/keys") secrets"
  clan_q secrets import-sops "$SRC"
  while IFS=$'\t' read -r h s; do
    clan_q secrets machines add-secret "$h" "$s"
  done <"$STATE/plan.tsv"
  say "linked $(wc -l <"$STATE/plan.tsv") secret/host pairs"

  # clan commits every step; fold those into one staged change.
  git -C "$REPO" reset -q --soft "$start"
  git -C "$REPO" add -A sops
  local other
  other=$(git -C "$REPO" diff --cached --name-only | grep -v '^sops/' || true)
  [ -z "$other" ] || die "unexpected staged changes outside sops/: $other"
  say "staged $(git -C "$REPO" diff --cached --name-only | wc -l) files under sops/ -- not committed. Next: validate"
}

cmd_validate() {
  [ -f "$STATE/plan.tsv" ] || die "run plan first"
  [ -d "$REPO/sops/secrets" ] || die "no sops/secrets -- run migrate first"
  local pub fail=0 ok=0 k f want have
  pub=$(cat "$STATE/pub")
  open_src

  say "== store: every value round-trips byte for byte"
  while read -r k; do
    f="$REPO/sops/secrets/$k/secret"
    if [ ! -f "$f" ]; then say "MISSING   $k"; fail=1; continue; fi
    jq -j --arg k "$k" '.[$k]' "$WORK/src.json" >"$WORK/a"
    if ! sops -d --input-type binary --output-type binary "$f" >"$WORK/b" 2>/dev/null; then
      say "UNREADABLE $k"; fail=1; continue
    fi
    if ! cmp -s "$WORK/a" "$WORK/b"; then say "MISMATCH  $k"; fail=1; continue; fi
    have=$(jq -r '.sops.age[]?.recipient' "$f" | sort -u)
    if [ "$have" != "$pub" ]; then say "RECIPIENTS $k: not exactly the shared key"; fail=1; continue; fi
    want=$(awk -F'\t' -v k="$k" '$2 == k { print $1 }' "$STATE/plan.tsv" | sort)
    have=$(ls "$REPO/sops/secrets/$k/machines" 2>/dev/null | sort || true)
    if [ "$want" != "$have" ]; then say "LINKS     $k: linked to [$(echo $have)], planned [$(echo $want)]"; fail=1; continue; fi
    ok=$((ok + 1))
  done <"$STATE/keys"
  extra=$(ls "$REPO/sops/secrets" | comm -23 - "$STATE/keys" | tr '\n' ' ')
  [ -z "$extra" ] || { say "EXTRA     secrets not in $SRC: $extra"; fail=1; }
  say "$ok/$(wc -l <"$STATE/keys") secrets identical, correctly encrypted and linked"

  say "== config: each server's sops wiring vs the pre-migration baseline"
  local labels h migrated planned
  labels=$( { printf '{"%s":"src"' "$(cat "$STATE/srchash")"
              while read -r k; do printf ',"%s":"clan:%s"' "$(sha256sum <"$REPO/sops/secrets/$k/secret" | cut -d' ' -f1)" "$k"; done <"$STATE/keys"
              printf '}'; } )
  for h in "${HOSTS[@]}"; do
    if ! sops_meta "$REPO" "$h" >"$WORK/after.json" || ! jq -e '.secrets | type == "object"' "$WORK/after.json" >/dev/null 2>&1; then
      say "FAIL      $h: does not evaluate"; fail=1; continue
    fi
    jq -r -n --slurpfile b "$STATE/baseline/$h.json" --slurpfile a "$WORK/after.json" --argjson L "$labels" '
      $b[0] as $B | $a[0] as $A | def lab(x): ($L[x] // "other");
      ( $B.secrets | keys[] as $n | select($A.secrets | has($n) | not) | "FAIL missing " + $n ),
      ( $A.secrets | keys[] as $n | select($B.secrets | has($n) | not) | "FAIL new " + $n ),
      ( $B.secrets | keys[] as $n | select($A.secrets | has($n)) | $B.secrets[$n] as $x | $A.secrets[$n] as $y |
        ( ("key","owner","group","mode","path","neededForUsers","restartUnits","reloadUnits")
          | select($x[.] != $y[.]) | "FAIL " + $n + ": " + . + " changed" ),
        ( if $x.format == $y.format and $x.src == $y.src then "UNCHANGED " + $n
          elif lab($x.src) == "src" and $x.format == "yaml" and $y.format == "binary" and lab($y.src) == "clan:" + $n
          then "MIGRATED " + $n
          else "FAIL " + $n + ": " + lab($x.src) + "/" + $x.format + " -> " + lab($y.src) + "/" + $y.format end ) ),
      ( if $B.templates == $A.templates then "TEMPLATES ok" else "FAIL templates changed" end )' >"$WORK/v2"
    migrated=$(sed -n 's/^MIGRATED //p' "$WORK/v2" | sort)
    planned=$(awk -F'\t' -v h="$h" '$1 == h { print $2 }' "$STATE/plan.tsv" | sort)
    grep '^FAIL' "$WORK/v2" | sed "s/^/  $h: /" || true
    comm -13 <(printf '%s\n' "$migrated") <(printf '%s\n' "$planned") | sed '/^$/d' |
      sed "s/^/  $h: planned but not migrated: /"
    if grep -q '^FAIL' "$WORK/v2" || [ "$migrated" != "$planned" ]; then
      fail=1; say "FAIL      $h"
    else
      say "$(printf 'ok        %-14s %2d migrated, %2d unchanged, templates identical' "$h" \
        "$(grep -c '^MIGRATED' "$WORK/v2")" "$(grep -c '^UNCHANGED' "$WORK/v2")")"
    fi
  done
  [ "$fail" = 0 ] && say "VALIDATION PASSED" || { say "VALIDATION FAILED"; exit 1; }
}

ssh_args() {
  local k=$HOME/.ssh/id_ed25519_priv
  case "$1" in
    201-mono) echo phonkd@192.168.3.201 ;;
    203-media) echo phonkd@192.168.3.203 ;;
    204-agent) echo phonkd@192.168.3.204 ;;
    205-builder) echo phonkd@100.64.0.2 ;;
    observability) echo "-p 5432 -i $k -o IdentitiesOnly=yes phonkd@89.167.83.90" ;;
    ext-mail) echo "-p 5432 -i $k -o IdentitiesOnly=yes phonkd@157.180.27.152" ;;
    *) die "unknown host $1" ;;
  esac
}

# Runs as root on the host. Hashes go to a root-only file there and are never
# printed; only paths and statuses come back.
REMOTE_COMMON='
set -eu; umask 077
SNAP=/root/clan-secrets-migrate.snapshot
listing() {
  for d in /run/secrets /run/secrets-for-users; do
    [ -e "$d" ] || continue
    find -L "$d" -type f -print0 | sort -z | while IFS= read -r -d "" p; do
      printf "%s\t%s\t%s\n" "$p" "$(stat -L -c %U:%G:%a "$p")" "$(sha256sum <"$p" | cut -d" " -f1)"
    done
  done
}'
REMOTE_SNAPSHOT="$REMOTE_COMMON"'
listing >"$SNAP.tmp"; mv "$SNAP.tmp" "$SNAP"
echo "snapshot: $(wc -l <"$SNAP") files"'
REMOTE_VERIFY="$REMOTE_COMMON"'
[ -f "$SNAP" ] || { echo "no snapshot on this host"; exit 2; }
NOW=$(mktemp); listing >"$NOW"
if awk -F "\t" "NR == FNR { o[\$1] = \$2 \"\t\" \$3; next }
  { seen[\$1] = 1
    if (!(\$1 in o)) { print \"NEW      \" \$1; bad = 1; next }
    split(o[\$1], a, \"\t\"); s = \"\"
    if (a[1] != \$2) s = s \" perms \" a[1] \" -> \" \$2
    if (a[2] != \$3) s = s \" content\"
    if (s != \"\") { print \"CHANGED  \" \$1 s; bad = 1 } else ok++ }
  END { for (p in o) if (!(p in seen)) { print \"MISSING  \" p; bad = 1 }
        print ok + 0 \" unchanged\"; exit bad }" "$SNAP" "$NOW"; then
  rm -f "$SNAP" "$NOW"; echo "verified; snapshot removed"
else rm -f "$NOW"; exit 1; fi'

remote() { # remote <script> <host>...
  local script=$1 h rc=0; shift
  [ $# -gt 0 ] || die "name at least one host"
  for h in "$@"; do
    read -r -a a <<<"$(ssh_args "$h")"
    say "== $h"
    ssh -o ConnectTimeout=10 -o BatchMode=yes "${a[@]}" sudo bash -s <<<"$script" || rc=1
  done
  return $rc
}

case "${1:-}" in
  plan) cmd_plan ;;
  migrate) cmd_migrate ;;
  validate) cmd_validate ;;
  snapshot) shift; remote "$REMOTE_SNAPSHOT" "$@" ;;
  verify) shift; remote "$REMOTE_VERIFY" "$@" ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
