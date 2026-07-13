/**
 * Floodgate service contract — the acceptance boundary a standalone Floodgate
 * server must satisfy for an unmodified `@fluidframework/routerlicious-driver`
 * to work against it.
 *
 * This module is the executable baseline for the Floodgate migration: later
 * tasks that port runtime behaviour from Phoenix/Levee to the Gleam Floodgate
 * service are expected to keep `floodgate-routerlicious.test.ts` (and any new
 * conformance suites) green against this contract rather than growing a new,
 * parallel definition of "what Floodgate supports".
 *
 * Floodgate and Levee are independent supported services (ADR-004). This file
 * is authoritative for Floodgate's Routerlicious compatibility; Levee keeps
 * its own Phoenix Channels contract and may also exercise this suite through
 * its optional Socket.IO compatibility endpoint.
 *
 * Event names below mirror the dewdrop package's Socket.IO event definitions
 * (https://github.com/tylerbutler/dewdrop/blob/main/src/dewdrop/events.gleam)
 * verbatim — that Gleam module is the single source of truth for the Socket.IO
 * event vocabulary shared by dewdrop/beryl/spillway. If the two ever drift,
 * treat the upstream `events.gleam` as authoritative and fix this file, not the reverse.
 */

/** Socket.IO/Engine.IO event names the Routerlicious driver depends on. */
export const FLOODGATE_SOCKET_EVENTS = {
	/** Outbound: client pushes `connect_document` to begin collaboration. */
	connectDocument: "connect_document",
	/** Inbound: server acknowledges a successful `connect_document`. */
	connectDocumentSuccess: "connect_document_success",
	/** Inbound: server rejects a `connect_document` attempt. */
	connectDocumentError: "connect_document_error",
	/** Outbound: client submits ops. */
	submitOp: "submitOp",
	/** Outbound: client submits signals. */
	submitSignal: "submitSignal",
	/** Inbound: sequenced ops fanned out by the server. */
	op: "op",
	/** Inbound: signals fanned out by the server. */
	signal: "signal",
	/** Inbound: rejected ops. */
	nack: "nack",
	/** Outbound: client submits a summary/snapshot for the document. */
	submitSummary: "submitSummary",
	/** Inbound: server acknowledges an accepted summary. */
	summaryAck: "summaryAck",
	/** Inbound: server rejects a summary. */
	summaryNack: "summaryNack",
	/** Connection close event. */
	close: "close",
} as const;

export type FloodgateSocketEvent =
	(typeof FLOODGATE_SOCKET_EVENTS)[keyof typeof FLOODGATE_SOCKET_EVENTS];

/**
 * Fields the Routerlicious driver requires on a `connect_document_success`
 * payload, per `@fluidframework/protocol-definitions` `IConnected`. Kept as a
 * plain string list (rather than re-declaring the interface) so this stays a
 * thin pointer at the upstream type instead of a duplicate of it — see the
 * `satisfies` check in `floodgate-routerlicious.test.ts` for the compile-time
 * enforcement against the real `IConnected` type.
 */
export const CONNECTED_RESPONSE_REQUIRED_FIELDS = [
	"claims",
	"clientId",
	"existing",
	"maxMessageSize",
	"initialMessages",
	"initialSignals",
	"initialClients",
	"version",
	"supportedVersions",
	"serviceConfiguration",
	"mode",
] as const;

/**
 * REST endpoints required by `@fluidframework/routerlicious-driver`, keyed by
 * the driver capability that exercises them. Paths intentionally match the
 * existing Levee router surface (`server/lib/levee_web/router.ex`) so the
 * same contract can be checked against either backend during migration.
 */
export const FLOODGATE_REST_ENDPOINTS = {
	/** Mint a tenant-signed document token when integration minting is enabled. */
	tokenMint: (tenantId: string) => `/api/tenants/${tenantId}/token-mint`,
	/** Create a document. */
	createDocument: (tenantId: string) => `/documents/${tenantId}`,
	/** Session discovery (ordering service location for a document). */
	sessionDiscovery: (tenantId: string, documentId: string) =>
		`/documents/${tenantId}/session/${documentId}`,
	/** Fetch a page of sequenced deltas/ops for catch-up. */
	deltas: (tenantId: string, documentId: string) =>
		`/deltas/${tenantId}/${documentId}`,
	/** Git-like content-addressed storage: blobs. */
	gitBlob: (tenantId: string, sha: string) =>
		`/repos/${tenantId}/git/blobs/${sha}`,
	gitCreateBlob: (tenantId: string) => `/repos/${tenantId}/git/blobs`,
	/** Git-like content-addressed storage: trees. */
	gitTree: (tenantId: string, sha: string) =>
		`/repos/${tenantId}/git/trees/${sha}`,
	gitCreateTree: (tenantId: string) => `/repos/${tenantId}/git/trees`,
	/** Git-like content-addressed storage: commits. */
	gitCommit: (tenantId: string, sha: string) =>
		`/repos/${tenantId}/git/commits/${sha}`,
	gitCreateCommit: (tenantId: string) => `/repos/${tenantId}/git/commits`,
	/** Git-like refs: list, show, create, update. */
	gitRefs: (tenantId: string) => `/repos/${tenantId}/git/refs`,
	gitRef: (tenantId: string, ref: string) =>
		`/repos/${tenantId}/git/refs/${ref}`,
} as const;

/**
 * JWT scope vocabulary enforced by the Auth plug
 * (`server/lib/levee_web/plugs/auth.ex`) and expected to be enforced
 * identically by Floodgate's own JWT validation.
 */
export const FLOODGATE_AUTH_SCOPES = {
	docRead: "doc:read",
	docWrite: "doc:write",
	summaryWrite: "summary:write",
} as const;

export type FloodgateAuthScope =
	(typeof FLOODGATE_AUTH_SCOPES)[keyof typeof FLOODGATE_AUTH_SCOPES];

/**
 * Minimum scopes required per REST/operation capability. Mirrors the
 * pipelines in `server/lib/levee_web/router.ex` (`read_access`,
 * `write_access`, `summary_access`).
 */
export const FLOODGATE_REQUIRED_SCOPES = {
	deltas: [FLOODGATE_AUTH_SCOPES.docRead],
	createDocument: [
		FLOODGATE_AUTH_SCOPES.docRead,
		FLOODGATE_AUTH_SCOPES.docWrite,
	],
	gitRead: [FLOODGATE_AUTH_SCOPES.docRead],
	gitWrite: [FLOODGATE_AUTH_SCOPES.docRead, FLOODGATE_AUTH_SCOPES.summaryWrite],
} as const satisfies Record<string, readonly FloodgateAuthScope[]>;

/**
 * Storage backend acceptance boundary: Floodgate must be able to run against an
 * in-memory (ETS) backend now and a PostgreSQL-backed one later without
 * changing the wire contract above. The executable boundary is
 * `floodgate/store.Backend`; ETS and actor-memory runtime/session/Historian
 * observations are compared by `server/floodgate/test/store_backend_test.gleam`.
 * Full HTTP and Socket.IO invariance is established by running this live suite
 * against both selectable runtime backends. PostgreSQL remains future work.
 */
export const FLOODGATE_STORAGE_BACKENDS = ["ets", "postgres"] as const;
export type FloodgateStorageBackend =
	(typeof FLOODGATE_STORAGE_BACKENDS)[number];
