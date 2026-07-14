# @tylerbu/floodgate-presence-tracker

A Floodgate adaptation of Fluid Framework's
[Presence Tracker sample](https://github.com/microsoft/FluidFramework/tree/main/examples/apps/presence-tracker).
It uses the official `@fluidframework/presence` APIs with
`@tylerbu/floodgate-client`, while keeping the existing Levee Presence app
independent.

The demo shares normalized cursors, window focus, participant status, and emoji
notifications. These values are ephemeral and are not written to the Fluid
document.

## Run

```bash
just floodgate-presence
# Floodgate server: http://localhost:3000
# Presence demo:    http://localhost:3003
```

Open the URL in another tab with the same hash to join the room.

The standalone app accepts the same development environment variables as the
other Floodgate examples:

| Variable | Default |
|---|---|
| `VITE_FLOODGATE_HTTP_URL` | `http://localhost:3000` |
| `VITE_FLOODGATE_SOCKET_URL` | Falls back to the HTTP URL |
| `VITE_FLOODGATE_TENANT_ID` | `fluid` |
| `VITE_FLOODGATE_TOKEN_MINT_SECRET` | Local development credential |

The default mint credential is development-only. Never expose or reuse it in
production.

## Sandbag

The `./sandbag` export registers the app as `floodgate-presence`:

```typescript
import floodgatePresence from "@tylerbu/floodgate-presence-tracker/sandbag";
```

## Verify

```bash
pnpm test:vitest
pnpm build:compile
pnpm build:vite
pnpm lint
pnpm check:format

# Starts Floodgate and verifies two-client Presence synchronization:
just test-floodgate-presence-sync
```
