# Authelia SSO: feasibility + a secret-generation workflow

**Repo(s):** nixconfig   **Status:** in-progress

_Decisions locked (2026-08-28):_ **forward-auth is rejected as an SSO
mechanism** — see "Why not forward-auth" below. Real OIDC is worth it for
**Grafana and Immich only**; phonkd is configuring those two directly. Everything
else either keeps its own login untouched, or gets `auth = true` purely as an
outer lock with a `bypass` policy on the home net (paperless, seerr, affine —
**done**, see "Lockdown" below).

## TL;DR

SSO is feasible and the groundwork is better than expected:

- Authelia is **4.39.20** — well past 4.38, where the OIDC provider config was
  reworked. The schema in the docs today is the schema we'd write.
- The nixpkgs authelia module has **first-class OIDC support**:
  `secrets.oidcHmacSecretFile`, `secrets.oidcIssuerPrivateKeyFile` (it
  auto-generates the `jwks:` fragment from the key file via Authelia's own
  config templating) and `settingsFiles` for a sops-templated client list.
  Nothing has to be hand-rolled.
- Today Authelia is used **only** as a forward-auth gate, and only on 3 of ~20
  routes. Turning on the OIDC provider is additive: forward-auth keeps working
  unchanged for everything that can't speak OIDC.

But the useful scope is much narrower than "which apps support it". The
question that decides each app is not *can it do SSO* — it's **does it have a
login of its own already**. If it does, putting Authelia in front adds a
login rather than removing one, and OIDC is only worth wiring if the app will
treat the OIDC identity as its own account.

That leaves **Grafana and Immich** as the entire SSO shortlist. Everything else
either keeps its own login untouched, or gets Authelia attached purely as an
outer deny layer that is bypassed at home.

## Where auth stands right now

Extracted from every `phonkds.modules.*` entry in the repo — 19 routed apps.
Only two have `traefik.auth = true`:

| route | auth today |
|---|---|
| `dashboard.w.phonkd.net` (homepage) | forward-auth |
| `priv.s3.w.phonkd.net` | forward-auth |

Everything else is `auth = false`. The internal ones lean on `ipfilter = true`
plus the `100.64.0.0/10` tailnet allow-list; the public ones (`jellyfin.w`,
`immich.w`, `ocis.w`, `vw.w`) lean on their own login page.

So the practical reading: **there is no SSO today, there is a firewall and a
pile of separate passwords.** Authelia's `access_control` already has the right
shape for it (the `internal` network definition already includes the tailnet),
it's just that almost no router is wired to the middleware.

## Tier 1 — real OIDC

These speak OIDC natively and can be configured declaratively from this repo.
Ordered by effort/reward.

**Only the first two are being done** (and phonkd is configuring them directly
— see the decision note at the top). The rest are recorded because "does this
app support OIDC?" is the question that keeps getting re-asked, not because
they are queued. See "Why not forward-auth" for why the list narrows to two.

