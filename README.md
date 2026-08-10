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
| `FLOODGATE_JWT_SECRET` | *(required)* | Verifies every REST and socket JWT for the startup tenant (see Multi-tenancy) |
| `PORT` / `FLOODGATE_PORT` | `3000` | Listen port (`PORT` wins) |
| `FLOODGATE_BIND` | `localhost` | Listen interface; containers need `0.0.0.0` |
| `FLOODGATE_TENANT_ID` | `fluid` | Id of the tenant seeded at startup from `FLOODGATE_JWT_SECRET` |
| `FLOODGATE_GITHUB_CLIENT_ID` | *(unset)* | GitHub OAuth App client id. OAuth remains disabled when unset |
| `FLOODGATE_GITHUB_CLIENT_SECRET` | *(unset)* | GitHub OAuth App client secret |
| `FLOODGATE_GITHUB_REDIRECT_URI` | `<public-url>/auth/github/callback` | Explicit OAuth callback URI |
| `FLOODGATE_ADMIN_GITHUB_USERS` | *(unset)* | Comma-separated GitHub usernames permitted to become admins. Unset denies OAuth login |
| `FLOODGATE_ADMIN_SESSION_TTL_SECONDS` | `604800` | Admin browser session lifetime |
| `FLOODGATE_ADMIN_STATIC_DIR` | `priv/static/admin` | Built Lustre admin UI directory |
| `FLOODGATE_ADMIN_KEY` | *(unset)* | Bearer key for the tenant management API (see Multi-tenancy). Unset disables that API entirely |
| `FLOODGATE_TOKEN_MINT_SECRET` | *(unset)* | Enables the token-mint endpoint |
| `FLOODGATE_TOKEN_MINT_USER_ID` | `floodgate-token-mint` | User id in minted tokens |
| `FLOODGATE_TOKEN_MINT_USER_NAME` | `Floodgate Token Mint` | User name in minted tokens |
| `FLOODGATE_STORAGE_BACKEND` | `shelf` | `shelf`/`ets` (persistent DETS) or `memory` — also selects where tenants persist |
| `FLOODGATE_DATA_DIR` | `priv/floodgate_data` | Shelf DETS directory. One file per document under `documents/t<hex tenant>/d<hex document id>.dets`, plus shared files for refs, tenants, and admin data |
| `FLOODGATE_DOC_IDLE_MS` | `300000` (5 min) | Drop a document from memory once it has no connected client and has gone this long untouched — **both** its sequence state and its open DETS file. Only ever a cache drop: writes are already on disk, and everything is rebuilt from storage on the next touch. `0` disables eviction. |
| `FLOODGATE_MAX_OPEN_DOCUMENTS` | `1024` | Document files open at once. At the cap, the least recently used is closed to make room, so a burst of opens cannot exhaust file descriptors before the idle sweep runs. `0` disables the cap. |
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
| `FLOODGATE_HEARTBEAT_INTERVAL_MS` | `30000` | Suggested client ping cadence; informational only |
| `FLOODGATE_HEARTBEAT_TIMEOUT_MS` | `60000` | Server-side staleness window. A socket that sends no heartbeat within it is evicted *and* closed, so its stale reference sequence number stops pinning the document's minimum. Must be at least 2 — beryl derives its check interval as half this. |

Set any limit to `0` to disable it. Defaults are deliberately generous — the conformance
suites open several concurrent sockets from one address and burst ops during sync tests —
so they bound abuse without shaping normal collaboration. The per-IP limit uses the real
socket peer address and deliberately ignores `X-Forwarded-For`, which a client can set
freely; behind a proxy every connection shares the proxy's address, so enforce per-client
limits there instead.

## Multi-tenancy

Floodgate supports any number of tenants, each with its own pair of rotating JWT
secrets — dynamic tenant management, not just the one tenant/secret pair the
environment configures. Tenants ride the same storage backend selection as
documents (`FLOODGATE_STORAGE_BACKEND`): `shelf` persists them in DETS
alongside document data, `memory` keeps them in the same ephemeral store used
by tests.

### Startup tenant compatibility

`FLOODGATE_TENANT_ID` + `FLOODGATE_JWT_SECRET` still work exactly as before:
at boot, that tenant is created if it does not already exist, with
`FLOODGATE_JWT_SECRET` as its first secret slot. If the tenant already exists
(a restart against persistent shelf storage, or one already created via the
admin API below), the boot step leaves it untouched — it will not roll back a
secret the admin API has since rotated. To rotate the startup tenant's own
secret deliberately, use the admin API rather than editing the env var and
restarting.

### Two secret slots and rotation

Every tenant has two secret slots. JWT verification tries both; token minting
always uses slot 1. Regenerating one slot leaves the other valid, so a client
can be migrated to a freshly rotated secret without an outage.

### Admin UI and authentication

