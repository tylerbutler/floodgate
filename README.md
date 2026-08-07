# Floodgate

A [Fluid Framework](https://fluidframework.com) server written in Gleam, running
on the BEAM.

Floodgate is **dual-mode**: one process serves both wire protocols from the same
coordinator, session, and storage, so clients of either kind collaborate on the
same document.

| Endpoint | Clients |
|---|---|
| `/socket.io/` | Official Fluid/Routerlicious drivers (`@fluidframework/routerlicious-driver`) |
| `/socket/websocket` | Phoenix Channels clients (`@tylerbu/levee-driver`, `@tylerbu/levee-client`) |

The Phoenix endpoint is wire-compatible with the Levee Elixir server's
`DocumentChannel`, which makes Floodgate a drop-in replacement for it. See
[ADR-008](../../docs/adr/008-floodgate-phoenix-endpoint.md) for the dual-mode
design and [ADR-009](../../docs/adr/009-floodgate-standalone-repo.md) for the
verified parity surface and the known gaps.

## Running

Floodgate refuses to start without an explicit JWT secret.

```sh
FLOODGATE_JWT_SECRET=dev-secret gleam run
```

Or as a container:

```sh
docker compose up -d --wait      # http://localhost:3000
docker compose logs -f floodgate
docker compose down -v
```

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `FLOODGATE_JWT_SECRET` | *(required)* | Verifies every REST and socket JWT |
| `PORT` / `FLOODGATE_PORT` | `3000` | Listen port (`PORT` wins) |
| `FLOODGATE_BIND` | `localhost` | Listen interface; containers need `0.0.0.0` |
| `FLOODGATE_TENANT_ID` | `fluid` | The single configured tenant |
| `FLOODGATE_TOKEN_MINT_SECRET` | *(unset)* | Enables the token-mint endpoint |
| `FLOODGATE_TOKEN_MINT_USER_ID` | `floodgate-token-mint` | User id in minted tokens |
| `FLOODGATE_TOKEN_MINT_USER_NAME` | `Floodgate Token Mint` | User name in minted tokens |
| `FLOODGATE_STORAGE_BACKEND` | `shelf` | `shelf`/`ets` (persistent DETS) or `memory` |
| `FLOODGATE_DATA_DIR` | `priv/floodgate_data` | Shelf DETS directory |
| `FLOODGATE_PUBLIC_URL` | `http://localhost:<port>` | Externally reachable base URL |
| `FLOODGATE_ALLOWED_ORIGINS` | *(same-origin)* | Comma-separated allow-list, or `*` |

### Limits

`FLOODGATE_ALLOWED_ORIGINS` applies to **both** socket endpoints. Non-browser clients —
including the official Fluid drivers — send no `Origin` and are admitted under the default
same-origin policy; the allow-list form is only needed for browser clients served from
another origin.

| Variable | Default | Purpose |
|---|---|---|
| `FLOODGATE_MAX_FRAME_BYTES` | `16777216` (16 MiB) | Inbound frame ceiling. Also what IConnected advertises as `maxMessageSize` and the Engine.IO handshake as `maxPayload` — one value, so the three cannot drift. Oversize frames close the socket. |
| `FLOODGATE_MAX_CONNECTIONS_PER_IP` | `256` | Concurrent sockets per peer address |
| `FLOODGATE_MAX_CONNECTIONS` | `4096` | Concurrent sockets node-wide |
| `FLOODGATE_MESSAGE_RATE` / `_BURST` | `1000` / `2000` | Per-socket inbound frames per second |
| `FLOODGATE_JOIN_RATE` / `_BURST` | `100` / `200` | Per-socket joins per second |

Set any limit to `0` to disable it. Defaults are deliberately generous — the conformance
suites open several concurrent sockets from one address and burst ops during sync tests —
so they bound abuse without shaping normal collaboration. The per-IP limit uses the real
socket peer address and deliberately ignores `X-Forwarded-For`, which a client can set
freely; behind a proxy every connection shares the proxy's address, so enforce per-client
limits there instead.

## HTTP surface

```
GET    /health                             Readiness probe — {"status":"ok"}
POST   /api/tenants/:tenant/token-mint     Mint a document token (dev/integration)

POST   /documents/:tenant                  Create a document (id from body, or generated)
POST   /documents/:tenant/:id              Create a document with an explicit id
GET    /documents/:tenant/:id              Document metadata
GET    /documents/:tenant/session/:id      Session discovery
GET    /documents/:tenant/:id/deltas       Ops catch-up
GET    /deltas/:tenant/:id                 Ops catch-up (Levee-style path)

GET    /repos/:tenant/commits              Commit history
GET    /repos/:tenant/git/refs             List refs
POST   /repos/:tenant/git/refs             Create a ref
GET    /repos/:tenant/git/refs/*path       Read a ref
PATCH  /repos/:tenant/git/refs/*path       Update a ref
POST   /repos/:tenant/git/{blobs,trees,commits}       Create a git object
GET    /repos/:tenant/git/{blobs,trees,commits}/:sha  Read a git object
```

## Development

```sh
just build     # or: gleam build --target erlang
just test      # or: gleam test
just format
just run
```

Conformance suites live in the Levee repository's client workspace and run
against a live server:

```sh
just test-floodgate-dual-mode          # both wire protocols, one process
just test-levee-suite-vs-floodgate     # Levee's own suites, repointed at Floodgate
```

## Architecture

Floodgate composes several sibling libraries rather than implementing the
protocol itself:

| Library | Role |
|---|---|
| [`spillway`](https://github.com/tylerbutler/spillway) | Fluid protocol: message types, sequencing, validation, signals, nacks |
| [`beryl`](https://github.com/tylerbutler/beryl) | Channel coordinator, pubsub fan-out, Phoenix framing |
| [`dewdrop`](https://github.com/tylerbutler/dewdrop) | Routerlicious/Socket.IO codec and event vocabulary |
| [`windsock`](https://github.com/tylerbutler/windsock) | Engine.IO/Socket.IO framing primitives |
| [`signet`](https://github.com/tylerbutler/signet) | JWT scopes and Fluid token handling |
| [`silt`](https://github.com/tylerbutler/silt) | Git object model for the Historian storage surface |
| [`shelf`](https://hex.pm/packages/shelf) | DETS-backed persistent storage |
| [`mist`](https://hex.pm/packages/mist) | HTTP/WebSocket server |

## License

MIT