| app | how | notes |
|---|---|---|
| **Grafana** | `services.grafana.settings."auth.generic_oauth"` — `settings` is a freeform INI type | Easiest win. Client secret via Grafana's `$__file{/run/secrets/...}` syntax, so no plaintext in the store. Lives on the Hetzner obs host, so the issuer must be the **public** `auth.w.phonkd.net`. |
| **Immich** | `services.immich.settings.oauth.*`, and the module explicitly supports `clientSecret._secret = "/path/to/file"` | Genuinely first-class — nixpkgs documents this exact pattern in the module. Mobile app handles OIDC fine. |
| **Paperless-ngx** | `PAPERLESS_APPS` + `PAPERLESS_SOCIALACCOUNT_PROVIDERS` (django-allauth) via `services.paperless.environmentFile` | The provider config is one JSON blob containing the secret → must go through `environmentFile`, not `settings` (which lands in the store). |
| **Headscale** | `services.headscale.settings.oidc.{issuer,client_id,client_secret_path}` — dedicated options, `client_secret_path` is sops-ready | Replaces the pre-auth-key dance for enrolling new nodes. Also the one place where "who are you" is currently a shared static key (`headscale_authkey`). |
| **Proxmox (`oldblac`)** | PVE realm of type OpenID Connect, configured in the PVE UI | Not nix-managed (it's an orphan route), so it's a one-time click-through. Still worth it — PVE is the highest-value login here. |
| **Jellyseerr (`seerr`)** | OIDC support in 2.x, configured in-app | In-app config, not nix. |
| **oCIS** | `OCIS_OIDC_ISSUER` + `PROXY_OIDC_*` + `WEB_OIDC_CLIENT_ID`, disable the bundled IDP via `OCIS_EXCLUDE_RUN_SERVICES=idp` | **The hard one.** oCIS ships its own IDP and swapping it out touches autoprovisioning, role assignment, and the desktop/mobile clients (which need a public client with the right redirect URIs). Do this last, or not at all. |
| **AFFiNE** | OAuth provider config in `AFFINE_*` env | Support exists but has moved between releases; verify against the pinned version before committing to it. |
| **Jellyfin** | `9p4/jellyfin-plugin-sso` | Plugin is not in nixpkgs — installed through Jellyfin's own catalogue, so it lives outside the config and survives rebuilds only because plugin state is in `/var/lib`. Works, but it's the one Tier-1 entry that makes the config less reproducible. |

## Why not forward-auth — the decision

An earlier draft of this plan called forward-auth "the cheapest real
improvement in the document" and proposed flipping `traefik.auth = true` across
`sonarr`, `radarr`, `lidarr`, `prowlarr`, `sabnzbd`, `slskd`, `syncthing`,
`snapcast`, `hermes-dashboard`, `noobservability` and the traefik dashboard.

**That was wrong, and the reason is the thing forward-auth cannot do.**

Forward-auth is a gate *in front of* an app. It does not log you *into* the
app. So on any app that has its own account system, the result is:

1. Authelia's login page, then
2. the app's own login page.

Two logins for one session — the exact opposite of single sign-on. And it
isn't fixable per app, because **most of these tools have no way to turn their
own auth off**. Jellyseerr, AFFiNE and Paperless all insist on an account;
the *arr apps can drop to "no authentication" only by also opening themselves
to anything that can reach the port. Trading a working app login for a
different login in front of it buys nothing.

Forward-auth is therefore kept for exactly two jobs, both of which it is
genuinely good at:

- **Apps with no auth of their own** — where it supplies the only login there
  is. Today: the homepage dashboard, `priv.s3.w`.
- **As an outer lock with a `bypass` policy** — attached to a route so that
  *external* requests hit `default_policy = "deny"`, while the home net passes
  straight through with no prompt. This is what the lockdown below does. It
  adds a deny layer without adding a login.

The `/api` problem that the earlier draft worried about is real but moot now:
forward-auth applies to the whole route including `/api`, which would break
Prowlarr→Sonarr sync, the homepage widgets and mobile clients. In practice
those all reach the backends by raw LAN IP and port (`192.168.3.203:8989` —
every widget `url` in `arr-slime.nix`), never through traefik, so they would
have been unaffected. It stopped mattering the moment the flips were dropped.

**Net effect on Tier 1:** the OIDC list narrows sharply too, for the same
reason. OIDC is only worth the wiring where the app can then treat the OIDC
identity as *its own* account — which is why **Grafana and Immich** are the
whole shortlist. Paperless, Jellyseerr and AFFiNE technically support OIDC, but
each would be a second identity source bolted onto an app whose local accounts
already work; the payoff doesn't cover the config.

## Lockdown — paperless, seerr, affine

**Done.** These three keep their own logins and are now double-locked from
outside, with nothing extra to type at home:

| | |
|---|---|
| `traefik.ipfilter = true` | already set; traefik 403s any source outside the LAN/tailnet allow-list |
| `traefik.auth = true` | *new* — attaches authelia as a second, independent deny layer |
| authelia `access_control` | *new* — an explicit `bypass` rule naming the three domains for `networks = [ "internal" ]`, placed **above** the generic `*.home.phonkd.net` `one_factor` rule (first match wins) |

From the home net: authelia returns 200 without a prompt, and you land on the
app's own login. One login. From outside: ip-filter blocks it, and if that
allow-list were ever misconfigured, authelia still falls through to
`default_policy = "deny"`.

### The trap this uncovered

traefik's `ip-filter` allow-list and authelia's `definitions.network.internal`
had **drifted apart**:

| | ip-filter | authelia `internal` |
|---|---|---|
| `192.168.3.0/24`, `192.168.1.0/24`, `100.64.0.0/10` | yes | yes |
| `192.168.2.0/24` | yes | **no** |
| `10.8.0.0/16` | yes | **no** |

A client on either of those two ranges passes the firewall, then matches no
`networks = [ "internal" ]` rule, and falls through to
`default_policy = "deny"` — a 403 with no login prompt and no way in. It was
invisible while every `*.home` route was `auth = false`; the first flip would
have surfaced it as "paperless is broken for some devices". Both ranges are now
in `definitions.network.internal`, so "home" means the same thing to both
layers. Keep them in step.

## Tier 3 — leave alone

| app | why |
|---|---|
| **Vaultwarden** (`vw.w`) | Upstream has no OIDC (only the unmerged `Timshel/vaultwarden` SSO fork, not in nixpkgs). More importantly the Bitwarden clients hit `/api` and `/identity` directly — forward-auth would brick every client, including `bwu`/secretspec in this repo. Currently `auth = false, ipfilter = false`: correct, keep it. |
| **Home Assistant** (`home.phonkd.net`) | No native OIDC (only a community custom component). The companion app and every webhook/API call would break under forward-auth. This domain has already burned us once — see the `trusted_proxies` 400 in the `nixconfig` skill notes. |
| **Garage S3** (`s3.phonkd.net`, `api.s3.w`) | S3 auth is request signing. A login redirect is meaningless to an S3 client. `priv.s3.w` is already forward-auth'd and that is the right boundary. |
| **Authelia itself** (`auth.w`, `auth.home`) | It *is* the boundary. |
| **Jellyfin** (`jellyfin.w`) | Listed in Tier 1 for the plugin, but never forward-auth it — TV apps and Chromecast can't do a browser login. |

## Design notes that will bite if ignored

### One issuer, two cookie domains

Forward-auth today runs two portal names (`auth.w` / `auth.home`) precisely
because a session cookie is only valid for the parent domain that set it.
**OIDC has no such split** — there is exactly one `issuer` per Authelia
instance, and it has to be `https://auth.w.phonkd.net`.

That's fine on its own (OIDC hands the app an authorization *code*; it never
needs to read Authelia's cookie), but it means an app on `home.phonkd.net`
bounces the browser to `auth.w.phonkd.net` and back. The user therefore ends up
holding a session cookie on `w.phonkd.net` and, if they also use a
forward-auth'd `*.home` service, a second one on `home.phonkd.net`. Two logins,
not one, in that mixed case. Worth knowing before someone reports it as a bug.

### `X_AUTHELIA_CONFIG_FILTERS = "template"`

The moment `secrets.oidcIssuerPrivateKeyFile` is set, the nixpkgs module turns
on Authelia's Go-template config filter for **all** config files. Any literal
`{{` in our own settings, or in the sops-templated client file, is then
interpreted as a template. Watch for it in `notifier`/`session` strings.

### Per-client authorization policy

`access_control` rules gate *forward-auth*. OIDC clients are gated by their own
`authorization_policy` field instead. Enabling OIDC does **not** inherit the
"bypass from internal, two_factor from outside" behaviour — that has to be
restated as a named policy per client, or every OIDC login prompts for TOTP
even on the tailnet.

## Enabling the provider — the actual diff

In `modules/homelab/apps/authelia/authelia.nix`:

```nix
sops.secrets.authelia_oidc_hmac_secret = { sopsFile = ./authelia-secret.yaml; owner = "authelia-main"; };
sops.secrets.authelia_oidc_jwks_key    = { sopsFile = ./authelia-secret.yaml; owner = "authelia-main"; };

services.authelia.instances.main = {
  secrets.oidcHmacSecretFile       = config.sops.secrets.authelia_oidc_hmac_secret.path;
  secrets.oidcIssuerPrivateKeyFile = config.sops.secrets.authelia_oidc_jwks_key.path;
  # The client list carries client secrets -> must not land in the store.
  settingsFiles = [ config.sops.templates."authelia-oidc-clients.yaml".path ];
};
```

`authelia_oidc_jwks_key` is an RSA-4096 private key in PEM
(`openssl genrsa 4096`); `authelia_oidc_hmac_secret` is 64 random characters.

The client list is a sops **template**, so each client's secret is interpolated
from its own sops key at activation:

```nix
sops.templates."authelia-oidc-clients.yaml" = {
  owner = "authelia-main";
  content = ''
    identity_providers:
      oidc:
        clients:
          - client_id: grafana
            client_name: Grafana
            client_secret: ${config.sops.placeholder."oidc_grafana_client_secret_digest"}
            public: false
            authorization_policy: one_factor
            redirect_uris: [ "https://grafana.phonkd.net/login/generic_oauth" ]
            scopes: [ openid, profile, groups, email ]
  '';
};
```

## The automation: `nix develop` → `sso-secret <app>`

### What's missing today

1. **There is no devShell.** `flake.nix` has no `perSystem.devShells`, so
   `nix develop` in this directory drops you into an empty shell. Anything here
   starts with adding one.
2. **`.sops.yaml` has no creation rule for per-app secret files.** The only
   rules are `secrets/wg-endpoint.json` and `modules/homelab/global-secrets`.
   `modules/homelab/apps/authelia/authelia-secret.yaml` matches *neither* — it
   was encrypted by hand. So `sops` on a brand-new per-app file fails with
   "no matching creation rules found". A rule covering
   `modules/homelab/apps/.*-secret\.yaml` is a prerequisite, not a nicety.
3. **The `authelia` CLI cannot be installed on the Mac.** `nixpkgs#authelia` is
   marked broken on `aarch64-darwin` (its `authelia-web` frontend derivation is
   broken) on both `nixos-26.05` and `nixos-unstable`. That kills the obvious
   `authelia crypto hash generate pbkdf2` call.

### Consequence of (3): default to `$plaintext$`

Authelia accepts `client_secret: '$plaintext$<secret>'`. Given the secret is
age-encrypted in git and lands at `/run/secrets/...` owned by `authelia-main`
mode 0400, PBKDF2 hashing on top buys very little here — it protects against a
config *leak*, which sops already covers. The tool therefore defaults to
`$plaintext$` and offers `--hash`, which shells out to
`ssh 201-mono authelia crypto hash generate pbkdf2` (authelia *is* installed
there) for anyone who wants the digest form.

### Shape

`nix develop` puts `sops-secret` and `sso-secret` on `PATH` directly, and a
thin `Taskfile.yaml` wraps them so `task` works too:

```
nix develop
sso-secret grafana --redirect https://grafana.phonkd.net/login/generic_oauth
sops-secret hermes.openrouterkey            # generic: prompts, encrypts, writes
task sso-secret -- grafana --redirect ...   # same thing through go-task
```

`sso-secret <app>`:

1. generates a 72-char client secret (`openssl rand`)
2. writes it into `modules/homelab/apps/<app>/<app>-secret.yaml` as
   `oidc_<app>_client_secret` (plain, for the app to send) and
   `oidc_<app>_client_secret_digest` (`$plaintext$`-prefixed, for Authelia),
   creating and encrypting the file if it doesn't exist
3. prints the two nix snippets to paste — the Authelia `clients:` entry and the
   app-side `sops.secrets` + config stanza

Step 3 stays manual on purpose. Auto-editing `.nix` files from a shell script
is how you end up in a formatter fight with a broken eval; a printed snippet is
a two-second paste and stays reviewable.

## Suggested order

1. ~~**devShell + `.sops.yaml` rule + the two scripts.**~~ **Done** — see
   `modules/devshell.nix`, `scripts/sops-secret.sh`, `scripts/sso-secret.sh`,
   `Taskfile.yaml`. Independently useful: `sops-secret` replaces the hand-run
   `sops set ...` for every secret in the repo, SSO or not. `perSystem` only,
   so no host closure changed and there is nothing to deploy. Verified by
   creating a per-app file, adding a second key to it, decrypting it back, and
   running the full `sso-secret` flow.
2. ~~Flip `traefik.auth = true` on the Tier-2 internal apps.~~ **Dropped** —
   see "Why not forward-auth". The *arr stack, sabnzbd, slskd, syncthing,
   snapcast, hermes-dashboard, noobservability and the traefik dashboard all
   stay `auth = false`; they are already unreachable from outside via
   `ipfilter`, and adding authelia in front would only add a second login.
3. ~~**Lockdown of paperless / seerr / affine.**~~ **Done** — `auth = true` +
   `ipfilter = true` + an internal `bypass` rule, and the
   ip-filter/`internal` network drift fixed. See "Lockdown" above.
4. **Enable the OIDC provider** (hmac + jwks secrets, empty client list).
   Deploy 201, confirm
   `https://auth.w.phonkd.net/.well-known/openid-configuration` answers.
   `sso-secret <app>` generates the per-client material from there.
5. **Grafana, then Immich.** phonkd is doing these directly.
6. Nothing else is queued. Headscale, Proxmox and oCIS remain documented in
   Tier 1 in case the appetite ever returns; oCIS specifically is only worth it
   if a day of client-side debugging is acceptable.
