# CLAUDE.md - @tylerbu/floodgate-client

Floodgate client package built on the official
`@fluidframework/routerlicious-driver`.

## Strategy

Per [ADR-004](../../../docs/adr/004-coexisting-client-stacks.md), Levee and
Floodgate are independent supported stacks:

- Do not depend on `@tylerbu/levee-driver`.
- Keep Routerlicious/Floodgate integration in this package.
- Share protocol-neutral types, fixtures, and conventions where useful.
- Do not imply that Floodgate readiness deprecates Levee.

## Status

The package is publishable through the client Changie/npm release pipeline.
Standalone Floodgate passes the required Routerlicious conformance suite on
both supported storage backends. The API exposes both high-level container
create/load operations and lower-level resolved-URL/document-service-factory
primitives.

## Commands

```bash
pnpm build:compile
pnpm test:vitest
pnpm format
pnpm lint
```
