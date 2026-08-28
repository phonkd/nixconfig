# Mint an Authelia OIDC client for one app: generate the client secret, store
# both halves encrypted, and print the two nix snippets to paste.
#
#   sso-secret grafana --redirect https://grafana.phonkd.net/login/generic_oauth
#   sso-secret immich  --redirect https://immich.w.phonkd.net/auth/login \
#                      --redirect app.immich:///oauth-callback
#
# Two halves land in modules/homelab/secrets/<app>.yaml:
#   <app>_oidc_client_secret          the raw secret, for the APP to send
#   <app>_oidc_client_secret_digest   what AUTHELIA stores for comparison
#
# The digest is '$plaintext$<secret>' by default. Authelia supports PBKDF2
# instead, but the authelia CLI that generates those hashes cannot be installed
# on this Mac (nixpkgs#authelia is marked broken on aarch64-darwin -- its
# authelia-web frontend derivation is broken, on both 26.05 and unstable), and
# the file is age-encrypted in git and 0400 root on the host either way. Pass
# --hash to generate a real PBKDF2 digest over ssh on 201-mono, where authelia
# actually is installed.

set -euo pipefail

issuer="https://auth.w.phonkd.net"
policy="one_factor"
scopes="openid, profile, groups, email"
hash_host="201-mono"

usage() {
  cat >&2 <<'EOF'
usage: sso-secret <app> --redirect <uri> [--redirect <uri>...] [options]

  --redirect <uri>   OIDC redirect URI (repeatable, at least one required)
  --policy <p>       authorization_policy (default: one_factor)
  --scopes <list>    comma-separated scopes (default: openid,profile,groups,email)
  --hash             PBKDF2-hash the secret via ssh 201-mono, instead of $plaintext$

Generates the client secret, stores it encrypted in
modules/homelab/secrets/<app>.yaml, and prints the Authelia client entry and
the app-side sops wiring.
EOF
  exit "${1:-2}"
}

[ $# -ge 1 ] || usage
case "$1" in
-h | --help) usage 0 ;;
esac

app="$(printf '%s' "$1" | tr '[:upper:].-' '[:lower:]__')"
shift

redirects=()
do_hash=0
while [ $# -gt 0 ]; do
  case "$1" in
  --redirect | -r)
    redirects+=("$2")
    shift 2
    ;;
  --policy)
    policy="$2"
    shift 2
    ;;
  --scopes)
    scopes="$(printf '%s' "$2" | sed 's/,/, /g; s/  */ /g')"
    shift 2
    ;;
  --hash)
    do_hash=1
    shift
    ;;
  *)
    echo "sso-secret: unknown argument '$1'" >&2
    usage
    ;;
  esac
done

if [ "${#redirects[@]}" -eq 0 ]; then
  echo "sso-secret: at least one --redirect is required" >&2
  usage
fi

# Authelia's own guidance is >=72 chars of entropy for a confidential client.
secret="$(openssl rand -base64 72 | tr -d '\n=' | tr '+/' '-_')"

if [ "$do_hash" = 1 ]; then
  echo "sso-secret: hashing on $hash_host (authelia is not installable on darwin)..." >&2
  digest="$(ssh "$hash_host" authelia crypto hash generate pbkdf2 \
    --variant sha512 --password "$secret" |
    sed -n 's/^Digest: *//p')"
  if [ -z "$digest" ]; then
    echo "sso-secret: could not parse a digest out of authelia's output" >&2
    exit 1
  fi
else
  digest="\$plaintext\$$secret"
fi

sops-secret "$app.oidc_client_secret" "$secret"
sops-secret "$app.oidc_client_secret_digest" "$digest"

# --- the paste-ready snippets ------------------------------------------------
redirect_yaml=""
for uri in "${redirects[@]}"; do
  redirect_yaml="$redirect_yaml
              - $uri"
done

cat <<EOF

────────────────────────────────────────────────────────────────────────────
1. Authelia side -- add to the sops.templates."authelia-oidc-clients.yaml"
   content in modules/homelab/apps/authelia/authelia.nix, and add
   sops.secrets.${app}_oidc_client_secret_digest (sopsFile = ../../secrets/$app.yaml)
   so the placeholder below resolves:

          - client_id: $app
            client_name: $app
            client_secret: \${config.sops.placeholder."${app}_oidc_client_secret_digest"}
            public: false
            authorization_policy: $policy
            require_pkce: true
            pkce_challenge_method: S256
            redirect_uris:$redirect_yaml
            scopes: [ $scopes ]

2. App side -- in the module that runs $app:

     sops.secrets.${app}_oidc_client_secret = {
       sopsFile = ../secrets/$app.yaml;
       owner = "$app";
     };

   client_id      = "$app"
   issuer         = "$issuer"
   discovery      = "$issuer/.well-known/openid-configuration"
   client secret  = config.sops.secrets.${app}_oidc_client_secret.path
────────────────────────────────────────────────────────────────────────────
EOF
