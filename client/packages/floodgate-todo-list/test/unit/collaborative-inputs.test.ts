/**
 * Unit tests for collaborative input listener cleanup.
 *
 * Verifies that `SharedStringHelper.dispose()` removes the sequenceDelta
 * listener, and that `CollaborativeInput` uses a stable listener reference
 * so `componentWillUnmount` can clean it up correctly.
 */

import type { SharedString } from "@fluidframework/sequence/legacy";
import { describe, expect, it, vi } from "vitest";
import { CollaborativeInput } from "../../src/collaborative-inputs/CollaborativeInput.js";
import { SharedStringHelper } from "../../src/collaborative-inputs/SharedStringHelper.js";

// ---------------------------------------------------------------------------
// Minimal fake SharedString — only the event API needed by these tests.
// ---------------------------------------------------------------------------

type AnyFn = (...args: unknown[]) => unknown;

function makeSharedString(text = "") {
	return {
		on: vi.fn().mockReturnThis(),
		off: vi.fn().mockReturnThis(),
		getText: vi.fn().mockReturnValue(text),
	};
}

// ---------------------------------------------------------------------------
// SharedStringHelper — dispose
// ---------------------------------------------------------------------------

describe("SharedStringHelper — dispose()", () => {
	it("removes the sequenceDelta listener registered during construction", () => {
		const ss = makeSharedString();
		const helper = new SharedStringHelper(ss as unknown as SharedString);

		expect(ss.on).toHaveBeenCalledOnce();
		expect(ss.on).toHaveBeenCalledWith("sequenceDelta", expect.any(Function));

		helper.dispose();

		expect(ss.off).toHaveBeenCalledOnce();
		expect(ss.off).toHaveBeenCalledWith("sequenceDelta", expect.any(Function));
	});

	it("passes the exact same listener reference to off as was passed to on", () => {
		const ss = makeSharedString();
		const helper = new SharedStringHelper(ss as unknown as SharedString);

		const [[, registeredFn]] = ss.on.mock.calls as [[string, AnyFn]];

		helper.dispose();

		const [[, removedFn]] = ss.off.mock.calls as [[string, AnyFn]];

		expect(removedFn).toBe(registeredFn);
	});

	it("no longer receives sequenceDelta events after dispose", () => {
		const listeners = new Map<string, Set<AnyFn>>();
		const ss = {
			on: vi.fn((event: string, fn: AnyFn) => {
				if (!listeners.has(event)) listeners.set(event, new Set());
				listeners.get(event)?.add(fn);
			}),
			off: vi.fn((event: string, fn: AnyFn) => {
				listeners.get(event)?.delete(fn);
			}),
			getText: vi.fn().mockReturnValue("hello"),
		};

		const helper = new SharedStringHelper(ss as unknown as SharedString);
		const textChangedSpy = vi.fn();
		helper.on("textChanged", textChangedSpy);

		// Simulate a remote delta before dispose — textChanged should fire.
		const fakeEvent = {
			isLocal: false,
			opArgs: { op: { type: 0 /* INSERT */, pos1: 0, seg: "x" } },
		};
		for (const fn of listeners.get("sequenceDelta") ?? []) {
			fn(fakeEvent);
		}
		expect(textChangedSpy).toHaveBeenCalledOnce();

		// After dispose, the listener is removed; no further events.
		helper.dispose();
		for (const fn of listeners.get("sequenceDelta") ?? []) {
			fn(fakeEvent);
		}
		expect(textChangedSpy).toHaveBeenCalledOnce(); // still only once
	});
});

// ---------------------------------------------------------------------------
// CollaborativeInput — componentWillUnmount cleanup
// ---------------------------------------------------------------------------

describe("CollaborativeInput — componentWillUnmount()", () => {
	it("calls sharedString.off with the same function reference passed to on", () => {
		const ss = makeSharedString();
		const component = new CollaborativeInput({
			sharedString: ss as unknown as SharedString,
		});

		component.componentDidMount?.();

		const [[, addedFn]] = ss.on.mock.calls as [[string, AnyFn]];

		component.componentWillUnmount?.();

		const [[, removedFn]] = ss.off.mock.calls as [[string, AnyFn]];

		expect(removedFn).toBe(addedFn);
	});

	it("calls off with the 'sequenceDelta' event name", () => {
		const ss = makeSharedString();
		const component = new CollaborativeInput({
			sharedString: ss as unknown as SharedString,
		});

		component.componentDidMount?.();
		component.componentWillUnmount?.();

		expect(ss.off).toHaveBeenCalledWith("sequenceDelta", expect.any(Function));
	});

	it("calling componentWillUnmount without a prior componentDidMount does not throw", () => {
		// Defensive: off is safe to call with a function that was never registered.
		const ss = makeSharedString();
		const component = new CollaborativeInput({
			sharedString: ss as unknown as SharedString,
		});

		expect(() => component.componentWillUnmount?.()).not.toThrow();
	});
});
