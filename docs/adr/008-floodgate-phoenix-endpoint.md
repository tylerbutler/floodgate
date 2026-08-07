# ADR-008: Dual-mode Floodgate — add a Phoenix Channels endpoint

- **Status:** Accepted
- **Date:** 2026-08-04 (implemented 2026-08-04)
- **Related:** [ADR-004](004-coexisting-client-stacks.md) (coexisting client
  stacks), [ADR-005](005-floodgate-storage-backend.md) (shelf storage),
  [ADR-007](007-signet-token-library.md) (signet tokens), the
  `levee_protocol → spillway` convergence.

## Context

ADR-004 established two supported stacks that do not share a server:

- **Levee**: Elixir/Phoenix server ⇄ `levee-driver`/`levee-client`
  (Phoenix Channels wire protocol).
- **Floodgate**: Gleam server on beryl/mist ⇄ `floodgate-client`
  (official Routerlicious driver, Engine.IO/Socket.IO wire protocol).

Floodgate today speaks **only** Socket.IO (`floodgate/socketio_transport` at
`/socket.io/`). But the surrounding pieces have converged to the point where a
second, Levee-compatible endpoint is mostly wiring:

1. **beryl is a Phoenix Channels analogue, and Phoenix is its native wire
   format.** Its canonical codec is `beryl/wire.phoenix_codec()` — the Phoenix
   V2 array framing `[join_ref, ref, topic, event, payload]`, exactly what the
   `phoenix` npm client (used by `levee-driver`) speaks at `vsn=2.0.0`. beryl
   also ships a stock mist transport (`beryl/transport/mist.handler`) and
   handles the reserved `"phoenix"`-topic heartbeat natively.
2. **One beryl instance can serve both wire formats.** The coordinator's
   `SocketConnected` message carries `codec: Option(Codec)` — a per-connection
   codec that falls back to the configured one. Sockets from different
   transports share the same coordinator, pubsub, channels, and session.
3. **The event vocabulary is already identical.** `dewdrop/events` defines
   `connect_document`, `connect_document_success`/`_error`, `submitOp`,
   `submitSignal`, `op`, `signal`, `nack` — the same names `levee-driver` and
   Levee's `DocumentChannel` use.
4. **Auth, protocol, and REST are already unified.** Tokens are signet
   (ADR-007), sequencing is spillway, and floodgate's REST surface already
   serves both dialects: Routerlicious-style `/documents/:tenant/:doc/deltas`
   *and* Levee-style `/deltas/:tenant/:doc` with the `{value: [...]}` envelope
   that `leveeDeltaStorageService` reads, plus the `/repos/:tenant` git surface
   that `urlResolver` points storage at.

What floodgate cannot do today is accept a `levee-driver` connection: the
driver connects a Phoenix socket to `<host>/socket` (the phoenix client appends
`/websocket`), joins `document:{tenant}:{doc}` with `{token}` params, then
pushes `connect_document` and listens for `connect_document_success` — none of
which the Socket.IO transport understands.

## Decision

Add a Phoenix Channels endpoint to floodgate at `/socket/websocket`, served by
the **same** beryl instance, channels, session, and storage as the Socket.IO
endpoint. A single floodgate process then supports:

- **Routerlicious mode** — official Fluid drivers via `/socket.io/` (unchanged).
- **Levee mode** — `levee-driver`/`levee-client` via `/socket/websocket`,
  wire-compatible with the Elixir server's `DocumentChannel`.

### Design

**1. Codec inversion.** Configure beryl with its canonical codec:
`beryl.config(wire.phoenix_codec())`. The Socket.IO transport already decodes
inbound frames itself; for outbound it passes its dewdrop/Routerlicious codec
per-connection via `SocketConnected(codec: Some(server_codec.server_codec()))`
(today it passes `None` and inherits the configured codec). The stock beryl
mist transport then serves Phoenix framing at `/socket/websocket` with no
custom transport code. Handler chain on one listener:
`/socket.io/` websocket → socketio transport; `/socket/websocket` websocket →
beryl stock transport; everything else → existing REST handler.

**2. Two-phase connect in `document_channel`.** The two wire protocols enter
the channel differently:

