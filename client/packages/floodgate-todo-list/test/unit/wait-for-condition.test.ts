/**
 * Unit tests for the waitForCondition helper.
 *
 * These tests exercise both the success and timeout paths, including
 * verifying that the unsubscribe function is called exactly once in each
 * path — with no live server required.
 */

import { describe, expect, it, vi } from "vitest";
import { waitForCondition } from "../helpers/wait-for-condition.js";

describe("waitForCondition", () => {
	it("resolves when the condition becomes true and unsubscribes exactly once", async () => {
		let storedHandler: (() => void) | undefined;
		const unsub = vi.fn();
		const subscribe = (handler: () => void): (() => void) => {
			storedHandler = handler;
			return unsub;
		};
		let value = false;

		const promise = waitForCondition(
			subscribe,
			() => value,
			1_000,
			"timed out",
		);

		// Condition not yet met — fire event, should not resolve or unsubscribe.
		storedHandler?.();
		expect(unsub).not.toHaveBeenCalled();

		// Now meet the condition and fire again.
		value = true;
		storedHandler?.();

		await expect(promise).resolves.toBeUndefined();
		expect(unsub).toHaveBeenCalledOnce();
	});

	it("rejects with the given message on timeout and unsubscribes exactly once", async () => {
		const unsub = vi.fn();
		const subscribe = (_handler: () => void): (() => void) => unsub;

		const promise = waitForCondition(
			subscribe,
			() => false,
			20, // 20 ms keeps the test fast
			"test timeout message",
		);

		await expect(promise).rejects.toThrow("test timeout message");
		expect(unsub).toHaveBeenCalledOnce();
	});
});
