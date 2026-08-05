/**
 * Floodgate conformance — Phoenix Channels endpoint (ADR-008).
 *
 * Drives the *full* levee-driver against Floodgate's `/socket/websocket`
 * endpoint, proving Floodgate is a drop-in replacement for the Elixir Levee
 * server. The companion suite `floodgate-routerlicious.test.ts` exercises the
 * same server process over Socket.IO, and the cross-mode block here proves a
 * client of each kind collaborates on one document.
 *
 * Opt-in, like the Routerlicious suite — these never run on a bare
 * `vitest run`:
 *
 *   just test-floodgate-dual-mode
 *
 * or, against an already-running server:
 *
 *   FLOODGATE_PHOENIX_COMPAT=1 pnpm vitest run test/integration/floodgate-phoenix.test.ts
 */

import type {
	IClient,
	IDocumentDeltaConnection,
} from "@fluidframework/driver-definitions/internal";
import { describe, expect, it } from "vitest";
import type { LeveeResolvedUrl } from "../../src/contracts.js";
import { LeveeDocumentServiceFactory } from "../../src/leveeDocumentServiceFactory.js";
import { InsecureLeveeTokenProvider } from "../../src/tokenProvider.js";
import { LeveeUrlResolver } from "../../src/urlResolver.js";
import { FLOODGATE_SOCKET_EVENTS } from "./floodgate-contract.js";
import {
	createFloodgateResolvedUrl,
	createFloodgateServiceFactory,
	createFloodgateTestClient,
	FLOODGATE_HTTP_URL,
	FLOODGATE_JWT_SECRET,
	FLOODGATE_TENANT_ID,
} from "./floodgate-target.js";
import { uniqueDocId } from "./helpers.js";

/**
 * Separate opt-in from the Routerlicious suite so either wire protocol can be
 * exercised alone, and neither runs by default.
 */
const RUN_PHOENIX_COMPAT =
	process.env["FLOODGATE_PHOENIX_COMPAT"] === "1" ||
	process.env["FLOODGATE_PHOENIX_COMPAT"] === "true";

/** The phoenix js client appends `/websocket` to this. */
const PHOENIX_SOCKET_URL = `${FLOODGATE_HTTP_URL.replace(/^http/, "ws")}/socket`;

const TEST_USER = {
	id: "phoenix-conformance-user",
	name: "Phoenix Conformance",
};

