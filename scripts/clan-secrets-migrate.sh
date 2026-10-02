#!/usr/bin/env bash
# Move sops files into clan's sops store (plans/clan-lol-migration.md,
# Phase 2), and prove nothing changed. Incremental: secrets and links already
# in the store are recognised and left alone, so it can be re-run as more
# sources and hosts are added.
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
# Order: plan, migrate, drop the consumers' explicit `sopsFile` lines (yaml
# sources other than defaultSopsFile, and binary ones), validate, commit, then
# per host: snapshot, deploy, verify.
#
# A secret is moved only where a host already reads it from one of SOURCES, and
# clan declares a secret on a host only if it is linked there
# (nixosModules/clanCore/sops.nix) -- so no host gains a secret it didn't have.
# Every source must be encrypted to exactly the shared key; that rules out the
# mail secret, which is encrypted to ext-mail's own key on purpose.
set -euo pipefail
umask 077
# One collation for sort, comm, uniq and ls -- the name-set checks depend on it.
export LC_ALL=C

REPO=$(git rev-parse --show-toplevel)
ADMIN=phonkd
# kind path. yaml: one clan secret per key, same name. binary: one clan secret
# per sops.secrets name that reads the file, same bytes.
SOURCES=(
  "yaml modules/homelab/global-secrets/secret.yaml"
  "yaml modules/homelab/apps/authelia/authelia-secret.yaml"
  "yaml modules/homelab/secrets/chat.yaml"
  "binary modules/homelab/apps/traefik/traefik-secret.txt"
)
# Not blac or the Mac: parked. The Mac's secrets are home-manager-level anyway,
# which clan's auto-declaration doesn't reach.
HOSTS=(201-mono 203-media 204-agent 205-builder ext-mail observability z14)
export SOPS_AGE_KEY_FILE=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/clan-secrets-migrate/$(printf %s "$REPO" | sha256sum | cut -c1-12)

# config.sops reduced to metadata. sopsFile becomes the sha256 of the
# encrypted file, which labels() maps back to "src:<path>" or "clan:<name>".
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

# Decrypt every source into the private work dir (s<i>.json or s<i>.bin), and
# derive the redaction patterns from all of them.
open_sources() {
  [ -n "$WORK" ] && return
  WORK=$(mktemp -d /dev/shm/clan-secrets-migrate.XXXXXX)
  local i kind path
  for i in "${!SOURCES[@]}"; do
    read -r kind path <<<"${SOURCES[$i]}"
    case $kind in
      yaml) sops -d --output-type json "$REPO/$path" >"$WORK/s$i.json" 2>/dev/null ||
              die "could not decrypt $path with $SOPS_AGE_KEY_FILE"
            jq -r '.[]' "$WORK/s$i.json" >>"$WORK/raw" ;;
      binary) sops -d --input-type binary --output-type binary "$REPO/$path" >"$WORK/s$i.bin" 2>/dev/null ||
              die "could not decrypt $path with $SOPS_AGE_KEY_FILE"
            cat "$WORK/s$i.bin" >>"$WORK/raw"; printf '\n' >>"$WORK/raw" ;;
      *) die "unknown source kind $kind" ;;
    esac
  done
  awk 'length($0) >= 4' "$WORK/raw" >"$WORK/patterns"; rm -f "$WORK/raw"
}

src_index() { local i kind path; for i in "${!SOURCES[@]}"; do
  read -r kind path <<<"${SOURCES[$i]}"; [ "$path" = "$1" ] && { echo "$i"; return; }; done; die "no source $1"; }
src_kind() { local kind path; read -r kind path <<<"${SOURCES[$(src_index "$1")]}"; echo "$kind"; }

# value_of <name> <path> <key>: the plaintext clan should hold, into $WORK/a.
value_of() {
  local i; i=$(src_index "$2")
  case $(src_kind "$2") in
    yaml) jq -j --arg k "$3" '.[$k]' "$WORK/s$i.json" >"$WORK/a" ;;
    binary) cp "$WORK/s$i.bin" "$WORK/a" ;;
  esac
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
    say "clan $* failed:" | redact; redact <"$WORK/clan.log" | tail -20
    exit 1
  fi
  grep -i 'warn' "$WORK/clan.log" | redact || true
}

