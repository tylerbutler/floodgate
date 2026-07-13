/**
 * Routerlicious driver compatibility checks for Floodgate.
 *
 * These tests define the compatibility baseline: an unmodified official
 * Routerlicious driver should be able to use Floodgate's Socket.IO/dewdrop
 * realtime endpoint plus its REST document/storage surface. All networked
 * tests are opt-in (`FLOODGATE_ROUTERLICIOUS_COMPAT=1`) because neither Floodgate
 * nor Levee's proxy of it is part of the default test run.
 *
 * Live-target matrix — point the same suite at either backend by env, run
 * twice (see `floodgate-target.ts` for the full var list and run instructions):
 *
 *   Floodgate direct:  FLOODGATE_HTTP_URL=http://localhost:3000 FLOODGATE_SOCKET_URL=http://localhost:3000 (defaults)
 *   Levee proxy:    FLOODGATE_HTTP_URL=http://localhost:4000 FLOODGATE_SOCKET_URL=http://localhost:4000
 *
 * Both targets expose their own HTTP/WS listener today: Levee via
 * `server/lib/levee_web/socket_io_websock.ex` plus the REST controllers in
 * `server/lib/levee_web/controllers/`, and the standalone `floodgate/` Gleam
 * service via Mist and `floodgate/socketio_transport.gleam`, started by
 * `serve/1`/`main()` in `server/floodgate/src/floodgate.gleam`.
 * Standalone Floodgate's REST surface implements document create/discovery,
 * delta catch-up, and Historian blob/tree/commit/ref storage (see
 * `server/floodgate/src/floodgate.gleam`'s `rest/2` route match). Tests that
 * need target-specific behavior gate on `isLeveeProxyTarget` and pair with an
 * `it.todo` explaining the standalone-only gap, rather than skipping
 * silently or assuming the route is universally unimplemented.
 */

import type { IDocumentDeltaConnection } from "@fluidframework/driver-definitions/internal";
import type { ContainerSchema } from "@fluidframework/fluid-static";
import { SharedMap } from "@fluidframework/map";
import type {
	IConnected,
	IDocumentMessage,
	INack,
	ISequencedDocumentMessage,
	ISignalMessage,
} from "@fluidframework/protocol-definitions";
import { describe, expect, it } from "vitest";
import { FloodgateClient } from "../../../floodgate-client/src/index.js";
import {
	CONNECTED_RESPONSE_REQUIRED_FIELDS,
	FLOODGATE_AUTH_SCOPES,
	FLOODGATE_REQUIRED_SCOPES,
	FLOODGATE_REST_ENDPOINTS,
	FLOODGATE_SOCKET_EVENTS,
} from "./floodgate-contract.js";
import {
	createBlobTreeCommit,
	createBlobTreeCommitGraph,
	createFloodgateRemoteTokenProvider,
	createFloodgateResolvedUrl,
	createFloodgateServiceFactory,
	createFloodgateServiceFactoryWithTokenProvider,
	createFloodgateTestClient,
	createFloodgateTokenProvider,
	createMinimalCombinedSummary,
	createStaticFloodgateTokenProvider,
	FLOODGATE_HTTP_URL,
	FLOODGATE_SOCKET_URL,
	FLOODGATE_TARGET_LABEL,
	FLOODGATE_TENANT_ID,
	floodgateFetch,
	generateFloodgateToken,
	isFloodgateRunning,
	isLeveeProxyTarget,
} from "./floodgate-target.js";
import { uniqueDocId } from "./helpers.js";

const floodgateAvailable = await isFloodgateRunning();

const testClient = createFloodgateTestClient("routerlicious-compat-user");

function message(
	clientSequenceNumber: number,
	referenceSequenceNumber: number,
	contents: string,
): IDocumentMessage {
	return {
		clientSequenceNumber,
		referenceSequenceNumber,
		type: "op",
		contents,
	};
}

function waitForOp(
	connection: IDocumentDeltaConnection,
	expectedContents: unknown,
): Promise<[string, ISequencedDocumentMessage[]]> {
	return new Promise((resolve) => {
		connection.on("op", (documentId, messages) => {
			if (
				messages.some(
					(candidate) =>
						candidate.clientId !== null &&
						Object.is(candidate.contents, expectedContents),
				)
			) {
				resolve([documentId, messages]);
			}
		});
	});
}

function waitForMessageType(
	connection: IDocumentDeltaConnection,
	expectedType: string,
): Promise<[string, ISequencedDocumentMessage[]]> {
	return new Promise((resolve) => {
		connection.on("op", (documentId, messages) => {
			if (messages.some((candidate) => candidate.type === expectedType)) {
				resolve([documentId, messages]);
			}
		});
	});
}

function waitForNack(
	connection: IDocumentDeltaConnection,
): Promise<[string, INack[]]> {
	return new Promise((resolve) => {
		connection.on("nack", (documentId, nacks) => {
			resolve([documentId, nacks]);
		});
	});
}

function waitForSignal(
	connection: IDocumentDeltaConnection,
	expectedContent: string,
): Promise<ISignalMessage> {
	return new Promise((resolve) => {
		connection.on("signal", (signal) => {
			const signals = Array.isArray(signal) ? signal : [signal];
			const matchingSignal = signals.find(
				(candidate) => candidate.content === expectedContent,
			);
			if (matchingSignal !== undefined) {
				resolve(matchingSignal);
			}
		});
	});
}

const sharedMapSchema = {
	initialObjects: {
		map: SharedMap,
	},
} satisfies ContainerSchema;

function createLoaderClient(userId: string): FloodgateClient {
	return new FloodgateClient({
		connection: {
			httpUrl: FLOODGATE_HTTP_URL,
			socketUrl: FLOODGATE_SOCKET_URL,
			tenantId: FLOODGATE_TENANT_ID,
			tokenProvider: createFloodgateTokenProvider(userId),
			user: { id: userId, name: userId },
		},
	});
}

async function waitForMapValue(
	map: SharedMap,
	key: string,
	expectedValue: unknown,
): Promise<void> {
	if (Object.is(map.get(key), expectedValue)) {
		return;
	}

	await new Promise<void>((resolve, reject) => {
		const timeout = setTimeout(() => {
			map.off("valueChanged", onValueChanged);
			reject(
				new Error(
					`Timed out waiting for SharedMap key "${key}" to equal ${JSON.stringify(expectedValue)}`,
				),
			);
		}, 10_000);
		const onValueChanged = (): void => {
			if (Object.is(map.get(key), expectedValue)) {
				clearTimeout(timeout);
				map.off("valueChanged", onValueChanged);
				resolve();
			}
		};
		map.on("valueChanged", onValueChanged);
	});
}

