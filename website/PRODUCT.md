# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Astro.

## Users

Primary: developers evaluating whether to adopt Floodgate as the backend for
a Fluid Framework-based collaborative application, deciding whether it fits
their stack and operational constraints.

Secondary: developers who have already chosen Floodgate and are integrating
or operating it, and need reference material (config, HTTP surface, wire
protocols, deployment).

## Product Purpose

Floodgate is a Fluid Framework server implemented in Gleam, running on the
BEAM. It provides real-time collaborative document sequencing, presence, and
git-like storage over two wire protocols at once: the official Fluid
(Routerlicious-compatible) Socket.IO protocol and Phoenix Channels. It is a
drop-in replacement for the sibling Levee Elixir server for existing
`levee-client`/`levee-driver` applications, while also serving official Fluid
Framework client drivers directly.

The website's job is to (1) persuade the evaluating audience that Floodgate
is a credible, differentiated Fluid server, and (2) give adopters durable
reference documentation once they've decided to use it.

## Positioning

Floodgate's protocol logic runs on the BEAM/Gleam actor model rather than a
conventional Node.js or JVM server stack. This gives it fault-tolerant,
low-operational-overhead process isolation per document/session and
compile-time type safety in the protocol logic itself — a mechanism a
Node-based or JVM-based competitor cannot claim by simply copying features.
Dual-mode wire compatibility (Socket.IO + Phoenix Channels from one process)
and per-document DETS storage are supporting, but secondary, differentiators.

## Operating Context

Floodgate is typically run as a single self-hosted binary or container
(`docker compose up`), fronting real-time collaborative editing sessions.
Operators configure it via environment variables (tenant/JWT secrets,
storage backend, connection/rate limits, admin OAuth). It exposes a REST
surface for documents, deltas, git-like object storage, tenant management,
and a `/health` readiness probe, plus two WebSocket endpoints
(`/socket.io/`, `/socket/websocket`). Multi-tenant by design: any number of
tenants, each with two rotating JWT secret slots.

## Capabilities and Constraints

- Confirmed capabilities (source: `server/floodgate/README.md`):
  dual-mode wire protocols; server-backed presence (`presence_v1`) on both
  endpoints; git-like blob/tree/commit/ref storage; multi-tenancy with
  secret rotation; admin UI (shared Lustre SPA) with GitHub OAuth; per-tenant
  storage backends (`shelf`/DETS, `ets`, or `memory`); configurable
  connection/rate/frame limits; `/health` readiness probe.
- Built from sibling Gleam libraries (`spillway`, `beryl`, `dewdrop`,
  `signet`, `silt`, `windsock`) rather than implementing the protocol itself
  — relevant to how "how it works" content should be framed.
- Currently lives inside the `levee` monorepo at `server/floodgate/`;
  extraction into its own repository is prepared but not yet performed
  (see `docs/adr/009-floodgate-standalone-repo.md`). The site should not
  claim a standalone repo/install path that doesn't exist yet.
- Deploy target for the website itself: undecided — record when confirmed.

## Evidence on Hand

Only `server/floodgate/README.md` and the `server/floodgate/src` source are
available as source material. No logo, brand name treatment, color palette,
benchmark numbers, or testimonials exist yet. Do not fabricate performance
claims, customer names, or logos — use only what the README/code states as
fact, or clearly-labeled illustrative examples.

## Product Principles

- Lead with the BEAM/Gleam runtime mechanism as the core differentiator;
  dual-mode and storage are supporting proof points, not the headline.
- Never claim a standalone repository, install path, or ecosystem maturity
  the project doesn't yet have.
- Docs content must trace back to real HTTP/socket surface and config
  documented in the README — no invented endpoints or defaults.
- No fabricated testimonials, logos, or benchmark numbers until real ones
  are supplied.

## Accessibility & Inclusion

No product-specific requirement established yet.
