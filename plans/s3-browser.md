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
`browse.s3.phonkd.net`, public (`ipfilter = false`, no authelia) per an
explicit decision below — no login either way, at home or from the internet.

Filestash was the starting suggestion but was rejected: it has no supported way
to seed a connection without an admin console pass and a version-fragile
`config.json`, and it still renders a connect screen. s3manager is env-var
configured and drops straight into the bucket.

## Steps

- [x] Create the read-only Garage key and grant R on `public`.
- [x] Store `s3-browser-key-id` / `s3-browser-secret-key` in sops.
- [x] Add `modules/homelab/apps/s3-browser.nix` + register in `builder.nix`.
- [x] Deploy 201-mono and verify the listing renders and a download works.
- [x] Made public at `browse.s3.phonkd.net` (was `s3.home.phonkd.net`,
      tailnet-only) — explicit decision, see below. Created the CNAME via the
      Cloudflare API (`browse.s3.phonkd.net` → `ddns.phonkd.net`) and added
      the matching entries in `modules/dns.nix` on both sides (Mac + 201's own
      dnsmasq), mirroring `s3.phonkd.net`'s existing pair.
- [ ] `sudo nix run nix-darwin/nix-darwin-26.05#darwin-rebuild -- switch
      --flake ~/git/nixconfig --impure` on the Mac, to pick up the new
      `browse.s3.phonkd.net` → tailnet-IP resolver entry. Not required for
      public reachability (real DNS already resolves it for everyone) — it
      only saves the Mac a public round trip / hairpin-NAT to reach its own
      home network. Left for the user: sudo + a rebuild of the machine
      running the agent is not something to do unprompted.

## Open decisions

Resolved: public, not tailnet-only. The bucket's *objects* were already
world-readable one-by-one by URL; an enumerable listing of all 89 keys is
marginally new information, but the explicit ask was for `browse.s3.phonkd.net`
to be public, so this ships without ipfilter or authelia.

Not resolved, flagged instead of fixed: s3manager's per-object **"Public
link"/"Download link" modal buttons are broken and cannot be fixed by
reconfiguring this module.** They build a raw `ENDPOINT/bucket/key` URL with
no signature (`public_access.go`), which assumes the backend allows anonymous
GetObject via a bucket policy — Garage has no such mode, so that URL 403s
regardless of what `ENDPOINT` points at (this is what produced the reported
`http://127.0.0.1:3900/public/id_ed25519_priv.pub` link — wrong host, but it
would 403 even fixed to a real hostname). Two ways to actually fix it:
  1. **Point people at the real public URL instead**: `https://s3.phonkd.net/<key>`
     (Garage's website endpoint, already public, already verified working).
     No config change; the browsable index makes the key names visible.
  2. **Make "Download link" (presigned, not "Public link") genuinely work**:
     add a new public traefik route for Garage's S3 API (port 3900) itself.
     Presigned URLs carry a valid SigV4 signature, so Garage would accept
     them without needing anonymous access — but the route change would make
     the *entire* S3 API network-reachable from the internet (traefik routes
     by Host header only, not by path/bucket), where today `api.s3.w.phonkd.net`
     is deliberately `ipfilter = true`. That is a materially bigger call than
     "browse the bucket" and was not made here — ask if it's wanted.

## Risks / rollout

Touches the reverse-proxy host: adds podman to 201 and one traefik router. The
container is `--network=host`, so no bridge or iptables chains are introduced
(same reasoning as affine.nix), and :3904 is unreachable off-box because 201's
firewall opens only 22/80/443. Rollback is reverting the commit; the Garage key
can be dropped with `garage key delete s3-browser`.