describe("Floodgate Routerlicious compatibility contract", () => {
	it("builds a Routerlicious resolved URL targeting Floodgate endpoints", () => {
		const documentId = "compat-doc";
		const resolvedUrl = createFloodgateResolvedUrl(documentId);

		expect(resolvedUrl.type).toBe("fluid");
		expect(resolvedUrl.id).toBe(documentId);
		expect(resolvedUrl.endpoints["ordererUrl"]).toBe(FLOODGATE_HTTP_URL);
		expect(resolvedUrl.endpoints["deltaStreamUrl"]).toBe(FLOODGATE_SOCKET_URL);
		expect(resolvedUrl.endpoints["deltaStorageUrl"]).toBe(
			`${FLOODGATE_HTTP_URL}/documents/${FLOODGATE_TENANT_ID}/${documentId}/deltas`,
		);
		expect(resolvedUrl.endpoints["storageUrl"]).toBe(
			`${FLOODGATE_HTTP_URL}/repos/${FLOODGATE_TENANT_ID}`,
		);
	});

	it("reports which live target (Floodgate direct or Levee proxy) this run is configured for", () => {
		expect(["floodgate-direct", "levee-proxy"]).toContain(
			FLOODGATE_TARGET_LABEL,
		);
	});

	it.runIf(floodgateAvailable)(
		"connects an unmodified Routerlicious delta stream to Floodgate",
		{ timeout: 30_000 },
		async () => {
			const documentId = uniqueDocId("floodgate-routerlicious");
			const factory = createFloodgateServiceFactory();
			const resolvedUrl = createFloodgateResolvedUrl(documentId);
			const service = await factory.createDocumentService(resolvedUrl);

			const connection = await service.connectToDeltaStream(testClient);

			expect(connection.clientId).toBeDefined();
			expect(connection.mode).toBe("write");
			expect(connection.claims.documentId).toBe(documentId);
			expect(connection.claims.scopes).toContain(FLOODGATE_AUTH_SCOPES.docRead);
			expect(connection.claims.scopes).toContain(
				FLOODGATE_AUTH_SCOPES.docWrite,
			);
			expect(connection.existing).toBe(false);

			connection.dispose();
		},
	);

	it.todo(
		"[levee-proxy target] official createContainer() — currently " +
			"blocked by an auth scheme mismatch, not just a missing route: " +
			"`RouterliciousDocumentServiceFactory.createContainer`'s orderer " +
			"REST calls always send `Authorization: Basic <jwt>` " +
			"(`RouterliciousOrdererRestWrapper.load` in " +
			"`@fluidframework/routerlicious-driver`'s restWrapper.ts hard-codes " +
			"the `Basic` scheme), but Levee's auth plug only accepts `Bearer " +
			"<token>` (`server/lib/levee_web/plugs/auth.ex#extract_token`), so " +
			"every such call 401s with 'Invalid Authorization header format'. " +
			"Confirmed live against the running Levee proxy on port 4000 (with " +
			"`enableRestLess: false` set to rule out the separate RestLess-body " +
			"encoding issue also discovered while building this test — see " +
			"`createFloodgateServiceFactory` in `floodgate-target.ts`). Fixing this " +
			"needs a runtime change (either Levee accepting `Basic` for this " +
			"route, or a documented reason official Routerlicious clients " +
			"can't create documents against Levee), which is out of scope for " +
			"a conformance-test-only change. `createMinimalCombinedSummary()` " +
			"in `floodgate-target.ts` is ready to drive this once unblocked.",
	);

	it.runIf(floodgateAvailable && !isLeveeProxyTarget)(
		"creates a document through the official Routerlicious createContainer() path",
		async () => {
			const requestedDocumentId = uniqueDocId("floodgate-create-placeholder");
			const factory = createFloodgateServiceFactory();
			const service = await factory.createContainer(
				createMinimalCombinedSummary(),
				createFloodgateResolvedUrl(requestedDocumentId),
			);

			expect(service.resolvedUrl.id).toBeDefined();
			expect(service.resolvedUrl.id).not.toBe(requestedDocumentId);

			const connection = await service.connectToDeltaStream(testClient);
			try {
				expect(connection.existing).toBe(true);
				expect(connection.claims.documentId).toBe(service.resolvedUrl.id);
			} finally {
				connection.dispose();
			}
		},
	);
});

describe("Floodgate contract — connect handshake shape", () => {
	it("connect_document_success payload satisfies IConnected's required fields", () => {
		// Minimal-but-real IConnected literal. The `satisfies` check below is a
		// compile-time enforcement that Floodgate's join-response builder
		// (`floodgate/document_channel.gleam`'s `JoinOk` reply) must eventually
		// produce every field the official driver requires — this fails to
		// typecheck if `@fluidframework/protocol-definitions` adds a new
		// required field that Floodgate hasn't accounted for.
		const minimalConnected = {
			claims: {
				documentId: "doc",
				tenantId: "fluid",
				scopes: [FLOODGATE_AUTH_SCOPES.docRead, FLOODGATE_AUTH_SCOPES.docWrite],
				user: { id: "u" },
				ver: "1.0",
			},
			clientId: "client-1",
			existing: true,
			maxMessageSize: 16 * 1024,
			initialMessages: [],
			initialSignals: [],
			initialClients: [],
			version: "0.1.0",
			supportedVersions: ["0.1.0"],
			serviceConfiguration: {
				maxMessageSize: 16 * 1024,
				blockSize: 1024,
			},
			mode: "write",
		} satisfies IConnected;

		for (const field of CONNECTED_RESPONSE_REQUIRED_FIELDS) {
			expect(minimalConnected).toHaveProperty(field);
		}
	});
});

