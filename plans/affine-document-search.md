# AFFiNE document search

**Repo:** nixconfig  
**Status:** done

## Goal

Restore Intelligence's document search, currently returning `SEARCH_UNAVAILABLE`.
Chat works, but the original self-host setup disabled the indexer and has no
embedding provider, leaving neither retrieval path available.

## Approach

Enable AFFiNE's native keyword indexer with the official Manticore 10.1.0 image
used by upstream 0.27.4. The pinned nixpkgs Manticore package explicitly omits
jieba, which AFFiNE's table definitions require; use the existing OCI module,
without custom units or application patches. Bind search to loopback on 203,
persist its derived index, and let AFFiNE's native jobs index existing documents.
Semantic/vector retrieval remains unavailable without an embedding provider.

## Steps

- [x] Confirm failure and inspect upstream retrieval, indexing, and module options.
- [x] Configure pinned search container and enable AFFiNE's indexer.
- [x] Commit to local main and deploy 203.
- [x] Verify native indexing and workspace-scoped retrieval of existing notes.

## Verification

Configuration committed as `e75d369`; deployment to 203 succeeded and was
confirmed. Both containers are active, AFFiNE HTTPS returns 200, and Manticore
only listens on loopback (9306/9308). Its native health check gates AFFiNE startup.
AFFiNE's existing predeploy migration created the search tables automatically.

The native indexing jobs populated 60 documents and 541 search units across
three workspaces, with no indexing errors. Workspace-scoped HTTP searches of the
same backend used by AFFiNE return the `2026-10-20` and `20.10.2026` pages with
the projection metadata required by document retrieval. A `Sonion` keyword query
returned no matches; that is distinct from the former unavailable backend.

The server rollout and index verification are complete. An authenticated
Intelligence UI retry is requested from the user and remains unverified. No
browser session was accessed and no user credentials were extracted for this
check.

## Rollout / rollback

Only 203 changes. Deploy over the established LAN SSH path; expect an AFFiNE
restart. Disable the indexer and remove its container declaration to roll back;
keep the search data directory. Documents remain in AFFiNE's existing database.
