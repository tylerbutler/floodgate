/**
 * Shared live-target configuration for the Floodgate/Routerlicious conformance
 * suite (`floodgate-routerlicious.test.ts`).
 *
 * The same test file is meant to run, unmodified, against two different
 * backends by pointing these env vars at whichever one is up:
 *
 *   | Target                          | FLOODGATE_HTTP_URL / FLOODGATE_SOCKET_URL       |
 *   |---------------------------------|--------------------------------------------|
 *   | Floodgate (Gleam service) direct   | `http://localhost:3000` (default; `server/floodgate/src/floodgate.gleam`'s `main()`/`serve/1` starts a Mist listener on port 3000) |
 *   | Levee proxying/mounting Floodgate  | `http://localhost:4000` (Phoenix)           |
 *
 * The standalone `floodgate/` service *does* expose its own HTTP/WS listener
 * today (Mist, started by `serve/1`/`main()` in `floodgate.gleam`) — it is not
 * gated behind Levee. Its REST surface is currently a minimal subset,
 * though: document create/discovery, deltas catch-up, and Historian
 * blob/tree/commit/ref storage are implemented.
 * Run the same test file against both targets by pointing these env vars
 * at whichever backend is up; tests that need routes standalone Floodgate
 * doesn't have yet are gated on `FLOODGATE_TARGET_LABEL` with a matching
 * `it.todo` explaining the gap (see `floodgate-routerlicious.test.ts`).
 *
 * Neither target is assumed to be running by default — `isFloodgateRunning()`
 * probes the configured URL and callers gate live tests on the result via
 * `describe.runIf`/`it.runIf`. Set `FLOODGATE_ROUTERLICIOUS_COMPAT=1` to opt in
 * to the probe at all (matches the existing `test:floodgate-routerlicious`
 * script); otherwise live tests are skipped without making a network call.
 *
 * To run against both targets:
 *   1. Levee proxy:    start Levee (`just server`, port 4000, the default
 *      env), then `FLOODGATE_ROUTERLICIOUS_COMPAT=1 pnpm test:floodgate-routerlicious`.
 *   2. Floodgate direct: start the standalone service on port 3000 with
 *      `cd server/floodgate && FLOODGATE_JWT_SECRET=floodgate-routerlicious-compat-secret
 *      FLOODGATE_TOKEN_MINT_SECRET=floodgate-routerlicious-mint-secret gleam run`,
 *      then run with
 *      `FLOODGATE_ROUTERLICIOUS_COMPAT=1 FLOODGATE_HTTP_URL=http://localhost:3000
 *      FLOODGATE_SOCKET_URL=http://localhost:3000 pnpm test:floodgate-routerlicious`
 *      (these are also the defaults, so plain `FLOODGATE_ROUTERLICIOUS_COMPAT=1
 *      pnpm test:floodgate-routerlicious` targets Floodgate directly out of the box).
 */

import type { IResolvedUrl } from "@fluidframework/driver-definitions/internal";
import { SummaryType } from "@fluidframework/driver-definitions/internal";
import type {
	IClient,
	ISummaryTree,
} from "@fluidframework/protocol-definitions";
import type {
	ITokenProvider,
	ITokenResponse,
} from "@fluidframework/routerlicious-driver";
import { RouterliciousDocumentServiceFactory } from "@fluidframework/routerlicious-driver/internal";
import { SignJWT } from "jose";
import { v4 as uuid } from "uuid";
import {
	InsecureLeveeTokenProvider,
	RemoteLeveeTokenProvider,
} from "../../src/tokenProvider.js";
import { FLOODGATE_REST_ENDPOINTS } from "./floodgate-contract.js";

export const FLOODGATE_HTTP_URL = (
	process.env["FLOODGATE_HTTP_URL"] ?? "http://localhost:3000"
).replace(/\/$/, "");
export const FLOODGATE_SOCKET_URL =
	process.env["FLOODGATE_SOCKET_URL"] ?? FLOODGATE_HTTP_URL;
export const FLOODGATE_TENANT_ID =
	process.env["FLOODGATE_TENANT_ID"] ?? "fluid";
/**
 * The standalone server requires this value explicitly at startup and verifies
 * every REST/socket JWT signature. The default here is only the integration
 * harness value; start Floodgate with the matching environment variable.
 * When pointed at Levee's proxy, override it to match Levee's tenant secret.
 */
export const FLOODGATE_JWT_SECRET =
	process.env["FLOODGATE_JWT_SECRET"] ??
	"floodgate-routerlicious-compat-secret";
export const FLOODGATE_TOKEN_MINT_SECRET =
	process.env["FLOODGATE_TOKEN_MINT_SECRET"] ??
	"floodgate-routerlicious-mint-secret";

/**
 * Opt-in switch: live probing/tests only run when this is set, regardless of
 * whether a server happens to be reachable at `FLOODGATE_HTTP_URL`. This keeps
 * default `vitest run` (no env vars) from ever attempting network calls.
 */
