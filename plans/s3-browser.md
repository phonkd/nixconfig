# S3 browser for the public bucket

**Repo(s):** `nixconfig`   **Status:** done

## Goal

Browse the contents of the Garage `public` bucket from a web UI, without the
viewer supplying any credentials.

## Approach

`s3.phonkd.net` is Garage's *website* endpoint: it serves objects by exact key
and has no directory listing (its root answers `404 NoSuchKey`). Listing is an
S3 API operation, and Garage 2.3 refuses unsigned API calls outright —
`403 AccessDenied: Garage does not support anonymous access yet` — with no
anonymous or bucket-policy mode to enable (`garage bucket allow` takes only
`--key`). So the *server* must hold a key even though the bucket is public; the
*viewer* still needs none.

Run `cloudlena/s3manager` (not in nixpkgs → podman, as with affine) on 201 with
a dedicated `s3-browser` Garage key holding **R** on `public` only, pinned to
that one bucket and with deletes disabled. Route it through traefik at
`s3.home.phonkd.net`, `ipfilter = true`, no authelia — tailnet-only, no login.

Filestash was the starting suggestion but was rejected: it has no supported way
to seed a connection without an admin console pass and a version-fragile
`config.json`, and it still renders a connect screen. s3manager is env-var
configured and drops straight into the bucket.

## Steps

- [x] Create the read-only Garage key and grant R on `public`.
- [x] Store `s3-browser-key-id` / `s3-browser-secret-key` in sops.
- [x] Add `modules/homelab/apps/s3-browser.nix` + register in `builder.nix`.
- [x] Deploy 201-mono and verify the listing renders and a download works.

## Open decisions

The index is internal (`*.home.phonkd.net`, tailnet-only) rather than public.
The bucket's *objects* are already world-readable by URL, but an enumerable
listing of all 89 keys is new information, so that is opt-in: swap the domain
to `*.w.phonkd.net` and set `ipfilter = false` to publish it.

## Risks / rollout

Touches the reverse-proxy host: adds podman to 201 and one traefik router. The
container is `--network=host`, so no bridge or iptables chains are introduced
(same reasoning as affine.nix), and :3904 is unreachable off-box because 201's
firewall opens only 22/80/443. Rollback is reverting the commit; the Garage key
can be dropped with `garage key delete s3-browser`.
