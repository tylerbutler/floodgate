# ADR-003: Floodgate release readiness gate

- **Status:** Accepted
- **Date:** 2026-06-30
- **Updated:** 2026-07-13
- **Context:** Establishing standalone Floodgate release readiness while Levee
  remains an independent supported stack

## Context

ADR-004 supersedes the original plan to replace Levee with Floodgate. Levee's
Phoenix Channels stack and Floodgate's Routerlicious-compatible Gleam stack
will coexist with separate client packages. This ADR therefore gates a
standalone Floodgate release, not removal of Phoenix.

As of this update:

- `floodgate-routerlicious.test.ts` has 0 outstanding Floodgate-required
  `it.todo(...)` gaps, plus one Levee-proxy-only gap
  (see the file's header comment and `floodgate-readiness.json`).
  Official createContainer, op sequencing, op fan-out, nack, signal fan-out,
  session discovery, paginated REST delta catch-up, Routerlicious delta-storage
  catch-up, Historian blob/tree/commit/ref loading, sequenced summary ack/nack,
  persisted summary context, Loader-backed SharedMap convergence and late-join
  reconstruction, and stale-client reconnect recovery are executable against
  standalone Floodgate. Standalone authentication now requires a
  configured tenant and JWT key, enforces mode scopes, and exposes token minting
  only when a separate bearer credential is configured. Floodgate runtime
  consumers now use the typed `floodgate/store.Backend` boundary. Server tests
  show both ETS and actor-memory satisfy it and produce identical runtime,
  session, and Historian helper observations; those tests do not traverse HTTP
  or Socket.IO.
- `@tylerbu/floodgate-client` is release-ready and registered in the client
  Changie/npm pipeline around the official Routerlicious driver.
- Levee remains supported through `@tylerbu/levee-driver` and
  `@tylerbu/levee-client`; its controllers, auth, sessions, and admin UI are no
  longer retirement prerequisites.

## Decision

1. **`client/packages/levee-driver/test/integration/floodgate-readiness.json`**
   is the single source of truth for Floodgate release readiness. It records:
   - the required conformance categories (create/load/sync/reconnect/
     summaries/signals),
   - standalone `floodgate-direct` as the required release target,
   - both tracked conformance targets (`floodgate-direct`, `levee-proxy`),
   - the storage backends requiring full live validation (`ets`, `memory`) and
     the subset whose live runs have been recorded,
   - the independent Levee and Floodgate client/transport stacks,
   - the expected outstanding `it.todo` count in
     `floodgate-routerlicious.test.ts`, and
   - an explicit `readyForFloodgateRelease` boolean that a human must flip.

2. **`floodgate-readiness.ts`/`floodgate-readiness.test.ts`** make the gate
   executable and run in the default (non-network-gated) test suite:
   - `countOutstandingConformanceTodos()` scans
     `floodgate-routerlicious.test.ts` for `it.todo(...)` calls required by
     Floodgate-direct, excluding explicitly tagged Levee-proxy-only gaps.
   - The test suite fails if that live count drifts from
     `expectedOutstandingTodoCount` in the manifest, forcing anyone who
     changes conformance coverage to also touch the gate in the same
     change (instead of silently improving or regressing conformance
     without acknowledgment).
   - The test suite asserts the release flag matches the todo and recorded
     backend-validation state. It does not execute or independently attest to
     live runs.

3. **A standalone Floodgate release may proceed only after**:
   - `expectedOutstandingTodoCount` reaches `0` (all conformance gaps
     closed), AND
   - the standalone `floodgate-direct` target passes the full required
     create/load/sync/reconnect/summaries/signals surface once with
     `FLOODGATE_STORAGE_BACKEND=ets` and once with
     `FLOODGATE_STORAGE_BACKEND=memory`, AND
   - both runs are recorded in `verifiedLiveStorageBackends`, AND
   - `readyForFloodgateRelease` is deliberately flipped to `true`.

Both selectable executable variants passed the full live suite on 2026-07-13,
so `verifiedLiveStorageBackends` records `ets` and `memory` and
`readyForFloodgateRelease` is `true`.

4. **Floodgate release does not deprecate or remove Levee.** Any future
   retirement decision for either stack requires a separate ADR.

## Consequences

- The project has a durable mechanism that prevents claiming standalone
  Floodgate support before Routerlicious conformance is complete.
- Any PR that closes conformance gaps must update
  `floodgate-readiness.json`'s `expectedOutstandingTodoCount` (and, for the
  final gap, `readyForFloodgateRelease`) or its tests fail — making the manifest
  self-maintaining rather than a document that quietly rots.
- `just check-floodgate-readiness-manifest` checks repo-tracked consistency
  without a running service. It verifies recorded metadata only and does not
  claim to have executed either live run.
- `just check-floodgate-readiness` requires a running direct Floodgate target
  and executes the live Routerlicious conformance suite. It exits successfully
  only when the release flag is set, no Floodgate-required gaps remain, and all
  required backend runs are recorded.
- Levee can continue evolving independently without being treated as temporary
  scaffolding.

## Live backend validation procedure

The standalone executable reads `FLOODGATE_STORAGE_BACKEND`; valid values are
`ets` (the default) and `memory`. Invalid values fail startup. Run the complete
suite against each backend in turn, stopping the first server before starting
the second:

```bash
cd server/floodgate
FLOODGATE_STORAGE_BACKEND=ets \
FLOODGATE_JWT_SECRET=floodgate-routerlicious-compat-secret \
FLOODGATE_TOKEN_MINT_SECRET=floodgate-routerlicious-mint-secret \
gleam run
```

In another terminal:

```bash
just test-floodgate-routerlicious
```

Repeat with the actor-memory backend:

```bash
cd server/floodgate
FLOODGATE_STORAGE_BACKEND=memory \
FLOODGATE_JWT_SECRET=floodgate-routerlicious-compat-secret \
FLOODGATE_TOKEN_MINT_SECRET=floodgate-routerlicious-mint-secret \
gleam run
```

After both full runs pass, record `ets` and `memory` in
`verifiedLiveStorageBackends`, set `readyForFloodgateRelease` to `true`, and run
`just check-floodgate-readiness` against either direct backend as the final
executable gate. This validates the current ETS and actor-memory
implementations; it does not claim PostgreSQL support.

## Alternatives considered

### Prose-only checklist in a markdown doc

Rejected: nothing would fail the build if the checklist quietly went stale
relative to the actual `it.todo` count.

### Gate on CI/deploy config instead of a test

Rejected for now: the project doesn't have a deploy pipeline that reads
per-service readiness flags, and a test is easier to run locally
(`just check-floodgate-readiness-manifest` / `pnpm test`) and keeps the static
gate colocated with the conformance suite it measures. The release command adds
the required live direct-target run.
