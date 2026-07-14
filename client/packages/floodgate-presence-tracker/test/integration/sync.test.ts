import type { FloodgateClient } from "@tylerbu/floodgate-client";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import {
	createFloodgateClient,
	DEV_ONLY_MINT_CREDENTIAL,
} from "../../src/config.js";
import type { PresenceTracker, Reaction } from "../../src/presenceTracker.js";
import {
	createPresenceSession,
	type PresenceSession,
} from "../../src/session.js";

const HTTP_URL = process.env["FLOODGATE_HTTP_URL"] ?? "http://localhost:3000";
const MINT_CREDENTIAL =
	process.env["FLOODGATE_MINT_CREDENTIAL"] ?? DEV_ONLY_MINT_CREDENTIAL;
const TENANT_ID = process.env["FLOODGATE_TENANT_ID"] ?? "fluid";
const isLive = process.env["FLOODGATE_INTEGRATION"] === "1";

async function isFloodgateReachable(): Promise<boolean> {
	try {
		const response = await fetch(
			`${HTTP_URL}/api/tenants/${TENANT_ID}/token-mint`,
			{
				method: "POST",
				headers: { "content-type": "application/json" },
				body: JSON.stringify({ documentId: "" }),
				signal: AbortSignal.timeout(3000),
			},
		);
		return response.status < 600;
	} catch {
		return false;
	}
}

function waitForTracker(
	tracker: PresenceTracker,
	predicate: () => boolean,
	message: string,
): Promise<void> {
	if (predicate()) {
		return Promise.resolve();
	}
	return new Promise((resolve, reject) => {
		const timeout = setTimeout(() => {
			unsubscribe();
			reject(new Error(message));
		}, 10_000);
		const unsubscribe = tracker.subscribe(() => {
			if (predicate()) {
				clearTimeout(timeout);
				unsubscribe();
				resolve();
			}
		});
	});
}

function waitForReaction(
	tracker: PresenceTracker,
	predicate: (reaction: Reaction) => boolean,
): Promise<Reaction> {
	return new Promise((resolve, reject) => {
		const timeout = setTimeout(() => {
			unsubscribe();
			reject(new Error("Presence reaction was not received within 10 seconds"));
		}, 10_000);
		const unsubscribe = tracker.subscribeToReactions((reaction) => {
			if (predicate(reaction)) {
				clearTimeout(timeout);
				unsubscribe();
				resolve(reaction);
			}
		});
	});
}

function audienceConnectionCount(session: PresenceSession): number {
	let count = 0;
	for (const member of session.services.audience.getMembers().values()) {
		count += member.connections.length;
	}
	return count;
}

function waitForAudience(
	session: PresenceSession,
	expectedConnections: number,
): Promise<void> {
	if (audienceConnectionCount(session) === expectedConnections) {
		return Promise.resolve();
	}
	return new Promise((resolve, reject) => {
		const check = (): void => {
			if (audienceConnectionCount(session) === expectedConnections) {
				clearTimeout(timeout);
				session.services.audience.off("membersChanged", check);
				resolve();
			}
		};
		const timeout = setTimeout(() => {
			session.services.audience.off("membersChanged", check);
			reject(
				new Error("Fluid audience did not contain both client connections"),
			);
		}, 10_000);
		session.services.audience.on("membersChanged", check);
	});
}

describe.skipIf(!isLive)(
	"Floodgate two-client Presence synchronization",
	() => {
		let client1: FloodgateClient;
		let client2: FloodgateClient;
		let session1: PresenceSession;
		let session2: PresenceSession;

		beforeAll(async () => {
			if (!(await isFloodgateReachable())) {
				throw new Error(
					`Floodgate server is not reachable at ${HTTP_URL}. Run just floodgate-server.`,
				);
			}
			const config = {
				httpUrl: HTTP_URL,
				tenantId: TENANT_ID,
				mintCredential: MINT_CREDENTIAL,
			};
			[client1, client2] = await Promise.all([
				createFloodgateClient(config),
				createFloodgateClient(config),
			]);
			session1 = await createPresenceSession(client1, {});
			session2 = await createPresenceSession(client2, {
				documentId: session1.documentId,
			});
			await Promise.all([
				waitForAudience(session1, 2),
				waitForAudience(session2, 2),
			]);
			// Presence intentionally does not send state while a session is alone.
			// Publish fresh values after both containers have connected.
			session1.tracker.setCursor({ x: 0.49, y: 0.5 });
			session2.tracker.setCursor({ x: 0.51, y: 0.5 });
			await Promise.all([
				waitForTracker(
					session1.tracker,
					() => session1.tracker.getParticipants().length === 2,
					"Client 1 did not discover client 2",
				),
				waitForTracker(
					session2.tracker,
					() => session2.tracker.getParticipants().length === 2,
					"Client 2 did not discover client 1",
				),
			]);
		}, 30_000);

		afterAll(() => {
			session1?.dispose();
			session2?.dispose();
		});

		it("discovers both attendees in the same room", () => {
			expect(session2.documentId).toBe(session1.documentId);
			expect(session1.tracker.getParticipants()).toHaveLength(2);
			expect(session2.tracker.getParticipants()).toHaveLength(2);
		});

		it("synchronizes focus and normalized cursor state without sleeps", async () => {
			const attendee1 = session1.tracker
				.getParticipants()
				.find((participant) => participant.isLocal);
			expect(attendee1).toBeDefined();

			const received = waitForTracker(
				session2.tracker,
				() => {
					const remote = session2.tracker
						.getParticipants()
						.find(
							(participant) => participant.attendeeId === attendee1?.attendeeId,
						);
					return (
						remote?.state.hasFocus === false &&
						remote.state.cursor.x === 0.2 &&
						remote.state.cursor.y === 0.8
					);
				},
				"Client 2 did not receive focus and cursor state",
			);

			session1.tracker.setFocus(false);
			session1.tracker.setCursor({ x: 0.2, y: 0.8 });
			await expect(received).resolves.toBeUndefined();
		}, 15_000);

		it("broadcasts transient reactions through Presence notifications", async () => {
			const received = waitForReaction(
				session2.tracker,
				(reaction) => reaction.emoji === "🎉",
			);
			session1.tracker.sendReaction("🎉");
			await expect(received).resolves.toMatchObject({
				emoji: "🎉",
				position: { x: 0.2, y: 0.8 },
			});
		}, 15_000);
	},
);
