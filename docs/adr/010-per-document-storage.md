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
holding that document's marker, ops, summary pointer, and commits in one
tagged key space — one file, one DETS handle, one ETS mirror.

1. **The runtime model does not change.** shelf's per-table ETS-in-front-of-DETS
   with `WriteThrough` *is* the previous runtime model, now scoped per document.
   Reads stay memory-speed, writes stay durable immediately, and no caller
   changed how it reads or writes.

2. **Only non-document-scoped data stays shared.** Refs (plus their index),
   tenants, admin users, and admin sessions remain in `shelf_store`'s tables.
   Tenant namespaces hold shared blobs and trees. The ref index supports
   tenant-wide lookup without a document-file walk; the REST handler filters
   foreign document heads. The document actor reconstructs its reserved head
   from trusted publication state through `git.reconcile_summary_ref`.

3. **Amended: only commits require document ownership.** The original decision
   to store all git objects per document is superseded. Commits use the
   document topic; blobs and trees use the tenant namespace so official driver
   upload caches can reuse objects between documents. Reads retain the old
   document-scoped blob/tree fallback. Historian handlers use the token's
   `documentId` for commit reads despite their tenant-scoped URLs.

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

7. **Reads never create unknown documents.** Opening a shelf table creates its
   DETS file, so reads pass `create: False` and miss instead. The old
   file-existence-only `has_document` rule is superseded: a file can contain
   only staged commits. Shelf reads the document marker; session existence
   also accepts stored ops or a summary pointer. A staged commit cannot cause
   a later document-create conflict.

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
- **Unknown-document probes do not open files.**
  `doc_state.stored_document_exists` is reachable unauthenticated. A missing
  file remains a miss; an existing file may need a marker read to distinguish
  a document from staged objects. The open-file cap still applies.

## Consequences

- **Superseded: document-only blob/tree access and duplicate storage.** New
  blobs and trees support tenant-wide reuse. Raw commits require document
  ownership, and version reads require membership in that document's
  published first-parent chain.
- **A document file is not a self-contained archive.** A copy also needs its
  referenced shared blobs and trees.
- **`GET /repos/:tenant/git/blobs/:sha` authorizes before reading.** The fetch
  used to be evaluated as part of the case subject, so an unauthenticated
  request still did the read.
- **Cold opens read the document file into ETS.** Its ops, commits, and any
  legacy document-scoped objects remain resident until eviction. Tenant-shared
  objects have their own storage lifetime.
- **Legacy objects remain readable.** The old shared `objects.dets` remains a
  read-only fallback for the exact namespace key. New tenant-shared blobs and
  trees use the existing namespaced `doc_store` files. There is no unrestricted
  tenant fallback for client-supplied commit SHAs.
- **No migration for ops/summaries/markers.** Their shared tables are gone; a
  pre-split data directory reads back empty. Accepted deliberately — there is no
  deployed data to preserve.
- **Config:** `FLOODGATE_MAX_OPEN_DOCUMENTS` (default 1024, `0` disables).
  `FLOODGATE_DOC_IDLE_MS` is reused rather than adding a second window.

## Published history and recovery

The document actor owns publication pointers and reserved `refs/heads/<id>`
refs. It accepts an uploaded tree with an empty head/parent list for the first
summary, or the current published commit as both `head` and sole parent. An
initial-summary commit also counts as a published head. Competing proposals
cannot publish siblings.

Publication writes objects, the proposal, its ack, the pointer, and the ref
before a success reply. The pointer records the proposal sequence number.
Summary-bearing actor calls do not replay after an ambiguous failure.

Cold recovery reads the complete durable op log and the pointer, validates
server-authored ack/proposal pairs and their commit chains, then selects the
latest trusted publication. Under actor ownership, it copies exact legacy
commit bytes into the document namespace and repairs the pointer/ref. Recovery
does not add ops. Ref reconciliation replaces stale or ahead refs and removes
a stray ref when no publication exists.

Authorized history and own-head REST reads trigger this recovery without a
socket connection. A known damaged chain or failed repair returns 503 rather
than empty or partial history. A foreign or unpublished history ID returns 404.
Clients cannot write reserved heads (403); unrelated generic refs retain their
create/update behavior. Neither a supplied SHA nor a ref can authorize legacy
commit adoption.

The backend matrix covers failed publication writes and partial legacy copies
on memory and Shelf, including close/reopen through the one-file cap. The
opt-in `floodgate-summary-recovery.test.ts` case starts an owned Shelf process,
restarts it on the same directory, reads old versions before opening a socket,
and extends the recovered head. See the README for its command.

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