describe("Floodgate contract — socket event vocabulary", () => {
	// NOTE: this only pins the *event name strings* Floodgate's dewdrop/events.gleam
	// exposes. It is not behavior coverage — actual signal fan-out semantics
	// (ordering, no-sequencing guarantee, delivery to all connected clients)
	// are exercised (as a todo, pending live harness support) below in
	// "Floodgate contract — operation submission, sequencing & fan-out".
	it("uses the dewdrop/events.gleam event names for op/signal/summary flows", () => {
		expect(FLOODGATE_SOCKET_EVENTS.connectDocument).toBe("connect_document");
		expect(FLOODGATE_SOCKET_EVENTS.connectDocumentSuccess).toBe(
			"connect_document_success",
		);
		expect(FLOODGATE_SOCKET_EVENTS.submitOp).toBe("submitOp");
		expect(FLOODGATE_SOCKET_EVENTS.op).toBe("op");
		expect(FLOODGATE_SOCKET_EVENTS.submitSignal).toBe("submitSignal");
		expect(FLOODGATE_SOCKET_EVENTS.signal).toBe("signal");
		expect(FLOODGATE_SOCKET_EVENTS.nack).toBe("nack");
		expect(FLOODGATE_SOCKET_EVENTS.submitSummary).toBe("submitSummary");
		expect(FLOODGATE_SOCKET_EVENTS.summaryAck).toBe("summaryAck");
	});
});

describe.runIf(floodgateAvailable)(
	"Floodgate contract — operation submission, sequencing & fan-out",
	{ timeout: 30_000 },
	() => {
		it("assigns monotonically increasing sequenceNumber across clients on a document", async () => {
			const documentId = uniqueDocId("floodgate-sequencing");
			const service =
				await createFloodgateServiceFactory().createDocumentService(
					createFloodgateResolvedUrl(documentId),
				);
			const first = await service.connectToDeltaStream(
				createFloodgateTestClient("sequencing-client-1"),
			);
			const second = await service.connectToDeltaStream(
				createFloodgateTestClient("sequencing-client-2"),
			);

			try {
				const firstOp = waitForOp(first, "first");
				first.submit([message(1, 0, "first")]);
				const [, firstMessages] = await firstOp;

				const secondOp = waitForOp(second, "second");
				second.submit([
					message(1, firstMessages[0]?.sequenceNumber ?? 0, "second"),
				]);
				const [, secondMessages] = await secondOp;

				expect(secondMessages[0]?.sequenceNumber).toBe(
					(firstMessages[0]?.sequenceNumber ?? 0) + 1,
				);
			} finally {
				first.dispose();
				second.dispose();
			}
		});

		it("fans out an accepted op to every connected client, including the submitter", async () => {
			const documentId = uniqueDocId("floodgate-op-fanout");
			const service =
				await createFloodgateServiceFactory().createDocumentService(
					createFloodgateResolvedUrl(documentId),
				);
			const first = await service.connectToDeltaStream(
				createFloodgateTestClient("fanout-client-1"),
			);
			const second = await service.connectToDeltaStream(
				createFloodgateTestClient("fanout-client-2"),
			);

			try {
				const firstOp = waitForOp(first, "fanout");
				const secondOp = waitForOp(second, "fanout");
				first.submit([message(1, 0, "fanout")]);

				const [
					[firstDocumentId, firstMessages],
					[secondDocumentId, secondMessages],
				] = await Promise.all([firstOp, secondOp]);

				expect(firstDocumentId).toBe(documentId);
				expect(secondDocumentId).toBe(documentId);
				expect(firstMessages[0]?.contents).toBe("fanout");
				expect(secondMessages).toEqual(firstMessages);
			} finally {
				first.dispose();
				second.dispose();
			}
		});

		it("nacks an op submitted with a future reference sequence number", async () => {
			const documentId = uniqueDocId("floodgate-op-nack");
			const service =
				await createFloodgateServiceFactory().createDocumentService(
					createFloodgateResolvedUrl(documentId),
				);
			const connection = await service.connectToDeltaStream(testClient);

			try {
				const nack = waitForNack(connection);
				connection.submit([message(1, 100, "invalid")]);
				const [nackDocumentId, nacks] = await nack;

				expect(nackDocumentId).toBe(documentId);
				expect(nacks[0]?.content.code).toBe(400);
				expect(nacks[0]?.operation?.contents).toBe("invalid");
			} finally {
				connection.dispose();
			}
		});

		it("nacks operations submitted by a read-mode client", async () => {
			const documentId = uniqueDocId("floodgate-read-mode-nack");
			const service =
				await createFloodgateServiceFactory().createDocumentService(
					createFloodgateResolvedUrl(documentId),
				);
			const connection = await service.connectToDeltaStream(
				createFloodgateTestClient("read-mode-client", "read"),
			);

			try {
				const initialSignals = Reflect.get(connection, "details")
					.initialSignals as ISignalMessage[];
				expect(initialSignals).toHaveLength(1);
				const ownJoin = JSON.parse(initialSignals[0]?.content as string);
				expect(ownJoin).toMatchObject({
					type: "join",
					content: {
						clientId: connection.clientId,
						client: {
							mode: "read",
							details: { capabilities: { interactive: true } },
							user: { id: expect.any(String) },
						},
					},
				});

				const nack = waitForNack(connection);
				connection.submit([message(1, 0, "not-allowed")]);
				const [, nacks] = await nack;

				expect(nacks[0]?.content.code).toBe(403);
				expect(nacks[0]?.operation).toBeNull();
			} finally {
				connection.dispose();
			}
		});

		it("preserves optional op metadata and accepts missing contents", async () => {
			const documentId = uniqueDocId("floodgate-op-metadata");
			const service =
				await createFloodgateServiceFactory().createDocumentService(
					createFloodgateResolvedUrl(documentId),
				);
			const connection = await service.connectToDeltaStream(testClient);

			try {
				const op = waitForOp(connection, null);
				connection.submit([
					{
						clientSequenceNumber: 1,
						referenceSequenceNumber: 0,
						type: "noop",
						contents: undefined,
						metadata: { batch: true },
						compression: "test-compression",
					},
				]);
				const [, messages] = await op;

				expect(messages[0]?.contents).toBeNull();
				expect(messages[0]?.metadata).toEqual({ batch: true });
				expect(messages[0]?.compression).toBe("test-compression");
			} finally {
				connection.dispose();
			}
		});

		it("fans out submitSignal payloads to every connected client without sequencing", async () => {
			const documentId = uniqueDocId("floodgate-signal-fanout");
			const service =
				await createFloodgateServiceFactory().createDocumentService(
					createFloodgateResolvedUrl(documentId),
				);
			const first = await service.connectToDeltaStream(
				createFloodgateTestClient("signal-client-1"),
			);
			const second = await service.connectToDeltaStream(
				createFloodgateTestClient("signal-client-2"),
			);

			try {
				const firstSignal = waitForSignal(first, "signal-content");
				const secondSignal = waitForSignal(second, "signal-content");
				first.submitSignal("signal-content");

				const [receivedByFirst, receivedBySecond] = await Promise.all([
					firstSignal,
					secondSignal,
				]);
				expect(receivedByFirst.content).toBe("signal-content");
				expect(receivedBySecond).toEqual(receivedByFirst);
				expect(receivedByFirst.clientId).toBe(first.clientId);
			} finally {
				first.dispose();
				second.dispose();
			}
		});
	},
);

