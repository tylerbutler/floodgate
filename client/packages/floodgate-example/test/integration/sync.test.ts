/**
 * Two-client SharedMap synchronization integration test.
 *
 * Verifies that two independent FloodgateClient instances connecting to the
 * same standalone Floodgate server can create and load a Fluid container and
 * that a SharedMap value set by client A is visible to client B via the
 * `valueChanged` event — confirming the full op-sequencing/fan-out path.
 *
 * The tests require a running standalone Floodgate server.
 *
 * To run:
 *   FLOODGATE_INTEGRATION=1 vitest run test/integration
 *
 * Or via the justfile recipe (starts + stops server automatically):
 *   just test-floodgate-sync
 *
 * When FLOODGATE_INTEGRATION is not set, all tests are silently skipped so
 * this file can be present in the workspace without breaking `pnpm test`.
 */

import type { FloodgateClient } from "@tylerbu/floodgate-client";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createFloodgateClient } from "../../src/config.js";
import {
	createDiceSession,
	DEV_ONLY_MINT_CREDENTIAL,
	DICE_VALUE_KEY,
	type DiceSession,
	subscribeToDiceMap,
} from "../../src/index.js";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const HTTP_URL = process.env["FLOODGATE_HTTP_URL"] ?? "http://localhost:3000";
const MINT_CREDENTIAL =
	process.env["FLOODGATE_MINT_CREDENTIAL"] ?? DEV_ONLY_MINT_CREDENTIAL;
const TENANT_ID = process.env["FLOODGATE_TENANT_ID"] ?? "fluid";

const isLive = process.env["FLOODGATE_INTEGRATION"] === "1";

// ---------------------------------------------------------------------------
// Connectivity check
// ---------------------------------------------------------------------------

async function isFloodgateReachable(url: string): Promise<boolean> {
	try {
		const controller = new AbortController();
		const timeout = setTimeout(() => controller.abort(), 3000);
		// An unauthenticated POST to the token-mint endpoint returns 401, which
		// proves the server is up without requiring a valid credential.
		const res = await fetch(`${url}/api/tenants/${TENANT_ID}/token-mint`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ documentId: "" }),
			signal: controller.signal,
		});
		clearTimeout(timeout);
		// 401 = server up, credential missing. 404 = server up, mint disabled.
		// Anything other than a network failure means the server is reachable.
		return res.status < 600;
	} catch {
		return false;
	}
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

describe.skipIf(!isLive)("Floodgate two-client SharedMap sync", () => {
	let client1: FloodgateClient;
	let client2: FloodgateClient;
	let session1: DiceSession;
	let session2: DiceSession;

	const config = {
		httpUrl: HTTP_URL,
		tenantId: TENANT_ID,
		mintCredential: MINT_CREDENTIAL,
	};

	beforeAll(async () => {
		const reachable = await isFloodgateReachable(HTTP_URL);
		if (!reachable) {
			throw new Error(
				`Floodgate server not reachable at ${HTTP_URL}. ` +
					"Start it with: just floodgate-server",
			);
		}

		// Create two independent clients against the same server.
		[client1, client2] = await Promise.all([
			createFloodgateClient(config),
			createFloodgateClient(config),
		]);

		// Client 1 creates a new container; client 2 loads the same document.
		session1 = await createDiceSession(client1, {});
		session2 = await createDiceSession(client2, {
			documentId: session1.documentId,
		});
	}, 30_000);

	afterAll(() => {
		session1?.dispose();
		session2?.dispose();
	});

	it("both sessions reference the same document ID", () => {
		expect(session2.documentId).toBe(session1.documentId);
	});

	it("client 2 sees the initial dice value set by client 1 on create", () => {
		expect(session2.diceMap.get(DICE_VALUE_KEY)).toBe(1);
	});

	it("client 2 receives valueChanged when client 1 updates the dice", async () => {
		const TARGET_VALUE = 5;

		const syncPromise = new Promise<void>((resolve, reject) => {
			const timer = setTimeout(
				() => reject(new Error("SharedMap sync timed out after 10 s")),
				10_000,
			);
			const cleanup = subscribeToDiceMap(session2.diceMap, () => {
				if (session2.diceMap.get(DICE_VALUE_KEY) === TARGET_VALUE) {
					clearTimeout(timer);
					cleanup();
					resolve();
				}
			});
		});

		session1.diceMap.set(DICE_VALUE_KEY, TARGET_VALUE);

		await expect(syncPromise).resolves.toBeUndefined();
		expect(session2.diceMap.get(DICE_VALUE_KEY)).toBe(TARGET_VALUE);
	}, 15_000);

	it("client 1 receives valueChanged when client 2 updates the dice", async () => {
		const TARGET_VALUE = 3;

		const syncPromise = new Promise<void>((resolve, reject) => {
			const timer = setTimeout(
				() => reject(new Error("SharedMap sync timed out after 10 s")),
				10_000,
			);
			const cleanup = subscribeToDiceMap(session1.diceMap, () => {
				if (session1.diceMap.get(DICE_VALUE_KEY) === TARGET_VALUE) {
					clearTimeout(timer);
					cleanup();
					resolve();
				}
			});
		});

		session2.diceMap.set(DICE_VALUE_KEY, TARGET_VALUE);

		await expect(syncPromise).resolves.toBeUndefined();
		expect(session1.diceMap.get(DICE_VALUE_KEY)).toBe(TARGET_VALUE);
	}, 15_000);
});
