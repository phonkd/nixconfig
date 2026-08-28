# Add or update one sops secret, in a per-app encrypted file.
#
#   sops-secret hermes.openrouterkey            # prompt for the value (hidden)
#   sops-secret hermes.openrouterkey sk-or-...  # value on the command line
#   sops-secret hermes.openrouterkey --generate # generate 48 random bytes
#   sops-secret hermes.openrouterkey --generate 24
#
# The file is modules/homelab/secrets/<app>.yaml, created and encrypted on
# first use (the .sops.yaml creation rule for that directory decides the age
# recipients). The key inside it is <app>_<key>, matching the existing
# authelia_* convention -- sops-nix names are flat per host, so the app prefix
# is what keeps two apps' "apikey" apart.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: sops-secret <app>.<key> [value | --generate [bytes]]

  sops-secret hermes.openrouterkey             prompt for the value (hidden)
  sops-secret hermes.openrouterkey sk-or-...   value on the command line
  sops-secret hermes.openrouterkey --generate  generate 48 random bytes

Stores it as <app>_<key> in modules/homelab/secrets/<app>.yaml, creating and
encrypting that file on first use.
EOF
  exit "${1:-2}"
}

[ $# -ge 1 ] || usage
case "$1" in
-h | --help) usage 0 ;;
esac

spec="$1"
shift

case "$spec" in
*.*) ;;
*)
  echo "sops-secret: expected <app>.<key>, got '$spec'" >&2
  exit 2
  ;;
esac

app="${spec%%.*}"
keypart="${spec#*.}"

# Normalise both halves the way the rest of the repo names things.
sanitise() { printf '%s' "$1" | tr '[:upper:].-' '[:lower:]__'; }
app="$(sanitise "$app")"
key="$(sanitise "$app")_$(sanitise "$keypart")"

repo="$(git rev-parse --show-toplevel)"
file="$repo/modules/homelab/secrets/$app.yaml"

# --- work out the value ------------------------------------------------------
value=""
case "${1:-}" in
--generate | -g)
  bytes="${2:-48}"
  value="$(openssl rand -base64 "$bytes" | tr -d '\n=' | tr '+/' '-_')"
  generated=1
  ;;
"")
  printf 'value for %s (input hidden): ' "$key" >&2
  read -rs value
  printf '\n' >&2
  ;;
*)
  value="$1"
  ;;
esac

if [ -z "$value" ]; then
  echo "sops-secret: refusing to store an empty value" >&2
  exit 1
fi

# --- write it ----------------------------------------------------------------
mkdir -p "$(dirname "$file")"

json="$(jq -n --arg v "$value" '$v')"

if [ -f "$file" ]; then
  sops set "$file" "[\"$key\"]" "$json"
  action="updated"
else
  # A brand-new file has nothing for `sops set` to edit, so build the first
  # version in the clear and encrypt it in one shot. --filename-override makes
  # sops pick the creation rule for the *destination* path, not the tempfile's.
  tmp="$(mktemp -t sops-secret.XXXXXX)"
  trap 'rm -f "$tmp"' EXIT
  jq -n --arg k "$key" --arg v "$value" '{($k): $v}' >"$tmp"
  sops encrypt --filename-override "$file" --output "$file" "$tmp"
  action="created"
fi

echo "sops-secret: $action $key in ${file#"$repo"/}" >&2
if [ "${generated:-0}" = 1 ]; then
  echo "sops-secret: generated value: $value" >&2
fi

cat >&2 <<EOF

Wire it up (in the module that needs it):

  sops.secrets.$key = {
    sopsFile = ../secrets/$app.yaml;
    # owner = "$app";   # if a service user has to read the file directly
  };

then reference it as config.sops.secrets.$key.path, or interpolate it into an
env file with \${config.sops.placeholder."$key"} inside a sops.templates entry.
EOF