describe.runIf(floodgateAvailable && !isLeveeProxyTarget)(
	"Floodgate contract — SharedMap/DDS sync via Loader/fluid-static",
	{ timeout: 45_000 },
	() => {
		it("two Loader-backed containers converge on a SharedMap value set by one client", async () => {
			const first = await createLoaderClient(
				"loader-sync-first",
			).createContainer(sharedMapSchema, "2");
			const documentId = await first.container.attach();
			const second = await createLoaderClient(
				"loader-sync-second",
			).getContainer(documentId, sharedMapSchema, "2");

			try {
				first.container.initialObjects.map.set("shared", "from-first");
				await waitForMapValue(
					second.container.initialObjects.map,
					"shared",
					"from-first",
				);
				expect(second.container.initialObjects.map.get("shared")).toBe(
					"from-first",
				);
			} finally {
				first.container.dispose();
				second.container.dispose();
			}
		});

		it("a client joining after a SharedMap op reconstructs the same state", async () => {
			const first = await createLoaderClient(
				"loader-late-first",
			).createContainer(sharedMapSchema, "2");
			const documentId = await first.container.attach();
			const observer = await createLoaderClient(
				"loader-late-observer",
			).getContainer(documentId, sharedMapSchema, "2");

			try {
				first.container.initialObjects.map.set("before-join", "persisted");
				await waitForMapValue(
					observer.container.initialObjects.map,
					"before-join",
					"persisted",
				);
				observer.container.dispose();

				const late = await createLoaderClient(
					"loader-late-reader",
				).getContainer(documentId, sharedMapSchema, "2");
				try {
					await waitForMapValue(
						late.container.initialObjects.map,
						"before-join",
						"persisted",
					);
					expect(late.container.initialObjects.map.get("before-join")).toBe(
						"persisted",
					);
				} finally {
					late.container.dispose();
				}
			} finally {
				first.container.dispose();
				observer.container.dispose();
			}
		});
	},
);

describe.runIf(floodgateAvailable && !isLeveeProxyTarget)(
	"Floodgate contract — summaries",
	{ timeout: 30_000 },
	() => {
		it("persists a summary tree as a commit and acknowledges the commit handle", async () => {
			const documentId = uniqueDocId("floodgate-summary");
			const graph = await createBlobTreeCommitGraph(
				FLOODGATE_TENANT_ID,
				"summary content",
				"Summary fixture",
			);
			const service =
				await createFloodgateServiceFactory().createDocumentService(
					createFloodgateResolvedUrl(documentId),
				);
			const connection = await service.connectToDeltaStream(testClient);
			try {
				const summaryAck = waitForMessageType(connection, "summaryAck");
				connection.submit([
					{
						clientSequenceNumber: 1,
						referenceSequenceNumber: 0,
						type: "summarize",
						contents: {
							handle: graph.treeSha,
							message: "Floodgate summary",
							parents: [graph.commitSha],
							head: graph.commitSha,
						},
					},
				]);
				const [, messages] = await summaryAck;
				const proposal = messages.find(
					(candidate) => candidate.type === "summarize",
				);
				const ack = messages.find(
					(candidate) => candidate.type === "summaryAck",
				);
				const ackHandle = (ack?.contents as { handle?: string } | undefined)
					?.handle;

				expect(proposal?.sequenceNumber).toBe(2);
				expect(ack).toMatchObject({
					sequenceNumber: 3,
					referenceSequenceNumber: 2,
					contents: {
						handle: expect.any(String),
						summaryProposal: { summarySequenceNumber: 2 },
					},
				});
				expect(ackHandle).not.toBe(graph.treeSha);

				const commitResponse = await floodgateFetch(
					FLOODGATE_REST_ENDPOINTS.gitCommit(
						FLOODGATE_TENANT_ID,
						ackHandle ?? "",
					),
				);
				expect(commitResponse.status).toBe(200);
				const commit = await commitResponse.json();
				expect(commit.tree.sha).toBe(graph.treeSha);
				expect(commit.parents).toEqual([
					expect.objectContaining({ sha: graph.commitSha }),
				]);
			} finally {
				connection.dispose();
			}
		});

		it("sequences summaryNack when summarize contents are invalid", async () => {
			const documentId = uniqueDocId("floodgate-summary-nack");
			const service =
				await createFloodgateServiceFactory().createDocumentService(
					createFloodgateResolvedUrl(documentId),
				);
			const connection = await service.connectToDeltaStream(testClient);

			try {
				const summaryNack = waitForMessageType(connection, "summaryNack");
				connection.submit([
					{
						clientSequenceNumber: 1,
						referenceSequenceNumber: 0,
						type: "summarize",
						contents: { handle: "incomplete-summary" },
					},
				]);
				const [, messages] = await summaryNack;
				const nack = messages.find(
					(candidate) => candidate.type === "summaryNack",
				);

				expect(nack).toMatchObject({
					sequenceNumber: 3,
					referenceSequenceNumber: 2,
					contents: {
						summaryProposal: { summarySequenceNumber: 2 },
						code: 400,
					},
				});
			} finally {
				connection.dispose();
			}
		});

		it("returns persisted summary context to a later connection", async () => {
			const documentId = uniqueDocId("floodgate-summary-context");
			const graph = await createBlobTreeCommitGraph(
				FLOODGATE_TENANT_ID,
				"summary context",
				"Summary context fixture",
			);
			const service =
				await createFloodgateServiceFactory().createDocumentService(
					createFloodgateResolvedUrl(documentId),
				);
			const first = await service.connectToDeltaStream(testClient);
			const summaryAck = waitForMessageType(first, "summaryAck");
			first.submit([
				{
					clientSequenceNumber: 1,
					referenceSequenceNumber: 0,
					type: "summarize",
					contents: {
						handle: graph.treeSha,
						message: "Floodgate summary context",
						parents: [graph.commitSha],
						head: graph.commitSha,
					},
				},
			]);
			const [, messages] = await summaryAck;
			const ack = messages.find((candidate) => candidate.type === "summaryAck");
			const handle = (ack?.contents as { handle?: string } | undefined)?.handle;
			expect(handle).toEqual(expect.any(String));
			first.dispose();

			const later = await service.connectToDeltaStream(testClient);
			try {
				expect(Reflect.get(later, "details")).toMatchObject({
					summaryHandle: handle,
					summarySequenceNumber: 2,
				});
			} finally {
				later.dispose();
			}
		});
	},
);