export const RUN_ROUTERLICIOUS_COMPAT =
	process.env["FLOODGATE_ROUTERLICIOUS_COMPAT"] === "1" ||
	process.env["FLOODGATE_ROUTERLICIOUS_COMPAT"] === "true";

/** Human-readable label for which target this run is exercising, for logs. */
export const FLOODGATE_TARGET_LABEL =
	process.env["FLOODGATE_TARGET_LABEL"] ??
	(FLOODGATE_HTTP_URL.includes(":4000") ? "levee-proxy" : "floodgate-direct");

/**
 * True when this run is pointed at Levee's proxy/mount of Floodgate rather than
 * the standalone Gleam service. Tests use this for behavior that intentionally
 * differs between the independent stacks — see the
 * target-matrix comment above — so tests exercising those routes gate on
 * this instead of assuming every route exists on every target.
 */
export const isLeveeProxyTarget = FLOODGATE_TARGET_LABEL === "levee-proxy";

export function createFloodgateResolvedUrl(documentId: string): IResolvedUrl {
	return {
		type: "fluid",
		id: documentId,
		url: `${FLOODGATE_HTTP_URL}/${FLOODGATE_TENANT_ID}/${documentId}`,
		tokens: {},
		endpoints: {
			ordererUrl: FLOODGATE_HTTP_URL,
			deltaStorageUrl: `${FLOODGATE_HTTP_URL}/documents/${FLOODGATE_TENANT_ID}/${documentId}/deltas`,
			deltaStreamUrl: FLOODGATE_SOCKET_URL,
			storageUrl: `${FLOODGATE_HTTP_URL}/repos/${FLOODGATE_TENANT_ID}`,
		},
	};
}

/**
 * Minimal `.app` + `.protocol` combined summary tree satisfying
 * `isCombinedAppAndProtocolSummary`/`getDocAttributesFromProtocolSummary`/
 * `getQuorumValuesFromProtocolSummary` (from `@fluidframework/driver-utils`,
 * used internally by `RouterliciousDocumentServiceFactory.createContainer`).
 * Used by the official create-container conformance test — this is the
 * smallest summary shape the real driver's create path will accept.
 */
export function createMinimalCombinedSummary(): ISummaryTree {
	return {
		type: SummaryType.Tree,
		tree: {
			".app": { type: SummaryType.Tree, tree: {} },
			".protocol": {
				type: SummaryType.Tree,
				tree: {
					attributes: {
						type: SummaryType.Blob,
						content: JSON.stringify({
							minimumSequenceNumber: 0,
							sequenceNumber: 0,
						}),
					},
					quorumValues: {
						type: SummaryType.Blob,
						content: JSON.stringify([]),
					},
				},
			},
		},
	};
}

/**
 * Result is intentionally not cached across calls: unlike the Levee-only
 * `helpers.ts#isServerRunning`, this suite may be re-pointed at a different
 * target between describe blocks in the future, so each caller decides when
 * to probe.
 */
export async function isFloodgateRunning(): Promise<boolean> {
	if (!RUN_ROUTERLICIOUS_COMPAT) {
		return false;
	}
	try {
		const controller = new AbortController();
		const timeout = setTimeout(() => controller.abort(), 2000);
		const response = await fetch(FLOODGATE_HTTP_URL, {
			method: "GET",
			signal: controller.signal,
		});
		clearTimeout(timeout);

		return response.status < 500;
	} catch {
		return false;
	}
}

export function createFloodgateTestClient(
	userId: string,
	mode: IClient["mode"] = "write",
): IClient {
	return {
		mode,
		details: {
			capabilities: { interactive: true },
			environment: "node:vitest",
		},
		permission: [],
		user: { id: userId },
		scopes: ["doc:read", "doc:write", "summary:write"],
	};
}

export function createFloodgateTokenProvider(
	userId = "routerlicious-compat-user",
): InsecureLeveeTokenProvider {
	return new InsecureLeveeTokenProvider(
		FLOODGATE_JWT_SECRET,
		{ id: userId, name: "Routerlicious Compat User" },
		FLOODGATE_TENANT_ID,
	);
}

export function createFloodgateServiceFactory(
	userId?: string,
): RouterliciousDocumentServiceFactory {
	return createFloodgateServiceFactoryWithTokenProvider(
		createFloodgateTokenProvider(userId),
	);
}

export function createFloodgateServiceFactoryWithTokenProvider(
	tokenProvider: ITokenProvider,
): RouterliciousDocumentServiceFactory {
	return new RouterliciousDocumentServiceFactory(tokenProvider, {
		enableDiscovery: false,
		enableLongPollingDowngrade: false,
		// Floodgate normalizes the official driver's RestLess envelope before
		// routing. This preserves JSON request bodies in Fluid 2.81, whose
		// non-RestLess fetch path otherwise sends objects as "[object Object]".
		enableRestLess: true,
	});
}

