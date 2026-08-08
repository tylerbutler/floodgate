# ADR-010: One DETS file per document

- **Status:** Accepted
- **Date:** 2026-08-08
- **Supersedes:** the single-file layout of
  [ADR-005](005-floodgate-storage-backend.md) (shelf/WriteThrough/public-ETS all
  stand; only "a handful of server-wide tables" changes), and closes its
  **known risk 2**
- **Related:** [ADR-001](001-ets-public-access.md) (public ETS access),
  [ADR-004](004-coexisting-client-stacks.md) (decoupled server stacks)

## Context

ADR-005 put Floodgate on shelf with ~10 fixed DETS files for the whole server.
A document was a *row*: every op in one `ops.dets`, every blob in one
`objects.dets`, keyed by topic. That has three costs.

1. **Memory is bounded by history, not by activity.** shelf mirrors each DETS
   table into ETS at open, so a server that has ever written N documents holds
   all N resident for the life of the process. Nothing evicts, because there is
   nothing to evict — the table is the whole server.
2. **A document is not a unit.** There is no `delete_document` in
   `store.Backend` at all, and no way to copy, archive, or move one document.
3. **The DETS 2 GB per-file ceiling is server-wide**, shared by every document
   and tenant, and reaching it fails writes for everyone.

## Decision

**A document is a file.** `floodgate/doc_store` opens one shelf table per
document at `{data_dir}/documents/t{hex tenant}/d{hex document id}.dets`,
holding that document's marker, ops, summary pointer, and git objects in one
tagged key space — one file, one DETS handle, one ETS mirror.

1. **The runtime model does not change.** shelf's per-table ETS-in-front-of-DETS
   with `WriteThrough` *is* the previous runtime model, now scoped per document.
   Reads stay memory-speed, writes stay durable immediately, and no caller
   changed how it reads or writes.

2. **Only non-document-scoped data stays shared.** Refs (plus their index),
   tenants, admin users, and admin sessions remain in `shelf_store`'s tables.
   Refs stay shared deliberately: `GET /repos/:tenant/git/refs` lists a whole
   tenant's refs, which per-document files would turn into a filesystem walk,
   and a copied document's ref is reconstructible from its summary pointer —
   `doc_state.restore_summary_ref` already does exactly that repair.

3. **Git objects become document-scoped.** `store.put_obj`/`get_obj` are keyed
   by topic. The Historian routes are tenant-scoped URLs, but the caller's token
   already carries `documentId` and the handlers were discarding it. This is
   what lets a document's storage be self-contained.