describe.runIf(floodgateAvailable)(
	"Floodgate contract — reconnect & audience/presence roster",
	{ timeout: 30_000 },
	() => {
		it("a second client's initialClients includes a still-connected first client (presence roster)", async () => {
			const documentId = uniqueDocId("floodgate-audience");
			const factory = createFloodgateServiceFactory();
			const resolvedUrl = createFloodgateResolvedUrl(documentId);
			const service = await factory.createDocumentService(resolvedUrl);

			const first = await service.connectToDeltaStream(
				createFloodgateTestClient("audience-client-1"),
			);
			try {
				const second = await service.connectToDeltaStream(
					createFloodgateTestClient("audience-client-2"),
				);
				try {
					const rosterClientIds = second.initialClients.map(
						(entry) => entry.clientId,
					);
					expect(rosterClientIds).toContain(first.clientId);
					const firstMember = second.initialClients.find(
						(entry) => entry.clientId === first.clientId,
					);
					expect(firstMember?.client).toMatchObject({
						mode: "write",
						details: { capabilities: { interactive: true } },
						user: { id: expect.any(String) },
					});
				} finally {
					second.dispose();
				}
			} finally {
				first.dispose();
			}
		});

		it("a client that disconnects and reconnects establishes a new delta-stream connection to the same document", async () => {
			const documentId = uniqueDocId("floodgate-reconnect");
			const factory = createFloodgateServiceFactory();
			const resolvedUrl = createFloodgateResolvedUrl(documentId);
			const service = await factory.createDocumentService(resolvedUrl);

			const initial = await service.connectToDeltaStream(testClient);
			const firstClientId = initial.clientId;
			initial.dispose();

			const reconnected = await service.connectToDeltaStream(testClient);
			try {
				expect(reconnected.clientId).toBeDefined();
				expect(reconnected.clientId).not.toBe(firstClientId);
				expect(reconnected.existing).toBe(true);
			} finally {
				reconnected.dispose();
			}
		});

		it("a client can request missed ops through the official delta-storage service", async () => {
			const documentId = uniqueDocId("floodgate-delta-storage");
			const service =
				await createFloodgateServiceFactory().createDocumentService(
					createFloodgateResolvedUrl(documentId),
				);
			const connection = await service.connectToDeltaStream(testClient);

			try {
				const op = waitForOp(connection, "stored-op");
				connection.submit([message(1, 0, "stored-op")]);
				await op;
			} finally {
				connection.dispose();
			}

			const deltaStorage = await service.connectToDeltaStorage();
			const stream = deltaStorage.fetchMessages(2, 3);
			const result = await stream.read();

			expect(result.done).toBe(false);
			if (!result.done) {
				expect(result.value).toMatchObject([
					{ sequenceNumber: 2, contents: "stored-op", type: "op" },
				]);
			}
		});
		it("reconnects with reset client sequencing and catches up without duplicate or missing ops", async () => {
			const documentId = uniqueDocId("floodgate-stale-reconnect");
			const service =
				await createFloodgateServiceFactory().createDocumentService(
					createFloodgateResolvedUrl(documentId),
				);
			const initial = await service.connectToDeltaStream(
				createFloodgateTestClient("stale-reconnect-client"),
			);
			const peer = await service.connectToDeltaStream(
				createFloodgateTestClient("stale-reconnect-peer"),
			);

			try {
				const beforeDisconnect = waitForOp(initial, "before-disconnect");
				initial.submit([message(1, 0, "before-disconnect")]);
				await beforeDisconnect;

				const clientLeave = waitForMessageType(peer, "leave");
				initial.dispose();
				await clientLeave;

				const whileDisconnected = waitForOp(peer, "while-disconnected");
				peer.submit([message(1, 1, "while-disconnected")]);
				await whileDisconnected;

				const reconnected = await service.connectToDeltaStream(
					createFloodgateTestClient("stale-reconnect-client"),
				);
				try {
					const initialMessages = Reflect.get(reconnected, "details")
						.initialMessages as ISequencedDocumentMessage[];
					expect(
						initialMessages
							.filter((candidate) => candidate.type === "op")
							.map((candidate) => candidate.contents),
					).toEqual(["before-disconnect", "while-disconnected"]);

					const afterReconnect = waitForOp(reconnected, "after-reconnect");
					reconnected.submit([message(1, 1, "after-reconnect")]);
					await afterReconnect;
				} finally {
					reconnected.dispose();
				}

				const deltaStorage = await service.connectToDeltaStorage();
				const stream = deltaStorage.fetchMessages(1, 8);
				const result = await stream.read();

				expect(result.done).toBe(false);
				if (!result.done) {
					expect(
						result.value
							.filter((candidate) => candidate.type === "op")
							.map((candidate) => candidate.contents),
					).toEqual([
						"before-disconnect",
						"while-disconnected",
						"after-reconnect",
					]);
				}
			} finally {
				if (!initial.disposed) {
					initial.dispose();
				}
				peer.dispose();
			}
		});
	},
);

