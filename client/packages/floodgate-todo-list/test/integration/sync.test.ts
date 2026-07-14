/**
 * Two-client SharedTree + dynamic SharedString synchronization integration test.
 *
 * Verifies that two independent FloodgateClient instances connecting to the
 * same standalone Floodgate server can create and load a Fluid container backed
 * by a SharedTree (Todo List), and that:
 *   - Both clients observe the initialized TodoList.
 *   - A SharedTree field mutation (boolean toggle) from client 1 propagates to
 *     client 2 via the `nodeChanged` event — no sleeps.
 *   - A dynamically created TodoItem inserted by client 2 propagates to client 1
 *     via the `treeChanged` event, and the item's SharedString title can be
 *     resolved and asserted.
 *   - A SharedString edit from client 2 on the dynamic item's title propagates
 *     to client 1 via the `sequenceDelta` event — no sleeps.
 *
 * The tests require a running standalone Floodgate server.
 *
 * To run:
 *   FLOODGATE_INTEGRATION=1 vitest run test/integration
 *
 * Or via the justfile recipe (starts + stops server automatically):
 *   just test-floodgate-todo-sync
 *
 * When FLOODGATE_INTEGRATION is not set, all tests are silently skipped so
 * this file can be present in the workspace without breaking `pnpm test`.
 */

import type { FloodgateClient } from "@tylerbu/floodgate-client";
import type { IFluidHandle } from "fluid-framework";
import { Tree } from "fluid-framework";
import type { ISharedString } from "fluid-framework/legacy";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
	createFloodgateClient,
	DEV_ONLY_MINT_CREDENTIAL,
} from "../../src/config.js";
import {
	createTodoItem,
	createTodoSession,
	type TodoSession,
} from "../../src/index.js";
import { waitForCondition } from "../helpers/wait-for-condition.js";

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

describe.skipIf(!isLive)(
	"Floodgate two-client SharedTree + SharedString sync",
	() => {
		let client1: FloodgateClient;
		let client2: FloodgateClient;
		let session1: TodoSession;
		let session2: TodoSession;

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
			session1 = await createTodoSession(client1, {});
			session2 = await createTodoSession(client2, {
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

		it("both sessions observe the initialized TodoList with 2 items", () => {
			expect(session1.todoList.items.length).toBe(2);
			expect(session2.todoList.items.length).toBe(2);
		});

		it("both sessions resolve the TodoList title SharedString", async () => {
			const handle1 = session1.todoList.title as IFluidHandle<ISharedString>;
			const handle2 = session2.todoList.title as IFluidHandle<ISharedString>;
			const [title1, title2] = await Promise.all([
				handle1.get(),
				handle2.get(),
			]);
			expect(title1.getText()).toBe("My to-do list");
			expect(title2.getText()).toBe("My to-do list");
		});

		it("client 2 observes SharedTree nodeChanged when client 1 toggles completed", async () => {
			const item1 = session1.todoList.items[0];
			const item2 = session2.todoList.items[0];
			const initialCompleted = item1.completed;
			const targetCompleted = !initialCompleted;

			const syncPromise = waitForCondition(
				(handler) => Tree.on(item2, "nodeChanged", handler),
				() => item2.completed === targetCompleted,
				10_000,
				"SharedTree nodeChanged timed out after 10 s",
			);

			item1.completed = targetCompleted;

			await expect(syncPromise).resolves.toBeUndefined();
			expect(item2.completed).toBe(targetCompleted);
		}, 15_000);

		it("client 1 observes dynamic item insertion and resolves its SharedString title", async () => {
			const INITIAL_TITLE = "Dynamic Task";
			const initialCount = session1.todoList.items.length;

			const insertionPromise = waitForCondition(
				(handler) => Tree.on(session1.todoList, "treeChanged", handler),
				() => session1.todoList.items.length === initialCount + 1,
				10_000,
				"Tree insertion treeChanged timed out after 10 s",
			);

			// Client 2 creates a new TodoItem and inserts it at the end.
			const newItem = await createTodoItem({
				container: session2.container,
				completed: false,
				initialTitleText: INITIAL_TITLE,
			});
			session2.todoList.items.insertAtEnd(newItem);

			await expect(insertionPromise).resolves.toBeUndefined();
			expect(session1.todoList.items.length).toBe(initialCount + 1);

			// Resolve the SharedString title from client 1's view of the new item.
			const remoteItem = session1.todoList.items[initialCount];
			const remoteHandle = remoteItem.title as IFluidHandle<ISharedString>;
			const remoteTitle = await remoteHandle.get();
			expect(remoteTitle.getText()).toBe(INITIAL_TITLE);
		}, 15_000);

		it("client 1 observes SharedString sequenceDelta when client 2 edits the dynamic item title", async () => {
			const currentCount = session1.todoList.items.length;
			// The dynamic item was appended last; get its title on each client.
			const client1Item = session1.todoList.items[currentCount - 1];
			const client2Item = session2.todoList.items[currentCount - 1];

			const client1Handle = client1Item.title as IFluidHandle<ISharedString>;
			const client2Handle = client2Item.title as IFluidHandle<ISharedString>;
			const [titleOnClient1, titleOnClient2] = await Promise.all([
				client1Handle.get(),
				client2Handle.get(),
			]);

			const ORIGINAL_TEXT = titleOnClient1.getText();
			const APPENDED_TEXT = " (done)";
			const EXPECTED_TEXT = `${ORIGINAL_TEXT}${APPENDED_TEXT}`;

			const sharedStringPromise = waitForCondition(
				(handler) => {
					titleOnClient1.on("sequenceDelta", handler);
					return () => titleOnClient1.off("sequenceDelta", handler);
				},
				() => titleOnClient1.getText() === EXPECTED_TEXT,
				10_000,
				"SharedString sequenceDelta timed out after 10 s",
			);

			// Client 2 appends text to the dynamic item's title SharedString.
			const currentLen = titleOnClient2.getText().length;
			titleOnClient2.insertText(currentLen, APPENDED_TEXT);

			await expect(sharedStringPromise).resolves.toBeUndefined();
			expect(titleOnClient1.getText()).toBe(EXPECTED_TEXT);
		}, 15_000);
	},
);