export function createStaticFloodgateTokenProvider(
	token: string,
): ITokenProvider {
	const response = async (): Promise<ITokenResponse> => ({ jwt: token });
	return {
		fetchOrdererToken: response,
		fetchStorageToken: response,
	};
}

export function createFloodgateRemoteTokenProvider(
	userId = "routerlicious-minted-user",
): RemoteLeveeTokenProvider {
	return new RemoteLeveeTokenProvider(
		`${FLOODGATE_HTTP_URL}${FLOODGATE_REST_ENDPOINTS.tokenMint(FLOODGATE_TENANT_ID)}`,
		{ id: userId, name: "Routerlicious Minted User" },
		FLOODGATE_TOKEN_MINT_SECRET,
	);
}

/**
 * Mint a JWT for direct REST calls against the configured target (bypassing
 * the driver's own token provider), mirroring `helpers.ts#generateTestToken`
 * but parameterized over the Floodgate target instead of the Levee-only one.
 */
export async function generateFloodgateToken(
	documentId = "",
	scopes: string[] = ["doc:read", "doc:write", "summary:write"],
	secretValue = FLOODGATE_JWT_SECRET,
	tenantId = FLOODGATE_TENANT_ID,
): Promise<string> {
	const now = Math.floor(Date.now() / 1000);
	const secret = new TextEncoder().encode(secretValue);

	return new SignJWT({
		documentId,
		tenantId,
		scopes,
		user: {
			id: "routerlicious-compat-user",
			name: "Routerlicious Compat User",
		},
		ver: "1.0",
		jti: uuid(),
	})
		.setProtectedHeader({ alg: "HS256" })
		.setIssuedAt(now)
		.setExpirationTime(now + 3600)
		.sign(secret);
}

/** Authenticated fetch against the configured Floodgate/Levee target. */
export async function floodgateFetch(
	path: string,
	options: {
		method?: string;
		body?: unknown;
		documentId?: string;
		scopes?: string[];
	} = {},
): Promise<Response> {
	const token = await generateFloodgateToken(
		options.documentId ?? "",
		options.scopes,
	);

	const headers: Record<string, string> = {
		Authorization: `Bearer ${token}`,
	};

	let body: string | undefined;
	if (options.body !== undefined) {
		headers["Content-Type"] = "application/json";
		body = JSON.stringify(options.body);
	}

	return fetch(`${FLOODGATE_HTTP_URL}${path}`, {
		method: options.method ?? "GET",
		headers,
		body,
	});
}

/**
 * Helper to create a blob, tree, and commit in sequence for git-storage
 * conformance tests. Returns the commit SHA.
 *
 * Each REST call status is asserted so test failures pinpoint which call failed.
 */
export async function createBlobTreeCommit(
	tenantId: string,
	contentStr: string,
	messageStr: string,
): Promise<string> {
	return (await createBlobTreeCommitGraph(tenantId, contentStr, messageStr))
		.commitSha;
}

export async function createBlobTreeCommitGraph(
	tenantId: string,
	contentStr: string,
	messageStr: string,
): Promise<{ blobSha: string; treeSha: string; commitSha: string }> {
	// Create blob from content string
	const content = Buffer.from(contentStr).toString("base64");
	const blobResponse = await floodgateFetch(`/repos/${tenantId}/git/blobs`, {
		method: "POST",
		body: { content, encoding: "base64" },
		scopes: ["doc:read", "summary:write"],
	});
	if (blobResponse.status !== 201) {
		throw new Error(
			`Expected blob creation to return 201, got ${blobResponse.status}`,
		);
	}
	const { sha: blobSha } = (await blobResponse.json()) as { sha: string };

	// Create tree from blob
	const treeResponse = await floodgateFetch(`/repos/${tenantId}/git/trees`, {
		method: "POST",
		body: {
			tree: [{ path: "file.txt", sha: blobSha, mode: "100644", type: "blob" }],
		},
		scopes: ["doc:read", "summary:write"],
	});
	if (treeResponse.status !== 201) {
		throw new Error(
			`Expected tree creation to return 201, got ${treeResponse.status}`,
		);
	}
	const { sha: treeSha } = (await treeResponse.json()) as { sha: string };

	// Create commit from tree
	const commitResponse = await floodgateFetch(
		`/repos/${tenantId}/git/commits`,
		{
			method: "POST",
			body: {
				tree: treeSha,
				parents: [],
				message: messageStr,
				author: {
					name: "Floodgate Conformance Suite",
					email: "conformance@floodgate.local",
					date: new Date().toISOString(),
				},
			},
			scopes: ["doc:read", "summary:write"],
		},
	);
	if (commitResponse.status !== 201) {
		throw new Error(
			`Expected commit creation to return 201, got ${commitResponse.status}`,
		);
	}
	const { sha: commitSha } = (await commitResponse.json()) as { sha: string };

	return { blobSha, treeSha, commitSha };
}