describe("Floodgate contract — REST endpoints required by the driver", () => {
	it("defines the create-document, session-discovery, and deltas endpoints", () => {
		expect(FLOODGATE_REST_ENDPOINTS.tokenMint("fluid")).toBe(
			"/api/tenants/fluid/token-mint",
		);
		expect(FLOODGATE_REST_ENDPOINTS.createDocument("fluid")).toBe(
			"/documents/fluid",
		);
		expect(FLOODGATE_REST_ENDPOINTS.sessionDiscovery("fluid", "doc-1")).toBe(
			"/documents/fluid/session/doc-1",
		);
		expect(FLOODGATE_REST_ENDPOINTS.deltas("fluid", "doc-1")).toBe(
			"/deltas/fluid/doc-1",
		);
	});

	it("defines git blob/tree/commit/ref endpoints", () => {
		expect(FLOODGATE_REST_ENDPOINTS.gitBlob("fluid", "abc123")).toBe(
			"/repos/fluid/git/blobs/abc123",
		);
		expect(FLOODGATE_REST_ENDPOINTS.gitTree("fluid", "abc123")).toBe(
			"/repos/fluid/git/trees/abc123",
		);
		expect(FLOODGATE_REST_ENDPOINTS.gitCommit("fluid", "abc123")).toBe(
			"/repos/fluid/git/commits/abc123",
		);
		expect(FLOODGATE_REST_ENDPOINTS.gitRefs("fluid")).toBe(
			"/repos/fluid/git/refs",
		);
		expect(FLOODGATE_REST_ENDPOINTS.gitRef("fluid", "heads/main")).toBe(
			"/repos/fluid/git/refs/heads/main",
		);
	});
});

describe.runIf(floodgateAvailable)(
	"Floodgate conformance — document REST lifecycle",
	() => {
		it.runIf(isLeveeProxyTarget)(
			"POST /documents/:tenant_id creates a document through the official REST path",
			async () => {
				const documentId = uniqueDocId("floodgate-doc-create");

				const response = await floodgateFetch(
					FLOODGATE_REST_ENDPOINTS.createDocument(FLOODGATE_TENANT_ID),
					{ method: "POST", body: { id: documentId }, documentId },
				);

				expect(response.status).toBe(201);
			},
		);

		it.runIf(!isLeveeProxyTarget)(
			"POST /documents/:tenant_id creates a server-assigned document",
			async () => {
				const response = await floodgateFetch(
					FLOODGATE_REST_ENDPOINTS.createDocument(FLOODGATE_TENANT_ID),
					{ method: "POST", body: { sequenceNumber: 0 } },
				);

				expect(response.status).toBe(201);
				const body = (await response.json()) as {
					id: string;
					tenantId: string;
				};
				expect(body.id).not.toHaveLength(0);
				expect(body.tenantId).toBe(FLOODGATE_TENANT_ID);
			},
		);

		it.runIf(isLeveeProxyTarget)(
			"GET session discovery returns an ordering-service URL usable by the driver's session discovery",
			async () => {
				const documentId = uniqueDocId("floodgate-doc-session");

				await floodgateFetch(
					FLOODGATE_REST_ENDPOINTS.createDocument(FLOODGATE_TENANT_ID),
					{
						method: "POST",
						body: { id: documentId },
						documentId,
					},
				);

				const response = await floodgateFetch(
					FLOODGATE_REST_ENDPOINTS.sessionDiscovery(
						FLOODGATE_TENANT_ID,
						documentId,
					),
					{ documentId },
				);

				expect(response.status).toBe(200);
				const session = await response.json();
				expect(typeof session.ordererUrl).toBe("string");
				expect(typeof session.deltaStreamUrl).toBe("string");
			},
		);

		it.runIf(!isLeveeProxyTarget)(
			"GET session discovery returns standalone Floodgate service URLs",
			async () => {
				const createResponse = await floodgateFetch(
					FLOODGATE_REST_ENDPOINTS.createDocument(FLOODGATE_TENANT_ID),
					{ method: "POST", body: { sequenceNumber: 0 } },
				);
				const { id: documentId } = (await createResponse.json()) as {
					id: string;
				};

				const response = await floodgateFetch(
					FLOODGATE_REST_ENDPOINTS.sessionDiscovery(
						FLOODGATE_TENANT_ID,
						documentId,
					),
					{ documentId },
				);

				expect(response.status).toBe(200);
				const session = await response.json();
				expect(session.ordererUrl).toBe(FLOODGATE_HTTP_URL);
				expect(session.historianUrl).toBe(
					`${FLOODGATE_HTTP_URL}/repos/${FLOODGATE_TENANT_ID}`,
				);
				expect(session.deltaStreamUrl).toBe(FLOODGATE_HTTP_URL);

				const metadataResponse = await floodgateFetch(
					`/documents/${FLOODGATE_TENANT_ID}/${documentId}`,
					{ documentId },
				);
				expect(metadataResponse.status).toBe(200);
				expect(await metadataResponse.json()).toEqual({
					id: documentId,
					tenantId: FLOODGATE_TENANT_ID,
					sequenceNumber: 0,
				});
			},
		);

		it.runIf(isLeveeProxyTarget)(
			"GET deltas returns an empty ops array for a brand-new document",
			async () => {
				const documentId = uniqueDocId("floodgate-doc-deltas");

				await floodgateFetch(
					FLOODGATE_REST_ENDPOINTS.createDocument(FLOODGATE_TENANT_ID),
					{
						method: "POST",
						body: { id: documentId },
						documentId,
					},
				);

				const response = await floodgateFetch(
					FLOODGATE_REST_ENDPOINTS.deltas(FLOODGATE_TENANT_ID, documentId),
					{ documentId },
				);

				expect(response.status).toBe(200);
				const body = await response.json();
				expect(Array.isArray(body.value)).toBe(true);
				expect(body.value).toHaveLength(0);
			},
		);

		it.runIf(!isLeveeProxyTarget)(
			"GET deltas paginates standalone ops in sequenceNumber order",
			async () => {
				const documentId = uniqueDocId("floodgate-doc-deltas");
				const service =
					await createFloodgateServiceFactory().createDocumentService(
						createFloodgateResolvedUrl(documentId),
					);
				const connection = await service.connectToDeltaStream(testClient);

				try {
					const firstOp = waitForOp(connection, "first-delta");
					connection.submit([message(1, 0, "first-delta")]);
					await firstOp;

					const secondOp = waitForOp(connection, "second-delta");
					connection.submit([message(2, 1, "second-delta")]);
					await secondOp;
				} finally {
					connection.dispose();
				}

				const response = await floodgateFetch(
					`${FLOODGATE_REST_ENDPOINTS.deltas(
						FLOODGATE_TENANT_ID,
						documentId,
					)}?from=1&to=3`,
					{ documentId },
				);

				expect(response.status).toBe(200);
				const body = await response.json();
				expect(body.value).toMatchObject([
					{ sequenceNumber: 2, contents: "first-delta", type: "op" },
					{ sequenceNumber: 3, contents: "second-delta", type: "op" },
				]);
			},
		);
	},
);

