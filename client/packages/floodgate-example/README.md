# @tylerbu/floodgate-example

Collaborative DiceRoller using [Floodgate](../../docs/) and the official
`@fluidframework/routerlicious-driver` via `@tylerbu/floodgate-client`.

The dice value is stored in a `SharedMap` and synchronized in real-time
across all connected clients.

## Standalone usage

Start the Floodgate server (Task 3), then run the Vite dev server:

```bash
pnpm dev
# → http://localhost:3001
```

Open the app in multiple browser tabs. The URL hash contains the document ID —
share it to collaborate. When no hash is present, a new document is created
automatically.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `VITE_FLOODGATE_HTTP_URL` | `http://localhost:3000` | Floodgate server HTTP URL |
| `VITE_FLOODGATE_SOCKET_URL` | _(falls back to `VITE_FLOODGATE_HTTP_URL`)_ | Socket URL passed to Routerlicious driver. Use an **HTTP** URL (e.g. `http://localhost:3000`), not `ws://` — Routerlicious handles the WebSocket upgrade internally. |
| `VITE_FLOODGATE_TENANT_ID` | `fluid` | Tenant ID |
| `VITE_FLOODGATE_TOKEN_MINT_SECRET` | `floodgate-example-mint-secret` | **⚠️ Dev-only** token mint secret |

> **⚠️ WARNING:** The default `VITE_FLOODGATE_TOKEN_MINT_SECRET` is a
> development-only credential that matches the Task 3 Floodgate server's
> `FLOODGATE_TOKEN_MINT_SECRET`. **Never expose or reuse this value in
> production.**

## Sandbag usage

Import the `./sandbag` entry to embed the DiceRoller inside
[Sandbag](../sandbag):

```typescript
import floodgateDiceRoller from "@tylerbu/floodgate-example/sandbag";

// Register with Sandbag
sandbag.register(floodgateDiceRoller);
```

The sandbag object exposes:
- `id`: `"floodgate-dice-roller"`
- `label`: `"Floodgate Dice Roller"`
- `mount(element, config)`: async function — creates or loads a document and
  renders the DiceRoller into `element`.

`mount` accepts a `MountConfig` with the same fields as the environment
variables above (`httpUrl`, `socketUrl`, `tenantId`, `mintCredential`,
`documentId`). When `documentId` is provided, the existing document is loaded;
otherwise a new one is created.

```typescript
const { unmount, documentId } = await floodgateDiceRoller.mount(element, {
  httpUrl: "https://my-floodgate.example.com",
  tenantId: "my-tenant",
  mintCredential: process.env.VITE_FLOODGATE_TOKEN_MINT_SECRET,
});

// Later, to clean up:
unmount();
```

## Development

```bash
pnpm test:vitest   # Run unit tests
pnpm dev           # Start standalone Vite dev server
pnpm build:compile # TypeScript type-check
```
