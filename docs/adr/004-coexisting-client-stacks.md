# ADR-004: Levee and Floodgate coexist with separate client stacks

- **Status:** Accepted
- **Date:** 2026-07-12
- **Supersedes:** The replacement/deprecation decisions in ADR-002 and the
  Phoenix-retirement conditions in ADR-003

## Context

ADR-002 originally treated Floodgate as the eventual replacement for Levee:
the official Routerlicious driver would become the only primary path,
`levee-client` would be re-pointed at it, and the Phoenix-specific
`levee-driver` would be deprecated. ADR-003 consequently defined readiness in
terms of retiring Phoenix-owned runtime surfaces.

Levee and Floodgate are meaningfully different Fluid service implementations:

- Levee is an Elixir/Phoenix server using a custom Fluid driver over Phoenix
  Channels.
- Floodgate is a Gleam server implementing the Routerlicious REST and
  Socket.IO contracts for the official Routerlicious driver.

Maintaining both implementations provides useful architectural diversity and
allows each stack to use its native transport and runtime model.

## Decision

1. **Levee and Floodgate are independent, supported server stacks.** Floodgate
   reaching production readiness does not trigger removal or deprecation of
   Levee, Phoenix Channels, or Levee's administration surfaces.

2. **Each stack has its own client packages.**
   - `@tylerbu/levee-driver` and `@tylerbu/levee-client` remain the supported
     Phoenix Channels path for Levee.
   - `@tylerbu/floodgate-client` is the high-level Floodgate package and uses
     the official `@fluidframework/routerlicious-driver`.

3. **`levee-client` will not be re-pointed to Floodgate.** The two high-level
   clients may intentionally share familiar create/load/container conventions,
   but neither package must hide the capabilities or constraints of its server.

4. **Floodgate readiness is a release gate, not a Levee cutover gate.** The
   Routerlicious conformance suite remains Floodgate's acceptance boundary.
   Phoenix proxy coverage may remain useful during development, but Floodgate
   release readiness does not require retiring Phoenix-owned code.

5. **Protocol and domain libraries should still be shared where appropriate.**
   Spillway, Dewdrop, Windsock, storage abstractions, schemas, and conformance
   fixtures can be reused without coupling the two server deployments or client
   packages.

## Consequences

- Existing Levee applications have no forced migration or deprecation clock.
- Floodgate gets a clean client API without Phoenix transport dependencies.
- Features can be implemented independently when the server stacks differ,
  while shared Fluid protocol behavior remains testable through common
  contracts.
- Documentation and readiness tooling must use "Floodgate release readiness"
  rather than "runtime cutover" or "Phoenix retirement."