| | Socket.IO (today) | Phoenix (new) |
|---|---|---|
| Join | `connect_document` event *is* the join; payload carries token + mode | `phx_join` with `{token}` params; reply `ok` |
| Connect | — (done at join; `JoinOk` reply carries connected response) | client pushes `connect_document` (IConnect: `tenantId`, `id`, `token`, `client`, `mode`, `versions`); server **pushes** `connect_document_success` / `connect_document_error` (not a Phoenix reply) |

Refactor `document_channel.join` to extract the connect core (authorize →
`session.connect` → build connected response → join-op/presence fan-out) into
a function used by both paths:

- Socket.IO join: unchanged single-phase behavior.
- Phoenix join: verify the token against topic tenant/doc (mirroring Levee's
  `join/3`, which only parses the topic — we go slightly stricter and
  authenticate here too), reply `ok`, mark the socket "joined but not
  connected". `handle_in("connect_document")` then runs the connect core and
  pushes `connect_document_success`. Events received before connect are
  nacked/ignored, mirroring Levee's `connected` assign guard.

Note `mode` is absent from Phoenix join params — it arrives in the
`connect_document` payload, which is another reason `session.connect` must be
deferred to phase two on this path.

**3. Close the small event-handling gaps** (all in `document_channel`, shared
by both modes where sensible):

- `submitSignal`: accept Levee's payload shape
  `{clientId, contentBatches: [[{content, targetClientId?}]]}` alongside the
  current `{clientId, signals}`. Reuse spillway's v1/v2 signal normalization
  (what Levee's `Bridge.normalize_signal_batch` calls) instead of a third
  ad-hoc parser, and support targeted signals.
- `noop`: add `{clientId, referenceSequenceNumber}` handling to advance the
  client's RSN (Levee has it; floodgate doesn't). Without it, MSN stalls for
  idle Levee-mode clients.
- `requestOps`: already compatible (`{from}` → `op` push).
- `op` fan-out: no change — floodgate pushes bare op arrays; the driver's
  `normalizeOpPayload` accepts arrays, `{documentId, op}`, and `{ops}`.
- `connect_document_success` payload: no change — floodgate's
  `connected_response` is a superset of the driver's `ConnectedResponse`
  (extra `summaryHandle`/`summarySequenceNumber` fields are ignored;
  `normalizeConnectedResponse` fills defaults).

**4. Heartbeats: no work.** The phoenix js client heartbeats on the reserved
`"phoenix"` topic; beryl classifies that as `Heartbeat` and replies via
`wire.heartbeat_reply`. Document-level `ping`/`pong` latency events are dormant
in both implementations (the driver listens for `pong` but nothing sends
`ping`) — explicitly out of scope.

**5. Serialization: JSON only, initially.** `levee-driver`'s msgpack mode uses
`vsn=3.0.0` with a custom serializer. beryl codecs support binary decoders
(`with_binary_decoder`, `decode_binary_message`), so msgpack can be layered on
later; it is not required for parity with the Elixir server's default path.

**6. REST: no changes.** `urlResolver` produces
`deltaStorageUrl = /deltas/:tenant/:doc` and `storageUrl = /repos/:tenant`,
both already served by floodgate in the correct dialect (delta envelope
`{value: [...]}` included). Document create (`POST /documents/:tenant`) exists.
Contract tests must pin this rather than assume it.

### Conformance testing

Extend the shared fixtures approach from ADR-004: run
`levee-driver`'s integration contract (`floodgate-contract.ts`) with the *full
driver* against floodgate's Phoenix endpoint, alongside the existing
Routerlicious-driver coverage of the Socket.IO endpoint. Both suites exercise
the same server process to prove the dual-mode claim, including cross-mode
fan-out (a Socket.IO client and a Phoenix client collaborating on one
document).

## Resolved questions

- **Nack payload shape.** Resolved as recommended: floodgate keeps its bare
  nack array and the driver grew `normalizeNackPayload` (mirroring
  `normalizeOpPayload`) accepting all three shapes. This was also a live bug
  fix — the driver's handler wrapped the whole payload as a single `INack`, so
  it was already wrong against the Elixir server's `{clientId, nacks}`.
- **`lastSeenSequenceNumber` catch-up.** Not implemented. `initialMessages` +
  `requestOps` suffice; `levee-driver` never sends the field, so the Elixir
  server's catch-up path is unexercised by it today. Revisit only if a client
  starts sending it.