4. **One supervised owner actor.** It opens tables (serializing opens, which
   would otherwise build two ETS mirrors over one DETS file) and owns their ETS
   mirrors, so a table outlives the REST handler or session actor that first
   touched it. This is a deliberate departure from ADR-005 decision 2 ("storage
   stays a value, not a process") — the `store.Backend` closure seam is
   unchanged, but there is now a process behind it, and `store.supervise` must
   be applied to the tree before anything calls in.

5. **Resolution stays out of the actor.** Open tables are published in a public
   ETS table via `floodgate/doc_registry` — the same mechanism, generalised over
   its stored value — so a hit resolves in the calling process with no message
   hop. Only a miss pays the call.

6. **Eviction on idle, plus an open-file cap.** The owner sweeps on the same
   cadence and the same `FLOODGATE_DOC_IDLE_MS` window the document actors
   already use, and evicts the least recently used at
   `FLOODGATE_MAX_OPEN_DOCUMENTS`. This is what converts (1) into a bound on
   *active* documents.

7. **Reads never create.** Opening a shelf table creates its DETS file, so reads
   pass `create: False` and miss instead. `has_document` is then a `stat`, not
   an open.

## Why this is acceptable

- **Eviction cannot lose data.** `WriteThrough` already put every write on disk,
  so closing is a cache drop and the next touch reopens the same contents.
- **The evict/use race is safe by construction.** `shelf_ffi` wraps every ETS
  call in `try`/`catch` and returns `TableClosed`, so a caller that resolved a
  handle just before eviction gets an error rather than a crash;
  `doc_store.with_table` drops the stale row, reopens, and retries once. No lock,
  no message hop on the hot path.
- **Client-supplied ids are contained.** Both path components are hex-encoded:
  reversible (`xxd -r -p` names the document), fixed alphabet, no traversal, no
  case-folding collision, no length surprise, and one code path rather than a
  sanitise-or-hash conditional. shelf's `base_directory` validation sits
  underneath. Opening is not `let assert`ed, so a bad id cannot take the node
  down.
- **Unauthenticated probes cost a `stat`.** `doc_state.stored_document_exists`
  is reachable unauthenticated; without the read/write split it would open — and
  therefore create — a file per probe.

## Consequences

- **Cross-document blob dedup within a tenant is gone.** Two documents uploading
  identical bytes store them twice. This is the price of a self-contained
  document, and it is the intended trade.
- **A blob is only readable with a token for the document it was written under.**
  Previously any token for the tenant would do. The official drivers always use
  the document's own token, so this is a tightening rather than a break.
- **`GET /repos/:tenant/git/blobs/:sha` authorizes before reading.** The fetch
  used to be evaluated as part of the case subject, so an unauthenticated
  request still did the read.
- **Cold opens cost more.** shelf streams the whole DETS file through its decoder
  into ETS, so a document with a large summary blob pays that on each cold open,
  and that blob is resident while the document is active. Memory is now bounded
  by *active* documents, not by document *size*.
- **The old shared `objects.dets` is retained read-only** as a fallback on a
  per-document miss, so pre-split blobs stay readable without a migration that
  would have to walk each ref's commit → tree → blob graph to attribute every
  sha. Nothing writes to it any more.
- **No migration for ops/summaries/markers.** Their shared tables are gone; a
  pre-split data directory reads back empty. Accepted deliberately — there is no
  deployed data to preserve.
- **Config:** `FLOODGATE_MAX_OPEN_DOCUMENTS` (default 1024, `0` disables).
  `FLOODGATE_DOC_IDLE_MS` is reused rather than adding a second window.

## Known risks

1. **One directory per tenant.** Fine to millions of entries on ext4, slow to
   list. Two-level fanout is the upgrade if it ever matters.
2. **File descriptors.** Each open document costs a DETS handle, a shelf
   guardian process, and an ETS table. `FLOODGATE_MAX_OPEN_DOCUMENTS` is the
   bound; the idle sweep is what normally keeps it well below.
3. **The fragile `make_table_public` FFI** is unchanged from ADR-005 risk 1 and
   now runs per document as well as per shared table.

## What this closes

ADR-005 recorded as known risk 2 that *"cross-restart durability is not
unit-tested — the `store.Backend` closure interface has no `close()`, so a
close-then-reopen cannot be driven cleanly in a test."* Per-document tables give
a real close hook: `store_backend_test.doc_store_reopens_evicted_documents_test`
drives write → evict → read through the open-file cap, deterministically and
without sleeping, and fails if the cap is disabled.

## Alternatives considered

### Keep one file per document but only for load/save, with a shared runtime

The original framing. **Rejected as a distinction without a difference:** shelf's
per-table ETS mirror already *is* the shared-runtime model, so scoping the table
per document gives the same runtime for free. A separate load/save layer over a
server-wide ETS table would have been more code and would not have bounded
memory.

### Plain per-document files (`term_to_binary`) instead of DETS

Simpler — no open/close lifecycle, no fd management, no repair. **Rejected**
because durability then requires rewriting the whole document on every op.
DETS is what buys incremental write-through at a per-key cost.

### Four tables per document (ops, summary, objects, marker)

Typed keys instead of a tagged key space. **Rejected:** four files and four file
descriptors per document undercuts "a document is a file", for a type-safety win
that one tagged decoder gives anyway.

### Shard into N files by `hash(topic) mod N`

Fixes the 2 GB ceiling with almost no lifecycle change. **Rejected:** it gives
neither per-document portability nor eviction, which are two of the three
motivations.

### Evict when a document actor stops

The lifecycle already exists. **Rejected:** the read-only REST paths open tables
for documents that never get an actor, so that would leak exactly the documents
nobody is collaborating on. One timer in `doc_store` covers both.