async function isFloodgatePhoenixRunning(): Promise<boolean> {
	if (!RUN_PHOENIX_COMPAT) {
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

function createPhoenixFactory(): LeveeDocumentServiceFactory {
	return new LeveeDocumentServiceFactory(
		new InsecureLeveeTokenProvider(FLOODGATE_JWT_SECRET, TEST_USER),
		process.env["LEVEE_DEBUG"] === "1",
	);
}

function createPhoenixUrlResolver(): LeveeUrlResolver {
	return new LeveeUrlResolver(PHOENIX_SOCKET_URL, FLOODGATE_HTTP_URL);
}

/** Connect the full levee-driver to Floodgate's Phoenix endpoint. */
async function connectPhoenix(
	documentId: string,
	mode: IClient["mode"] = "write",
): Promise<IDocumentDeltaConnection> {
	const resolved = (await createPhoenixUrlResolver().resolve({
		url: `${FLOODGATE_TENANT_ID}/${documentId}`,
	})) as LeveeResolvedUrl;
	const service = await createPhoenixFactory().createDocumentService(resolved);
	return service.connectToDeltaStream(
		createFloodgateTestClient(TEST_USER.id, mode),
	);
}

/** Resolve on the next op batch that satisfies `predicate`. */
function nextOps(
	connection: IDocumentDeltaConnection,
	predicate: (contents: unknown) => boolean,
	timeoutMs = 10_000,
): Promise<unknown> {
	return new Promise((resolve, reject) => {
		const timer = setTimeout(
			() => reject(new Error("timed out waiting for op")),
			timeoutMs,
		);
		connection.on("op", (_documentId: string, messages: unknown[]) => {
			for (const message of messages) {
				const contents = (message as { contents?: unknown }).contents;
				if (predicate(contents)) {
					clearTimeout(timer);
					resolve(contents);
					return;
				}
			}
		});
	});
}

function submitOp(
	connection: IDocumentDeltaConnection,
	contents: unknown,
): void {
	connection.submit([
		{
			clientSequenceNumber: 1,
			contents,
			referenceSequenceNumber: 0,
			type: "op",
		},
	]);
}

async function createDocument(documentId: string): Promise<void> {
	const token = await new InsecureLeveeTokenProvider(
		FLOODGATE_JWT_SECRET,
		TEST_USER,
	).fetchOrdererToken(FLOODGATE_TENANT_ID, documentId);
	await fetch(`${FLOODGATE_HTTP_URL}/documents/${FLOODGATE_TENANT_ID}`, {
		method: "POST",
		headers: {
			Authorization: `Bearer ${token.jwt}`,
			"Content-Type": "application/json",
		},
		body: JSON.stringify({ id: documentId }),
	});
}

const phoenixAvailable = await isFloodgatePhoenixRunning();

if (!phoenixAvailable && RUN_PHOENIX_COMPAT) {
	console.log(
		`\n⚠️  Floodgate not reachable at ${FLOODGATE_HTTP_URL}; Phoenix conformance tests skipped.\n`,
	);
}

describe.runIf(phoenixAvailable)(
	"Floodgate conformance — Phoenix endpoint (levee-driver)",
	() => {
		it("completes the two-phase connect and returns a connected response", async () => {
			const documentId = uniqueDocId("phoenix-connect");
			await createDocument(documentId);

			const connection = await connectPhoenix(documentId);
			try {
				expect(connection.clientId).toBeTruthy();
				expect(connection.mode).toBe("write");
				expect(Array.isArray(connection.initialMessages)).toBe(true);
				expect(Array.isArray(connection.initialClients)).toBe(true);
				// The driver injects itself when absent, so the audience always
				// contains the connecting client.
				expect(
					connection.initialClients.some(
						(entry) => entry.clientId === connection.clientId,
					),
				).toBe(true);
			} finally {
				connection.dispose();
			}
		});

		it("round-trips a submitted op back as a sequenced message", async () => {
			const documentId = uniqueDocId("phoenix-op");
			await createDocument(documentId);

			const connection = await connectPhoenix(documentId);
			try {
				const marker = `echo-${Date.now()}`;
				const received = nextOps(connection, (contents) => contents === marker);
				submitOp(connection, marker);
				await expect(received).resolves.toBe(marker);
			} finally {
				connection.dispose();
			}
		});

		it("fans an op out between two Phoenix clients", async () => {
			const documentId = uniqueDocId("phoenix-fanout");
			await createDocument(documentId);

			const writer = await connectPhoenix(documentId);
			const reader = await connectPhoenix(documentId);
			try {
				const marker = `fanout-${Date.now()}`;
				const received = nextOps(reader, (contents) => contents === marker);
				submitOp(writer, marker);
				await expect(received).resolves.toBe(marker);
			} finally {
				writer.dispose();
				reader.dispose();
			}
		});

		// `noop` and `requestOps` have no levee-driver caller, so their coverage
		// lives in floodgate's own tests (test/phoenix_channel_test.gleam) rather
		// than here, where the driver could not drive them.

		it("serves the Levee-dialect delta endpoint with a value envelope", async () => {
			const documentId = uniqueDocId("phoenix-deltas");
			await createDocument(documentId);

			const connection = await connectPhoenix(documentId);
			const marker = `delta-${Date.now()}`;
			try {
				const received = nextOps(connection, (contents) => contents === marker);
				submitOp(connection, marker);
				await received;
			} finally {
				connection.dispose();
			}

			const token = await new InsecureLeveeTokenProvider(
				FLOODGATE_JWT_SECRET,
				TEST_USER,
			).fetchOrdererToken(FLOODGATE_TENANT_ID, documentId);
			const response = await fetch(
				`${FLOODGATE_HTTP_URL}/deltas/${FLOODGATE_TENANT_ID}/${documentId}`,
				{ headers: { Authorization: `Bearer ${token.jwt}` } },
			);
			expect(response.ok).toBe(true);
			const body = (await response.json()) as { value?: unknown };
			expect(Array.isArray(body.value)).toBe(true);
		});

		it("uses the same event vocabulary as the Socket.IO endpoint", () => {
			expect(FLOODGATE_SOCKET_EVENTS.connectDocument).toBe("connect_document");
			expect(FLOODGATE_SOCKET_EVENTS.connectDocumentSuccess).toBe(
				"connect_document_success",
			);
			expect(FLOODGATE_SOCKET_EVENTS.submitOp).toBe("submitOp");
			expect(FLOODGATE_SOCKET_EVENTS.submitSignal).toBe("submitSignal");
		});
	},
);

describe.runIf(phoenixAvailable)(
	"Floodgate conformance — cross-mode collaboration",
	() => {
		it("fans an op from a Phoenix client to a Routerlicious client", async () => {
			const documentId = uniqueDocId("cross-mode");
			await createDocument(documentId);

			const phoenix = await connectPhoenix(documentId);
			const routerlicious = await (
				await createFloodgateServiceFactory().createDocumentService(
					createFloodgateResolvedUrl(documentId),
				)
			).connectToDeltaStream(createFloodgateTestClient("routerlicious-peer"));

			try {
				const marker = `cross-${Date.now()}`;
				const received = nextOps(
					routerlicious,
					(contents) => contents === marker,
				);
				submitOp(phoenix, marker);
				await expect(received).resolves.toBe(marker);
			} finally {
				phoenix.dispose();
				routerlicious.dispose();
			}
		});

		it("fans an op from a Routerlicious client to a Phoenix client", async () => {
			const documentId = uniqueDocId("cross-mode-reverse");
			await createDocument(documentId);

			const phoenix = await connectPhoenix(documentId);
			const routerlicious = await (
				await createFloodgateServiceFactory().createDocumentService(
					createFloodgateResolvedUrl(documentId),
				)
			).connectToDeltaStream(createFloodgateTestClient("routerlicious-peer"));

			try {
				const marker = `cross-reverse-${Date.now()}`;
				const received = nextOps(phoenix, (contents) => contents === marker);
				submitOp(routerlicious, marker);
				await expect(received).resolves.toBe(marker);
			} finally {
				phoenix.dispose();
				routerlicious.dispose();
			}
		});
	},
);
