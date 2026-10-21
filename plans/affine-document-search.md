# AFFiNE document search

**Repo:** nixconfig  
**Status:** in-progress

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
- [ ] Configure pinned search container and enable AFFiNE's indexer.
- [ ] Commit to local main and deploy 203.
- [ ] Verify indexing and AFFiNE document retrieval against an existing note.

## Rollout / rollback

Only 203 changes. Deploy over the established LAN SSH path; expect an AFFiNE
restart. Disable the indexer and remove its container declaration to roll back;
keep the search data directory. Documents remain in AFFiNE's existing database.