- **Transport path matching.** Confirmed working with no beryl change.
  `beryl_mist.upgrade` compares only the normalised path, so the query string
  (`?token=…&vsn=2.0.0`) does not participate; `vsn=2.x` is admitted and
  `vsn=3.x` is rejected at the handshake, which correctly refuses the driver's
  msgpack mode (out of scope per §5). `with_on_connect` is deliberately **not**
  used: its assigns return type is restored into the channel's assigns type
  unchecked, and the Socket.IO transport seeds different connect assigns. The
  token is validated at join instead, matching Levee.

## Consequences

- Floodgate becomes a drop-in replacement for the Elixir Levee server for
  existing `levee-client`/`levee-driver` apps — one Gleam binary, two client
  ecosystems. This advances the full-Gleam-stack direction without deprecating
  either client stack (ADR-004 stands; the stacks now merely *may* share a
  backend).
- `document_channel` grows a connect-core refactor and a per-mode join path;
  the Socket.IO transport changes one line (per-socket codec). No beryl changes
  are expected unless path matching (open question 3) demands one.
- The test matrix grows: two wire protocols × the existing conformance suite,
  plus cross-mode collaboration tests.
- The Elixir server's retirement becomes a product decision rather than a
  technical necessity — explicitly **not** decided here.

### Discovered during implementation

- **Origin policy differs between the two endpoints.** beryl's mist transport
  defaults to a same-origin policy and rejects cross-origin browser upgrades
  with 403; the Socket.IO path has no origin check at all. Non-browser clients
  (no `Origin` header) are admitted either way, so test suites are unaffected,
  but a browser `levee-client` served from another origin needs
  `FLOODGATE_ALLOWED_ORIGINS` (comma-separated allow-list, or `*` to disable
  checking). This asymmetry is intentional — the Phoenix endpoint is the
  stricter of the two — but it is a real behavioral difference to know about.
- **Signal targeting is honoured** (initially deferred; closed later).
  `submitSignal` accepts Levee's `{clientId, contentBatches}` alongside the
  existing `{clientId, signals}`, normalizing through spillway's
  `normalize_signal_batch` — the same path levee's
  `Bridge.normalize_signal_batch` takes — and recipients now come from
  `spillway/session_logic.determine_signal_recipients`, the same function
  levee's `Bridge.determine_signal_recipients` calls.

  The original blocker was that `beryl.send_info` needs a `RegisteredChannel`
  handle which does not exist when the channel is constructed, and `register`
  takes the channel. `document_channel` resolves that with a small holder built
  before `register` and filled in immediately after; a targeted signal reads it
  at push time. Addressing a recipient needs no client→socket map, because
  floodgate assigns `socket.id(sock)` as the Fluid client id — the two are the
  same string. Untargeted signals keep the topic broadcast, which is one
  coordinator message instead of one per recipient and avoids resolving a
  recipient list at all.
- **The beryl-main migration was deferred.** The ADR assumed floodgate could
  move onto beryl's current `main` to pick up the split-out `beryl_mist`
  package and the public transport SPI. It cannot yet: `dewdrop` and
  `aquamarine` both still consume beryl in its pre-split root-package form
  (aquamarine pins an old beryl commit outright), and subdirectory git
  dependencies additionally require Gleam ≥ 1.18. Floodgate therefore stays on
  its pinned pre-split beryl, where `beryl/transport/mist` and the per-socket
  codec on `coordinator.SocketConnected` already provide everything this ADR
  needs. Two pieces of the migration were still done and are ready for
  whenever the ecosystem catches up: the repo moved to Gleam 1.18.1, and beryl
  gained `transport.socket_connected_with_codec` (branch
  `feat/per-socket-codec-spi`) so the per-socket codec is reachable from the
  supported SPI instead of the internal `beryl/coordinator` module.

## Alternatives considered

- **Two beryl instances (one per codec) sharing pubsub + session.** Works, but
  per-socket codecs make it unnecessary; two coordinators would double the
  socket bookkeeping and complicate presence/roster consistency.
- **Teach `levee-driver` Socket.IO instead.** Rejected: ADR-004 deliberately
  keeps `levee-driver` as the Phoenix Channels stack, and the point of this
  ADR is server-side convergence without touching either client's transport.
- **Status quo (Elixir server remains the only Phoenix endpoint).** Keeps two
  servers alive indefinitely and blocks consolidating operational surface onto
  floodgate.