pubkey() { age-keygen -y "$SOPS_AGE_KEY_FILE"; }
# --impure: z14 imports /etc/nixos/hardware-configuration.nix.
sops_meta() { # sops_meta <flakeref> <host>
  nix eval --impure --json "$1#nixosConfigurations.\"$2\".config.sops" --apply "$APPLY" 2>/dev/null
}
# hash -> label, for every source and every secret in the store.
labels() {
  local kind path d
  { printf '{"-":"-"'
    for s in "${SOURCES[@]}"; do read -r kind path <<<"$s"
      printf ',"%s":"src:%s"' "$(sha256sum <"$REPO/$path" | cut -d' ' -f1)" "$path"; done
    if [ -d "$REPO/sops/secrets" ]; then for d in "$REPO"/sops/secrets/*/; do
      printf ',"%s":"clan:%s"' "$(sha256sum <"$d/secret" | cut -d' ' -f1)" "$(basename "$d")"; done; fi
    printf '}'; }
}

cmd_plan() {
  rm -rf "$STATE"; mkdir -p "$STATE/baseline"
  local start pub kind path i bad L h
  start=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet || die "working tree not clean"
  pub=$(pubkey)
  for s in "${SOURCES[@]}"; do read -r kind path <<<"$s"
    [ "$(grep -oE 'age1[0-9a-z]{58}' "$REPO/$path" | sort -u)" = "$pub" ] ||
      die "$path is not encrypted to exactly the shared key ($pub)"
  done
  open_sources
  for i in "${!SOURCES[@]}"; do read -r kind path <<<"${SOURCES[$i]}"
    case $kind in
      yaml) bad=$(jq -r 'to_entries[] | select((.value|type) != "string" or .value == "") | .key' "$WORK/s$i.json")
            [ -z "$bad" ] || die "$path: non-string or empty values (clan would skip or open \$EDITOR): $bad"
            jq -r 'keys[]' "$WORK/s$i.json" | awk -v p="$path" '{ print $0 "\t" p "\t" $0 }' >>"$STATE/expected.tsv" ;;
      binary) [ -s "$WORK/s$i.bin" ] || die "$path is empty" ;;
    esac
  done
  printf '%s\n' "$start" >"$STATE/start"; printf '%s\n' "$pub" >"$STATE/pub"
  : >"$STATE/plan.tsv"
  L=$(labels)

  for h in "${HOSTS[@]}"; do
    sops_meta "git+file://$REPO?rev=$start" "$h" >"$STATE/baseline/$h.json" || die "could not evaluate $h"
    jq -r --argjson L "$L" '.secrets | to_entries[] | [.key, .value.key, ($L[.value.src] // "other")] | @tsv' \
      "$STATE/baseline/$h.json" >"$WORK/rows"
    while IFS=$'\t' read -r name key label; do
      case $label in
        clan:*) [ "${label#clan:}" = "$name" ] || die "$h: $name reads clan's ${label#clan:}"
                printf '%s\t%s\texisting\n' "$h" "$name" >>"$STATE/plan.tsv" ;;
        src:*) path=${label#src:}
               if [ "$(src_kind "$path")" = yaml ]; then
                 [ "$key" = "$name" ] || { say "SKIP     $h: $name reads key $key (name != key)"; continue; }
               else
                 printf '%s\t%s\t-\n' "$name" "$path" >>"$STATE/expected.tsv"
               fi
               printf '%s\t%s\tnew\n' "$h" "$name" >>"$STATE/plan.tsv" ;;
      esac
    done <"$WORK/rows"
    say "$(printf '%-14s %2d in clan already, %2d to move, %2d left alone' "$h" \
      "$(awk -F'\t' -v h="$h" '$1 == h && $3 == "existing"' "$STATE/plan.tsv" | wc -l)" \
      "$(awk -F'\t' -v h="$h" '$1 == h && $3 == "new"' "$STATE/plan.tsv" | wc -l)" \
      "$(awk -F'\t' '$3 == "other"' "$WORK/rows" | wc -l)")"
  done
  sort -u -o "$STATE/expected.tsv" "$STATE/expected.tsv"
  dup=$(cut -f1 "$STATE/expected.tsv" | uniq -d)
  [ -z "$dup" ] || die "secret names coming from two sources: $dup"
  say "store will hold $(wc -l <"$STATE/expected.tsv") secrets ($(cut -f1 "$STATE/expected.tsv" |
    while read -r n; do [ -e "$REPO/sops/secrets/$n/secret" ] || echo "$n"; done | wc -l) to import);" \
    "$(awk -F'\t' '$3 == "new"' "$STATE/plan.tsv" | wc -l) new links"
  say "linked nowhere: $(cut -f2 "$STATE/plan.tsv" | sort -u | comm -13 - <(cut -f1 "$STATE/expected.tsv") | tr '\n' ' ')"
  say "plan written to $STATE"
}

cmd_migrate() {
  [ -f "$STATE/plan.tsv" ] || die "run plan first"
  local start pub h s name path key kind
  start=$(cat "$STATE/start"); pub=$(cat "$STATE/pub")
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$start" ] || die "HEAD moved since plan; re-run plan"
  git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet || die "working tree not clean"

  open_sources
  cd "$REPO"
  [ -e "sops/users/$ADMIN" ] || { say "registering admin user $ADMIN"; clan_q secrets users add "$ADMIN" "$pub"; }
  for h in "${HOSTS[@]}"; do
    [ -e "sops/machines/$h" ] || { say "registering machine $h (shared key, as today)"; clan_q secrets machines add "$h" "$pub"; }
  done
  local missing
  for s in "${SOURCES[@]}"; do read -r kind path <<<"$s"
    [ "$kind" = yaml ] || continue
    missing=$(awk -F'\t' -v p="$path" '$2 == p { print $1 }' "$STATE/expected.tsv" |
      while read -r name; do [ -e "sops/secrets/$name/secret" ] || echo "$name"; done | wc -l)
    if [ "$missing" -gt 0 ]; then say "importing $path ($missing new)"; clan_q secrets import-sops "$path"; fi
  done
  while IFS=$'\t' read -r name path key; do
    if [ "$key" != - ] || [ -e "sops/secrets/$name/secret" ]; then continue; fi
    say "importing $path as $name"
    # From the copy open_sources already decrypted and checked non-empty: a
    # failed decrypt piped straight in would be stored as an empty value.
    clan_q secrets set "$name" <"$WORK/s$(src_index "$path").bin"
  done <"$STATE/expected.tsv"
  while IFS=$'\t' read -r h s status; do
    if [ "$status" = new ]; then clan_q secrets machines add-secret "$h" "$s"; fi
  done <"$STATE/plan.tsv"
  say "linked $(awk -F'\t' '$3 == "new"' "$STATE/plan.tsv" | wc -l) new secret/host pairs"

  # clan commits every step; fold those into one staged change.
  git -C "$REPO" reset -q --soft "$start"
  git -C "$REPO" add -A sops
  local other
  other=$(git -C "$REPO" diff --cached --name-only | grep -v '^sops/' || true)
  [ -z "$other" ] || die "unexpected staged changes outside sops/: $other"
  say "staged $(git -C "$REPO" diff --cached --name-only | wc -l) files under sops/ -- not committed."
  say "Next: drop the moved secrets' explicit sopsFile lines, then validate"
}

cmd_validate() {
  [ -f "$STATE/plan.tsv" ] || die "run plan first"
  [ -d "$REPO/sops/secrets" ] || die "no sops/secrets -- run migrate first"
  local pub fail=0 ok=0 f want have name path key extra
  pub=$(cat "$STATE/pub")
  open_sources

  say "== store: every value round-trips byte for byte"
  while IFS=$'\t' read -r name path key; do
    f="$REPO/sops/secrets/$name/secret"
    if [ ! -f "$f" ]; then say "MISSING   $name"; fail=1; continue; fi
    value_of "$name" "$path" "$key"
    if ! sops -d --input-type binary --output-type binary "$f" >"$WORK/b" 2>/dev/null; then
      say "UNREADABLE $name"; fail=1; continue
    fi
    if ! cmp -s "$WORK/a" "$WORK/b"; then say "MISMATCH  $name (vs $path)"; fail=1; continue; fi
    have=$(jq -r '.sops.age[]?.recipient' "$f" | sort -u)
    if [ "$have" != "$pub" ]; then say "RECIPIENTS $name: not exactly the shared key"; fail=1; continue; fi
    want=$(awk -F'\t' -v k="$name" '$2 == k { print $1 }' "$STATE/plan.tsv" | sort)
    have=$(ls "$REPO/sops/secrets/$name/machines" 2>/dev/null | sort || true)
    if [ "$want" != "$have" ]; then say "LINKS     $name: linked to [$(echo $have)], planned [$(echo $want)]"; fail=1; continue; fi
    ok=$((ok + 1))
  done <"$STATE/expected.tsv"
  extra=$(ls "$REPO/sops/secrets" | comm -23 - <(cut -f1 "$STATE/expected.tsv") | tr '\n' ' ')
  [ -z "$extra" ] || { say "EXTRA     secrets in the store but in no source: $extra"; fail=1; }
  say "$ok/$(wc -l <"$STATE/expected.tsv") secrets identical, correctly encrypted and linked"

  say "== config: each host's sops wiring vs the pre-migration baseline"
  local L h moved planned
  L=$(labels)
  for h in "${HOSTS[@]}"; do
    if ! sops_meta "$REPO" "$h" >"$WORK/after.json" || ! jq -e '.secrets | type == "object"' "$WORK/after.json" >/dev/null 2>&1; then
      say "FAIL      $h: does not evaluate"; fail=1; continue
    fi
    jq -r -n --slurpfile b "$STATE/baseline/$h.json" --slurpfile a "$WORK/after.json" --argjson L "$L" '
      $b[0] as $B | $a[0] as $A | def lab(x): ($L[x] // "other");
      ( $B.secrets | keys[] as $n | select($A.secrets | has($n) | not) | "FAIL missing " + $n ),
      ( $A.secrets | keys[] as $n | select($B.secrets | has($n) | not) | "FAIL new " + $n ),
      ( $B.secrets | keys[] as $n | select($A.secrets | has($n)) | $B.secrets[$n] as $x | $A.secrets[$n] as $y |
        ( ("key","owner","group","mode","path","neededForUsers","restartUnits","reloadUnits")
          | select($x[.] != $y[.]) | "FAIL " + $n + ": " + . + " changed" ),
        ( if $x.format == $y.format and $x.src == $y.src then "UNCHANGED " + $n
          elif (lab($x.src) | startswith("src:")) and $y.format == "binary" and lab($y.src) == "clan:" + $n
          then "MIGRATED " + $n
          else "FAIL " + $n + ": " + lab($x.src) + "/" + $x.format + " -> " + lab($y.src) + "/" + $y.format end ) ),
      ( if $B.templates == $A.templates then "TEMPLATES ok" else "FAIL templates changed" end )' >"$WORK/v2"
    moved=$(sed -n 's/^MIGRATED //p' "$WORK/v2" | sort)
    planned=$(awk -F'\t' -v h="$h" '$1 == h && $3 == "new" { print $2 }' "$STATE/plan.tsv" | sort)
    grep '^FAIL' "$WORK/v2" | sed "s/^/  $h: /" || true
    comm -13 <(printf '%s\n' "$moved") <(printf '%s\n' "$planned") | sed '/^$/d' |
      sed "s/^/  $h: planned but not migrated: /"
    comm -23 <(printf '%s\n' "$moved") <(printf '%s\n' "$planned") | sed '/^$/d' |
      sed "s/^/  $h: migrated but not planned: /"
    if grep -q '^FAIL' "$WORK/v2" || [ "$moved" != "$planned" ]; then
      fail=1; say "FAIL      $h"
    else
      say "$(printf 'ok        %-14s %2d moved now, %2d unchanged, templates identical' "$h" \
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
    205-builder) echo phonkd@192.168.3.205 ;;
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

remote() { # remote <script> <host>...; the local host runs it via sudo directly
  local script=$1 h rc=0; shift
  [ $# -gt 0 ] || die "name at least one host"
  for h in "$@"; do
    say "== $h"
    if [ "$h" = "$(hostname)" ]; then
      sudo bash -s <<<"$script" || rc=1
    else
      read -r -a a <<<"$(ssh_args "$h")"
      ssh -o ConnectTimeout=10 -o BatchMode=yes "${a[@]}" sudo bash -s <<<"$script" || rc=1
    fi
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
