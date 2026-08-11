# ADR-009: Extracting Floodgate into its own repository

- **Status:** Accepted (preparation); blocking coupling resolved 2026-08-10
  (see "Resolution" below); extraction not yet performed
- **Date:** 2026-08-05
- **Supersedes:** nothing
- **Related:** [ADR-004](004-coexisting-client-stacks.md), [ADR-005](005-floodgate-storage-backend.md), [ADR-008](008-floodgate-phoenix-endpoint.md)

## Context

Floodgate lives at `server/floodgate/` inside the Levee repository. It is a
self-contained Gleam application: its `gleam.toml` depends only on Hex packages
and sibling git repositories (`beryl`, `dewdrop`, `spillway`, `signet`, `silt`,
`windsock`), never on anything by relative path inside this repo.

Since ADR-008 it is also *dual-mode*: one process serves the official
Fluid/Routerlicious drivers on `/socket.io/` and Phoenix Channels clients
(`levee-driver`/`levee-client`) on `/socket/websocket`. That makes it a
candidate drop-in replacement for the Levee Elixir server, and therefore a
candidate for its own release cadence and repository.

This ADR records what was done to prepare for that extraction, and — more
importantly — the one coupling that genuinely blocks it.

## Decision

Prepare Floodgate for extraction now; do not extract yet. Specifically:

1. Give Floodgate the operational surface a standalone service needs
   (`/health`, configurable port and bind address, a container image).
2. Prove drop-in parity by running Levee's *own* integration suites against
   Floodgate, unmodified.
3. Document the Levee→Floodgate code dependency that must be resolved first.

## The blocking coupling

Floodgate does not depend on Levee, but **Levee depends on Floodgate**.

`server/lib/levee/floodgate.ex` delegates to six Gleam modules that Floodgate
owns, and `server/lib/levee/application.ex` asserts they are loadable at boot:

| Gleam module | What Levee uses it for |
|---|---|
| `floodgate@socketio` | Engine.IO/Socket.IO frame classification and encoding |
| `floodgate@connect_document` | `connect_document` payload shape, mode/scope decisions |
| `floodgate@session_logic` | feature/version negotiation, sequenced-op and summary-ack builders, op-history trimming |
| `floodgate@signals` | signal v1/v2 normalization, recipient targeting |
| `floodgate@nack` | nack construction |
| `floodgate@rest` | REST response shaping shared with Levee's controllers |

`server/mix.exs` (`gleam_build/1`) compiles `floodgate/` as part of every Levee
build, and `application.ex` lists it in `gleam_packages`.

So moving the directory out of this repo would break the Levee server. Three
ways to resolve it, in order of preference:

1. **Promote the shared modules into `spillway`.** These six are protocol-shape
   logic, not server runtime — `spillway` is already the shared Fluid protocol
   implementation both stacks depend on, and much of this logic is built on it.
   Floodgate then keeps only its server runtime (`floodgate.gleam`, `auth`,
   `document_channel`, `session`, `git`, `initial_summary`, `store` and the two
   store backends, `server_codec`, `socketio_transport`), and Levee's
   `Levee.Floodgate` becomes `Levee.Spillway` — no cross-repo dependency in
   either direction. **Recommended.**
2. **Levee takes Floodgate as a Gleam git dependency.** Cheapest to execute, but
   inverts the intended layering: the Elixir server would pull in an entire
   Fluid server, including its Mist listener and storage backends, to reach six
   pure modules.
3. **Duplicate the modules.** Rejected — this is exactly the divergence ADR-004
   and the shared conformance fixtures exist to prevent.

Option 1 is a three-repo change (spillway → floodgate → levee), the same
cascade noted for the beryl-main migration in ADR-008, and is deliberately left
out of this ADR's scope.

### Resolution (2026-08-10)

Option 1 was executed (tylerbutler/spillway#9 plus the two follow-up commits
in this repo). Three of the six modules — `socketio`, `connect_document`,
`rest` — moved into spillway; the other three (`session_logic`, `signals`,
`nack`) turned out to be pure re-export wrappers over modules spillway already
had, so callers now import spillway directly and the wrappers were deleted.
`spillway/socketio` declares the four Routerlicious event names locally
instead of importing `dewdrop/events`, because dewdrop depends on beryl — a
server runtime spillway must stay independent of; windsock (stdlib + json
only) is spillway's one new dependency.

`Levee.Floodgate` became `Levee.Spillway`, calling `:spillway@*` through the
`levee_bridge` package. `floodgate` was removed from `mix.exs` `gleam_projects`,
`application.ex`'s load/boot-check lists, the Levee `Dockerfile`, and
`rel/env.sh.eex`. Levee no longer compiles or boot-checks Floodgate; nothing
in the Levee server build references `server/floodgate/` anymore. All gates
held at baseline: Levee 375/0, floodgate 185/0, dual-mode 38 + 7, drop-in
parity 52 passed with only the two known 401-not-403 auth-status failures.

## Drop-in parity: what was verified

`just test-levee-suite-vs-floodgate` runs Levee's existing integration suites —
`levee-driver`, `levee-client`, `levee-example` — against Floodgate with no
Floodgate-specific code. The suites are simply repointed with
`LEVEE_HTTP_URL` / `LEVEE_SOCKET_URL` / `LEVEE_TENANT_KEY`; nothing in them is
Floodgate-aware, so every failure is a real behavioural difference.