Floodgate serves the same Gleam/Lustre admin SPA as Levee at `/admin`; it does
not use Phoenix, Elixir, or Mix. The container builds both Floodgate's Erlang
shipment and the SPA's JavaScript output with the Gleam compiler.

Create a GitHub OAuth App with this callback:

```
https://your-floodgate.example/auth/github/callback
```

Set `FLOODGATE_GITHUB_CLIENT_ID`, `FLOODGATE_GITHUB_CLIENT_SECRET`, and
`FLOODGATE_ADMIN_GITHUB_USERS`. The allow-list is required: an unset or empty
list denies all new OAuth users, avoiding a first-login-wins bootstrap race.
Users and opaque sessions persist in the selected storage backend. Sessions
use an HttpOnly, SameSite=Lax cookie, with Secure enabled for HTTPS. OAuth
state is expiring and single-use.

For local monorepo development, root `just build-admin` copies the shared SPA
into both Levee and Floodgate. `server/floodgate/justfile` also has a
Gleam-only `build-admin` recipe.

### Tenant management API

Tenant management accepts either a valid Floodgate admin session or
`FLOODGATE_ADMIN_KEY` (`Authorization: Bearer <key>`, compared in constant
time). The key remains available for automation and headless deployments.

```
GET    /api/tenants                        List tenants — {"tenants":[{"id","name"}]}, no secrets
POST   /api/tenants                        Create — body {"name"}, 201 {"tenant":{"id","name","secret1","secret2"}}
GET    /api/tenants/:id                    Show — {"tenant":{"id","name","secret1","secret2"}}
DELETE /api/tenants/:id                    Delete — {"message":"Tenant unregistered"}. Does not delete the
                                            tenant's documents; only the registration/secrets are forgotten.
POST   /api/tenants/:id/secrets/:slot      Regenerate slot 1 or 2 — {"secret":"<new value>"}
```

These shapes match what `server/levee_admin`'s Lustre admin UI already expects
(`server/levee_admin/src/levee_admin/api.gleam`), so the same frontend that
manages Levee's tenants can call Floodgate's API without any decoder changes.

## Presence

Floodgate speaks **server-backed presence (`presence_v1`)** on both socket
endpoints, on top of beryl's presence registry. Because the server binds presence
to the authenticated connection, a late joiner gets the whole roster at once and
a dropped socket stops being present immediately — neither needs a client
heartbeat or a TTL.

It is advertised in `connect_document_success`:

```json
{ "supportedFeatures": { "presence_v1": true } }
```

Clients that ignore the key are unaffected; a client that reads it opts in per
document by sending `joinPresence`.

```
joinPresence     {"meta": {...}}   → presence_state to that socket, then presence_diff to the topic
updatePresence   {"meta": {...}}   → presence_diff carrying the leave, then one carrying the join
leavePresence    {}                → presence_diff carrying the leave
```

Server→client frames are Phoenix-shaped, so a standard Phoenix Presence client
can consume them:

```json
// presence_state
{ "user:alice": { "metas": [{ "phx_ref": "…", "client_id": "…", "panel": "sudoku" }] } }
// presence_diff
{ "joins": { … }, "leaves": {} }
// presence_error
{ "code": "invalid_meta", "message": "…" }
```

Identity is derived server-side and cannot be claimed: `key` is the token's user
id, `client_id` is the server-assigned client id, `phx_ref` is beryl's. A command
naming `key`, `session_id`, `clientId`, `phx_ref`, or `phx_ref_prev` at the top
level is rejected with `invalid_meta`; the same names inside `meta` are stripped.
Presence commands are pushes with no reply, so every rejection
(`unauthenticated`, `invalid_meta`, `not_joined`) comes back as a `presence_error`
frame.

Presence is per document connection: one registration per connection, and a
reconnect is a new client id and therefore a new session. Cross-node replication
turns itself on when the BEAM node is distributed (a named node) and stays off on
an undistributed one, where the only reachable peers would be other runtimes in
the same OS process.

## HTTP surface

```
GET    /health                             Readiness probe — {"status":"ok"}
GET    /admin/*                            Shared Lustre admin SPA
GET    /auth/github                       Begin GitHub OAuth
GET    /auth/github/callback              Complete GitHub OAuth
GET    /api/auth/config                   UI auth capabilities
GET    /api/auth/me                       Current cookie/bearer admin
POST   /api/auth/logout                   End the admin session
POST   /api/tenants/:tenant/token-mint     Mint a document token (dev/integration)
GET    /api/tenants                        List tenants (admin session or key)
POST   /api/tenants                        Create a tenant (admin session or key)
GET    /api/tenants/:id                    Show a tenant with its secrets (admin session or key)
DELETE /api/tenants/:id                    Delete a tenant (admin session or key)
POST   /api/tenants/:id/secrets/:slot      Regenerate secret slot 1 or 2 (admin session or key)

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
