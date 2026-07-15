# ADR-005: Floodgate storage — shelf with WriteThrough and no storage process

- **Status:** Accepted
- **Date:** 2026-07-14
- **Related:** [ADR-001](001-ets-public-access.md) (public ETS access),
  [ADR-004](004-coexisting-client-stacks.md) (Levee and Floodgate are decoupled,
  independently supported server stacks)

## Context

Floodgate (the Gleam Routerlicious-compatible server) needs storage for
documents, ops, summaries, and git-like Historian objects (blobs/trees/commits/
refs). It previously used a hand-written raw-ETS FFI (`floodgate_store_ffi.erl`),
in-memory only (VM lifetime), exposed via `store.ets()`. The goal was to move
Floodgate onto [shelf](https://github.com/tylerbutler/shelf) (typed ETS + DETS)
— the same library `levee_storage` uses — for persistence and type safety.

Two existing constraints shaped the design:

- **ADR-004** keeps Levee and Floodgate as independent, decoupled server stacks.
  Floodgate storage must not couple into `levee_storage`.
- Floodgate models storage as a **value** — `store.Backend`, a record of
  closures — deliberately "not a process-global selection" (per `store.gleam`).
  Floodgate runs session actors but has **no dedicated storage process**, unlike
  Levee's `Levee.Storage.GleamETS` GenServer.

## Decision

1. **Floodgate uses shelf as separate code.** `floodgate/shelf_store.gleam` is
   its own `store.Backend` implementation over five shelf `PSet` tables, keeping
   Floodgate's topic/tenant key model and the existing closure seam. It does not
   wire into `levee_storage` and does not introduce a shared storage library.

2. **Storage stays a value, not a process.** No storage GenServer/actor. The
   `store.Backend` closures capture shelf table handles; writes go directly to
   public ETS tables from session actors and REST handler processes.

3. **Public tables via Floodgate's own FFI.** shelf creates `protected` tables;
   `floodgate_shelf_ffi:make_table_public/1` swaps each to `public`. This
   mirrors ADR-001's approach for `levee_storage` but is an **independent copy**
   — Floodgate does not share levee's `storage_ffi_helpers`.

4. **WriteThrough, not WriteBack.** Because there is no storage process to own a
   periodic/shutdown save lifecycle, tables open in `WriteThrough` mode so every
   write reaches DETS immediately. This delivers cross-restart durability
   without a save loop.

## Why this is acceptable

- **Per-document write ordering already exists.** As in ADR-001, the single
  writer for a document's data is its session actor, which serializes that
  document's operations. Public tables + direct writes are therefore safe;
  writes to different documents/tenants touch different keys and ETS guarantees
  per-operation atomicity.
- **Decoupled per ADR-004.** No shared code or deployment coupling with
  `levee_storage`; the two stacks independently depend on shelf.
- **Durable with no crash window.** WriteThrough persists every write, so
  Floodgate does not risk losing recent writes on a hard crash (which WriteBack
  would, since recent writes would live only in ETS until the next flush).

## Consequences

- **Writes are bounded by DETS/disk-layer I/O, not ETS/memory speed.** Reads
  stay memory-speed (ETS); only the write path pays the cost. Acceptable at
  current load. If per-message op writes become a bottleneck, the remedy is the
  WriteBack upgrade under "Alternatives".
- **Config:** data directory via `FLOODGATE_DATA_DIR` (default
  `priv/floodgate_data`), gitignored along with the test data dirs.
- `memory_store` remains for tests and embedding; `session.start()` defaults to
  it (ephemeral), while the standalone runtime (`serve`/`main`) uses shelf.

## Known risks

1. **Fragile FFI.** `make_table_public` reaches into shelf's opaque `PSet`
   tuple to swap the ETS reference — the same fragility as ADR-001, tracked in
   [shelf#49](https://github.com/tylerbutler/shelf/issues/49). If shelf adds a
   configurable access mode, this workaround can be removed.
2. **Cross-restart durability is not unit-tested.** The `store.Backend` closure
   interface has no `close()`, so a close-then-reopen cannot be driven cleanly
   in a test. Backend correctness is covered by the shared contract test;
   persistence is inherited from shelf's WriteThrough guarantee.
3. **No save lifecycle.** Fine under WriteThrough, but it is the reason
   WriteBack is not available today.

## Alternatives considered

### Shared storage abstraction (one library behind both stacks)

ADR-004 explicitly permits sharing storage abstractions, and this would remove
duplication. **Rejected (for now)** because the two backends have different key
models (Floodgate `topic`/`tenant` strings vs `levee_storage` `(tenant,
document)` tuples) and data shapes (bare tuples vs typed records). Forcing a
common interface today is premature and would add another external pinned
dependency to govern.

### Wire Floodgate into `levee_storage`

**Rejected:** couples the two server stacks, contrary to ADR-004.

### Storage GenServer/actor + WriteBack

The way to reclaim memory-speed, batched writes: an owner process holds the
tables and flushes ETS→DETS periodically and on shutdown (mirroring
`GleamETS`'s 30s `:periodic_save` + `terminate`). **Rejected for now** — it adds
a supervised process and a save loop for a throughput problem we do not have
yet, and re-introduces a serialization point the session layer already provides.
Documented as the future upgrade path if writes become disk-bound; it trades a
small crash-durability window for write throughput.

## Follow-ups

- **[dewdrop#5](https://github.com/tylerbutler/dewdrop/issues/5):** beryl `main`
  is ahead of dewdrop `main` in a breaking way (opaque `Codec`/`Inbound`). shelf
  was added to Floodgate's `manifest.toml` **without re-resolving the git deps**,
  so beryl stays on its last dewdrop-compatible commit. `gleam update` will break
  the Floodgate build until dewdrop adopts the opaque API.
- **Postgres backend** for Floodgate is not yet implemented (shelf is ETS+DETS).
- **WriteBack + storage actor** is the upgrade path if writes become disk-bound.
