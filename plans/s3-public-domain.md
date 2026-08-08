# S3 public domain

**Repo(s):** `nixconfig`   **Status:** in-progress

## Goal

Serve the existing Garage `public` bucket at `https://s3.phonkd.net` without
renaming or copying the bucket, and update the in-repo consumers of the old URL.

## Approach

Keep Garage's website root domain unchanged because the API and other website
buckets still use `*.s3.w.phonkd.net`. Add `s3.phonkd.net` as a second global
alias for the existing `public` bucket, then route that hostname through Traefik.

## Steps

- [x] Add the native Garage bucket alias and verify it against a known object.
- [x] Add the new Traefik route.
- [x] Add exact local DNS answers for the Mac and homelab clients.
- [x] Update dashboard assets to use `s3.phonkd.net`.
- [ ] Create the public DNS record, deploy `201-mono`, rebuild the Mac, and verify
      the new URL against a known object.

## Open decisions

None. A second native bucket alias avoids both a data migration and proxy-level
Host rewriting.

## Risks / rollout

The shared reverse proxy is touched, but only one router hostname changes. Parse
the affected Nix files first; deploy `201-mono`, then verify both the new hostname
and an existing object. The old route can be restored by reverting the commit;
the additional Garage alias is harmless and can also be removed explicitly.
