# @tylerbu/floodgate-client

Client integration for the standalone Floodgate Gleam service using the
official `@fluidframework/routerlicious-driver`.

## Status

This package is release-ready and participates in the client Changie/npm
release pipeline. Floodgate passes the required Routerlicious conformance suite
against both supported storage backends. The package remains independent and
does not depend on `@tylerbu/levee-driver`.

Levee and Floodgate are separate, supported server stacks:

- `@tylerbu/levee-client` uses the custom Phoenix Channels Levee driver.
- `@tylerbu/floodgate-client` uses the official Routerlicious driver.

## Installation

```bash
pnpm add @tylerbu/floodgate-client
```

## High-level API

```typescript
import { FloodgateClient } from "@tylerbu/floodgate-client";
import { SharedMap } from "@fluidframework/map";

const client = new FloodgateClient({
  connection: {
    httpUrl: "http://localhost:3000",
    tenantId: "fluid",
    tokenProvider,
    user: { id: "user-1", name: "User One" },
  },
});

const schema = { initialObjects: { map: SharedMap } };
const { container } = await client.createContainer(schema, "2");
const documentId = await container.attach();

const { container: loaded } = await client.getContainer(
  documentId,
  schema,
  "2",
);
```

## Token provider

Use `RemoteFloodgateTokenProvider` to authenticate against the Floodgate
`POST /api/tenants/:tenant/token-mint` endpoint with a bearer credential:

```typescript
import {
  FloodgateClient,
  RemoteFloodgateTokenProvider,
} from "@tylerbu/floodgate-client";

const tokenProvider = new RemoteFloodgateTokenProvider(
  "http://localhost:3000/api/tenants/fluid/token-mint",
  process.env.FLOODGATE_TOKEN_MINT_SECRET,
);

// Resolve user identity before constructing the client
const user = await tokenProvider.resolveUser("fluid");

const client = new FloodgateClient({
  connection: {
    httpUrl: "http://localhost:3000",
    tenantId: "fluid",
    tokenProvider,
    user,
  },
});
```

Tokens are cached until one minute before the server-reported expiry.
Pass `refresh: true` to `fetchOrdererToken` / `fetchStorageToken` to force
a new request. After the first successful fetch, `tokenProvider.resolvedUser`
holds the server-returned user identity.

## Driver adapter

```typescript
import {
  createFloodgateClientAdapter,
  type FloodgateTokenProvider,
} from "@tylerbu/floodgate-client";

const tokenProvider: FloodgateTokenProvider = {
  fetchOrdererToken: async () => ({ jwt: "..." }),
  fetchStorageToken: async () => ({ jwt: "..." }),
};

const floodgate = createFloodgateClientAdapter({
  httpUrl: "http://localhost:3000",
  tenantId: "fluid",
  tokenProvider,
});

const serviceFactory = floodgate.documentServiceFactory;
const resolvedUrl = floodgate.createResolvedUrl("document-id");
```

`FloodgateClient` parallels the core `LeveeClient` create/load API where that
improves portability, while the packages remain independent so each server can
expose stack-specific capabilities.