Baseline against the Levee Elixir server: **54 passed, 0 failed**.

That comparison found, and this change fixed, nine divergences:

| # | Divergence | Fix |
|---|---|---|
| 1 | No `/health` route | Added, byte-identical to `HealthController` (`{"status":"ok"}`), plus `HEAD` (Phoenix answers HEAD for every GET route) |
| 2 | `POST /documents/:tenant` ignored the body's `id` | Honour it, matching `params["id"] \|\| generate_document_id()` |
| 3 | Same route authorized against document `""`, rejecting a document-scoped token | Authorize the tenant without binding to a document, as Levee's auth plug does when the route has no `:id` param |
| 4 | Created trees and commits returned only `{sha, url}` | Return the full object, as `GitController` does (blobs keep `{sha, url}`) |
| 5 | Every rejection was an opaque `{"error":"unauthorized"}` | Report Levee's wording via `signet`'s `format_error` — "Missing Authorization header", "Token expired at …", "Missing required scope: …". Statuses deliberately stay 401; see below |
| 6 | Initial summaries only parsed the Routerlicious whole-summary shape | Also accept the Fluid `ISummaryTree` shape (numeric `type`, `tree` map) that `levee-driver` posts |
| 7 | Snapshot layout always nested app data under `.app` | For a combined summary, flatten `.app`'s children to the root tree beside `.protocol`, as `process_initial_summary/3` does — `levee-driver`'s `convertGitTreeToSnapshotTree` does not unwrap `.app` |
| 8 | The client record in `initialClients` and in the sequenced join op was rebuilt from `mode` + token claims | Echo the `IClient` the peer sent, as `Session.client_join/2` does. The container seeds its audience with the object it sent, so a rebuilt record — missing `details.environment`, with server-side `scopes`/`user` — made the audience see two payloads for one client id and trip assert `0x4b2` |
| 9 | Git commits with a numeric `author.date` were rejected | `silt`'s `person_decoder` typed `date` as a string; it now accepts a number and renders it, matching Levee's passthrough |

Divergences 6 and 7 only apply to the combined summary `levee-driver` posts;
the official Routerlicious driver splits the summary client-side and posts the
app tree plus `values`, and that path is unchanged.

Divergence 8 was the cause of both `levee-example` failures — the container
close on load *and* the two-client sync timeout were the same assert.

**Result: 53 passed, 1 failed** — the one remaining failure is the deliberate
status divergence below. `just test-floodgate-dual-mode` stays fully green
(38 Routerlicious + 7 Phoenix/cross-mode).

### Accepted divergence: rejection status

Levee's `Plugs.Auth.error_response/1` — and `signet`'s own
`jwt.error_to_http_code` — answer **403** for a token that authenticates but is
not entitled (wrong tenant/document, missing scope). Floodgate answers **401**
for every rejection.

This is deliberate. The two statuses are not interchangeable to a Fluid client:
`401` prompts a token refresh and retry, `403` is fatal. Floodgate's
Routerlicious conformance suite pins `401`, and `floodgate-readiness.json`
gates release on that suite, so the Routerlicious contract wins.

The visible cost is one test: `rest-api.test.ts`'s "rejects requests with
insufficient scopes" expects `403` and gets `401`. Error *messages* still match
Levee's wording, so a client keying off the text behaves identically; only the
status differs. Revisit by splitting the status per endpoint (403 on the Phoenix
surface, 401 on Socket.IO) if a `levee-client` app is ever found to depend on
the distinction.

### Note on the silt bump

Divergence 9 was fixed in `silt` (`7df0c9e`) and `floodgate/manifest.toml` is
bumped to it, verified on a freshly resolved dependency tree and in the
container image.

The bump was originally applied by editing the pinned commit in
`manifest.toml` directly rather than with `gleam update silt`, because a full
re-resolve failed: `signet` was reachable both as a direct floodgate dependency
and through `spillway`, at two different commits, and `gleam` rejects that as
"conflicting provided dependencies".

**Resolved (2026-08-06):** the `signet` refs were aligned upstream, and a full
`gleam update` now succeeds. Doing so pulled in beryl's monorepo split
(`packages/beryl` + `packages/beryl_mist`, pinned to the `v0.0` tag) and its
new supervised-startup and `beryl/transport` APIs, which floodgate has been
migrated to — the beryl-main migration noted in ADR-008. Verified: floodgate's
Gleam suite, both dual-mode conformance suites, and Levee's Elixir suite all
pass on the freshly resolved tree.

## Consequences

- Floodgate has a container image (`server/floodgate/Dockerfile`,
  `docker-compose.yml`) that mirrors how Levee is run for integration testing,
  built from a `gleam export erlang-shipment` — no Elixir or Mix in the image.
- `PORT`/`FLOODGATE_PORT` and `FLOODGATE_BIND` make the listener configurable;
  Mist binds to localhost by default, which is unreachable from outside a
  container.
- Floodgate carries its own `README.md`, `justfile`, and CI workflow, so the
  extraction is a directory move plus a remote, not a reconstruction.
- Until the coupling above is resolved, `server/floodgate/` must stay in this
  repository.
