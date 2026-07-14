# @tylerbu/floodgate-todo-list

Collaborative todo list using [Floodgate](../../docs/) and the official
`@fluidframework/routerlicious-driver` via `@tylerbu/floodgate-client`.

Todo items are stored in a `SharedTree` (with `SharedString` for text) and
synchronized in real-time across all connected clients.

## Standalone usage

Start the Floodgate server, then run the Vite dev server:

```bash
# Combined launcher (recommended): starts both and waits for server readiness
just floodgate-todo-list
#  Floodgate server:  http://localhost:3000
#  Todo List example: http://localhost:3002

# Or separately:
just floodgate-server           # Floodgate server on :3000 only
just dev-floodgate-todo-list    # Vite Todo List on :3002 only (strictPort)
```

Open the app in multiple browser tabs. The URL hash contains the document ID —
share the full URL (hash included) to collaborate on the same todo list. When
no hash is present, a new document is created automatically.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `VITE_FLOODGATE_HTTP_URL` | `http://localhost:3000` | Floodgate server HTTP URL |
| `VITE_FLOODGATE_SOCKET_URL` | _(falls back to `VITE_FLOODGATE_HTTP_URL`)_ | Socket URL passed to Routerlicious driver. Use an **HTTP** URL (e.g. `http://localhost:3000`), not `ws://` — Routerlicious handles the WebSocket upgrade internally. |
| `VITE_FLOODGATE_TENANT_ID` | `fluid` | Tenant ID |
| `VITE_FLOODGATE_TOKEN_MINT_SECRET` | `floodgate-example-mint-secret` | **⚠️ Dev-only** token mint secret |

> **⚠️ WARNING:** The default `VITE_FLOODGATE_TOKEN_MINT_SECRET` is a
> development-only credential that matches the local Floodgate server's
> `FLOODGATE_TOKEN_MINT_SECRET`. **Never expose or reuse this value in
> production.**

## Sandbag usage

Import the `./sandbag` entry to embed the Todo List inside
[Sandbag](../sandbag):

```typescript
import floodgateTodoList from "@tylerbu/floodgate-todo-list/sandbag";

// Register with Sandbag
sandbag.register(floodgateTodoList);
```

The sandbag object exposes:
- `id`: `"floodgate-todo-list"`
- `label`: `"Floodgate Todo List"`
- `mount(element, config)`: async function — creates or loads a document and
  renders the Todo List into `element`.

`mount` accepts a `MountConfig` with the same fields as the environment
variables above (`httpUrl`, `socketUrl`, `tenantId`, `mintCredential`,
`documentId`). When `documentId` is provided, the existing document is loaded;
otherwise a new one is created.

```typescript
const { unmount, documentId } = await floodgateTodoList.mount(element, {
  httpUrl: "https://my-floodgate.example.com",
  tenantId: "my-tenant",
  mintCredential: process.env.VITE_FLOODGATE_TOKEN_MINT_SECRET,
});

// Later, to clean up:
unmount();
```

## Development

```bash
pnpm test:vitest                # Run unit tests
pnpm test:vitest:integration    # Run integration tests (requires running Floodgate server)
pnpm dev                        # Start standalone Vite dev server
pnpm build:compile              # TypeScript type-check
```

Run the integration tests with a managed server lifecycle:

```bash
just test-floodgate-todo-sync
```
