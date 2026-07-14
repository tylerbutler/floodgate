import { describe, expect, it } from "vitest";

import {
	createParticipantIdentity,
	normalizeCursor,
} from "../../src/presenceTracker.js";

describe("createParticipantIdentity", () => {
	it("returns a deterministic identity for an attendee", () => {
		expect(createParticipantIdentity("session-1234")).toStrictEqual(
			createParticipantIdentity("session-1234"),
		);
		expect(createParticipantIdentity("session-1234").name).toBe("Guest 1234");
	});

	it("distributes different attendees across visual identities", () => {
		const first = createParticipantIdentity("session-alpha");
		const second = createParticipantIdentity("session-bravo");
		expect(first.name).not.toBe(second.name);
		expect(first.color).toMatch(/^#[0-9a-f]{6}$/i);
	});
});

describe("normalizeCursor", () => {
	it("preserves points inside the shared stage", () => {
		expect(normalizeCursor({ x: 0.25, y: 0.75 })).toStrictEqual({
			x: 0.25,
			y: 0.75,
		});
	});

	it("clamps values so remote cursors remain visible", () => {
		expect(normalizeCursor({ x: -4, y: 9 })).toStrictEqual({ x: 0, y: 1 });
	});

	it("handles non-finite pointer coordinates safely", () => {
		expect(
			normalizeCursor({ x: Number.NaN, y: Number.POSITIVE_INFINITY }),
		).toStrictEqual({ x: 0, y: 0 });
	});
});