describe.runIf(floodgateAvailable)(
	"Floodgate conformance — git object storage (summary upload path)",
	() => {
		it("round-trips a blob through the git-like content-addressed storage endpoints", async () => {
			const content = Buffer.from(
				JSON.stringify({ hello: "floodgate" }),
			).toString("base64");

			const createResponse = await floodgateFetch(
				FLOODGATE_REST_ENDPOINTS.gitCreateBlob(FLOODGATE_TENANT_ID),
				{
					method: "POST",
					body: { content, encoding: "base64" },
					scopes: ["doc:read", "summary:write"],
				},
			);
			expect(createResponse.status).toBe(201);
			const { sha } = await createResponse.json();
			expect(typeof sha).toBe("string");

			const readResponse = await floodgateFetch(
				FLOODGATE_REST_ENDPOINTS.gitBlob(FLOODGATE_TENANT_ID, sha),
			);
			expect(readResponse.status).toBe(200);
			const blob = await readResponse.json();
			expect(blob.sha).toBe(sha);
			expect(blob.encoding).toBe("base64");
			expect(Buffer.from(blob.content, "base64").toString()).toBe(
				JSON.stringify({ hello: "floodgate" }),
			);
		});

		it("creates a tree over a blob, then a commit over the tree", async () => {
			const commitSha = await createBlobTreeCommit(
				FLOODGATE_TENANT_ID,
				"floodgate conformance content",
				"Floodgate conformance commit",
			);

			expect(typeof commitSha).toBe("string");
		});

		it("creates a ref pointing at a commit and reads it back", async () => {
			const commitSha = await createBlobTreeCommit(
				FLOODGATE_TENANT_ID,
				"floodgate conformance ref content",
				"Floodgate conformance ref commit",
			);

			const refName = `refs/heads/${uniqueDocId("floodgate-conformance")}`;
			const refResponse = await floodgateFetch(
				FLOODGATE_REST_ENDPOINTS.gitRefs(FLOODGATE_TENANT_ID),
				{
					method: "POST",
					body: { ref: refName, sha: commitSha },
					scopes: ["doc:read", "summary:write"],
				},
			);
			expect(refResponse.status).toBe(201);

			const duplicateResponse = await floodgateFetch(
				FLOODGATE_REST_ENDPOINTS.gitRefs(FLOODGATE_TENANT_ID),
				{
					method: "POST",
					body: { ref: refName, sha: "replacement-sha" },
					scopes: ["doc:read", "summary:write"],
				},
			);
			expect(duplicateResponse.status).toBe(409);

			const shortRef = refName.replace(/^refs\//, "");
			const readRefResponse = await floodgateFetch(
				FLOODGATE_REST_ENDPOINTS.gitRef(FLOODGATE_TENANT_ID, shortRef),
			);
			expect(readRefResponse.status).toBe(200);
			const ref = await readRefResponse.json();
			expect(ref.object.sha).toBe(commitSha);
		});

		it.runIf(!isLeveeProxyTarget)(
			"loads versions, snapshot trees, and blobs through the official storage service",
			async () => {
				const documentId = uniqueDocId("floodgate-storage-load");
				const content = "official storage load";
				const graph = await createBlobTreeCommitGraph(
					FLOODGATE_TENANT_ID,
					content,
					"Floodgate official storage load",
				);
				const commitResponse = await floodgateFetch(
					FLOODGATE_REST_ENDPOINTS.gitCreateCommit(FLOODGATE_TENANT_ID),
					{
						method: "POST",
						body: {
							tree: graph.treeSha,
							parents: [graph.commitSha],
							message: "Floodgate official storage load child",
							author: {
								name: "Floodgate Conformance Suite",
								email: "conformance@floodgate.local",
								date: new Date().toISOString(),
							},
						},
						scopes: ["doc:read", "summary:write"],
					},
				);
				expect(commitResponse.status).toBe(201);
				const { sha: childCommitSha } = await commitResponse.json();
				const refResponse = await floodgateFetch(
					FLOODGATE_REST_ENDPOINTS.gitRefs(FLOODGATE_TENANT_ID),
					{
						method: "POST",
						body: {
							ref: `refs/heads/${documentId}`,
							sha: childCommitSha,
						},
						documentId,
						scopes: ["doc:read", "summary:write"],
					},
				);
				expect(refResponse.status).toBe(201);

				const service =
					await createFloodgateServiceFactory().createDocumentService(
						createFloodgateResolvedUrl(documentId),
					);
				const storage = await service.connectToStorage();
				const versions = await storage.getVersions(null, 2);

				expect(versions).toMatchObject([
					{ id: childCommitSha, treeId: graph.treeSha },
					{ id: graph.commitSha, treeId: graph.treeSha },
				]);

				const snapshot = await storage.getSnapshotTree(versions[0]);
				expect(snapshot?.blobs["file.txt"]).toBe(graph.blobSha);

				const blob = await storage.readBlob(graph.blobSha);
				expect(Buffer.from(blob).toString()).toBe(content);
			},
		);

		it.runIf(!isLeveeProxyTarget)(
			"flattens nested entries when reading a tree recursively",
			async () => {
				const graph = await createBlobTreeCommitGraph(
					FLOODGATE_TENANT_ID,
					"nested tree content",
					"Floodgate nested tree fixture",
				);
				const rootTreeResponse = await floodgateFetch(
					FLOODGATE_REST_ENDPOINTS.gitCreateTree(FLOODGATE_TENANT_ID),
					{
						method: "POST",
						body: {
							tree: [
								{
									path: "nested",
									sha: graph.treeSha,
									mode: "040000",
									type: "tree",
								},
							],
						},
						scopes: ["doc:read", "summary:write"],
					},
				);
				expect(rootTreeResponse.status).toBe(201);
				const { sha: rootTreeSha } = await rootTreeResponse.json();

				const recursiveTreeResponse = await floodgateFetch(
					`${FLOODGATE_REST_ENDPOINTS.gitTree(
						FLOODGATE_TENANT_ID,
						rootTreeSha,
					)}?recursive=1`,
				);
				expect(recursiveTreeResponse.status).toBe(200);
				const recursiveTree = await recursiveTreeResponse.json();
				expect(
					recursiveTree.tree.map((entry: { path: string }) => entry.path),
				).toEqual(["nested", "nested/file.txt"]);
				expect(recursiveTree.tree[1]).toMatchObject({
					sha: graph.blobSha,
					type: "blob",
				});
			},
		);
	},
);

describe("Floodgate contract — auth/token expectations", () => {
	it("requires doc:read+doc:write scopes to create a document, per router.ex write_access", () => {
		expect(FLOODGATE_REQUIRED_SCOPES.createDocument).toEqual([
			FLOODGATE_AUTH_SCOPES.docRead,
			FLOODGATE_AUTH_SCOPES.docWrite,
		]);
	});

	it("requires doc:read+summary:write scopes for git write endpoints, per router.ex summary_access", () => {
		expect(FLOODGATE_REQUIRED_SCOPES.gitWrite).toEqual([
			FLOODGATE_AUTH_SCOPES.docRead,
			FLOODGATE_AUTH_SCOPES.summaryWrite,
		]);
	});

	it.runIf(floodgateAvailable && !isLeveeProxyTarget)(
		"rejects socket and REST tokens with the wrong key or tenant",
		async () => {
			const documentId = uniqueDocId("floodgate-wrong-key");
			const wrongKeyToken = await generateFloodgateToken(
				documentId,
				["doc:read", "doc:write"],
				"wrong-tenant-secret",
			);
			const restResponse = await fetch(
				`${FLOODGATE_HTTP_URL}${FLOODGATE_REST_ENDPOINTS.createDocument(FLOODGATE_TENANT_ID)}`,
				{
					method: "POST",
					headers: { Authorization: `Basic ${wrongKeyToken}` },
					body: JSON.stringify({ id: documentId }),
				},
			);
			expect(restResponse.status).toBe(401);

			const wrongKeyService =
				await createFloodgateServiceFactoryWithTokenProvider(
					createStaticFloodgateTokenProvider(wrongKeyToken),
				).createDocumentService(createFloodgateResolvedUrl(documentId));
			await expect(
				wrongKeyService.connectToDeltaStream(testClient),
			).rejects.toBeDefined();

			const wrongTenantToken = await generateFloodgateToken(
				documentId,
				["doc:read"],
				undefined,
				"other-tenant",
			);
			const wrongTenantResponse = await fetch(
				`${FLOODGATE_HTTP_URL}/documents/${FLOODGATE_TENANT_ID}/${documentId}`,
				{
					headers: { Authorization: `Bearer ${wrongTenantToken}` },
				},
			);
			expect(wrongTenantResponse.status).toBe(401);
		},
	);
	it.runIf(floodgateAvailable && !isLeveeProxyTarget)(
		"rejects write-mode connect_document when the token lacks doc:write",
		async () => {
			const documentId = uniqueDocId("floodgate-missing-write-scope");
			const readOnlyToken = await generateFloodgateToken(documentId, [
				"doc:read",
			]);
			const service = await createFloodgateServiceFactoryWithTokenProvider(
				createStaticFloodgateTokenProvider(readOnlyToken),
			).createDocumentService(createFloodgateResolvedUrl(documentId));

			await expect(
				service.connectToDeltaStream(
					createFloodgateTestClient("missing-write-scope", "write"),
				),
			).rejects.toBeDefined();
		},
	);
	it.runIf(floodgateAvailable && !isLeveeProxyTarget)(
		"rejects summarize operations when the token lacks summary:write",
		async () => {
			const documentId = uniqueDocId("floodgate-missing-summary-scope");
			const token = await generateFloodgateToken(documentId, [
				"doc:read",
				"doc:write",
			]);
			const service = await createFloodgateServiceFactoryWithTokenProvider(
				createStaticFloodgateTokenProvider(token),
			).createDocumentService(createFloodgateResolvedUrl(documentId));
			const connection = await service.connectToDeltaStream(testClient);

			try {
				const nack = waitForNack(connection);
				connection.submit([
					{
						clientSequenceNumber: 1,
						referenceSequenceNumber: 0,
						type: "summarize",
						contents: { handle: "not-authorized" },
					},
				]);
				const [, nacks] = await nack;
				expect(nacks[0]?.content.code).toBe(403);
			} finally {
				connection.dispose();
			}
		},
	);
	it.runIf(floodgateAvailable && !isLeveeProxyTarget)(
		"rejects official document creation when the Basic token lacks doc:write",
		async () => {
			const token = await generateFloodgateToken("", ["doc:read"]);
			const response = await fetch(
				`${FLOODGATE_HTTP_URL}${FLOODGATE_REST_ENDPOINTS.createDocument(FLOODGATE_TENANT_ID)}`,
				{
					method: "POST",
					headers: { Authorization: `Basic ${token}` },
					body: JSON.stringify({ sequenceNumber: 0 }),
				},
			);

			expect(response.status).toBe(401);
		},
	);
	it.runIf(floodgateAvailable && !isLeveeProxyTarget)(
		"connects with a token minted by the standalone token-mint integration",
		async () => {
			const documentId = uniqueDocId("floodgate-token-mint");
			const tokenProvider = createFloodgateRemoteTokenProvider();
			const service = await createFloodgateServiceFactoryWithTokenProvider(
				tokenProvider,
			).createDocumentService(createFloodgateResolvedUrl(documentId));
			const connection = await service.connectToDeltaStream(testClient);

			try {
				expect(connection.claims).toMatchObject({
					documentId,
					tenantId: FLOODGATE_TENANT_ID,
					user: { id: "floodgate-token-mint" },
				});
				expect(connection.claims.scopes).toEqual(
					expect.arrayContaining(["doc:read", "doc:write", "summary:write"]),
				);
				expect(tokenProvider.resolvedUser).toEqual({
					id: "floodgate-token-mint",
					name: "Floodgate Token Mint",
				});
			} finally {
				connection.dispose();
			}
		},
	);
});
