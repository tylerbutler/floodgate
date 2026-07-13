/**
 * Behavioral tests for dice session lifecycle and SharedMap subscription.
 *
 * Tests create vs load dispatch, real attach ID propagation, SharedMap
 * initialization, listener cleanup, and container disposal — all without a
 * live Floodgate server.
 */

import type { ISharedMap } from "@fluidframework/map/legacy";
import type { FloodgateClient } from "@tylerbu/floodgate-client";
import { describe, expect, it, vi } from "vitest";

import { DICE_VALUE_KEY, subscribeToDiceMap } from "../../src/diceRoller.js";
import { createDiceSession } from "../../src/session.js";

// ---------------------------------------------------------------------------
// Minimal fakes
// ---------------------------------------------------------------------------

type Listener = (...args: unknown[]) => void;

/** In-memory ISharedMap stub with event tracking. */
function makeSharedMap(): ISharedMap & {
	_data: Map<string, unknown>;
	_emit: (event: string) => void;
} {
	const _data = new Map<string, unknown>();
	const _listeners = new Map<string, Set<Listener>>();

	const _emit = (event: string): void => {
		for (const fn of _listeners.get(event) ?? []) fn();
	};

	const stub = {
		_data,
		_emit,
		get: (key: string) => _data.get(key),
		set: (key: string, value: unknown) => {
			_data.set(key, value);
			return stub;
		},
		on: (event: string, fn: Listener) => {
			if (!_listeners.has(event)) _listeners.set(event, new Set());
			_listeners.get(event)?.add(fn);
			return stub;
		},
		off: (event: string, fn: Listener) => {
			_listeners.get(event)?.delete(fn);
			return stub;
		},
	} as unknown as ISharedMap & {
		_data: Map<string, unknown>;
		_emit: (event: string) => void;
	};

	return stub;
}

function makeContainer(diceMap: ISharedMap, attachId = "server-doc-id") {
	return {
		initialObjects: { dice: diceMap },
		attach: vi.fn().mockResolvedValue(attachId),
		dispose: vi.fn<[], void>(),
	};
}

function makeMockClient(
	container: ReturnType<typeof makeContainer>,
): FloodgateClient {
	return {
		createContainer: vi.fn().mockResolvedValue({ container, services: {} }),
		getContainer: vi.fn().mockResolvedValue({ container, services: {} }),
	} as unknown as FloodgateClient;
}

// ---------------------------------------------------------------------------
// createDiceSession
// ---------------------------------------------------------------------------

describe("createDiceSession — create path", () => {
	it("calls createContainer when documentId is absent", async () => {
		const mockMap = makeSharedMap();
		const mockContainer = makeContainer(mockMap);
		const mockClient = makeMockClient(mockContainer);

		await createDiceSession(mockClient, {});

		expect(mockClient.createContainer).toHaveBeenCalledOnce();
		expect(mockClient.getContainer).not.toHaveBeenCalled();
	});

	it("initializes dice value to 1 on create", async () => {
		const mockMap = makeSharedMap();
		const mockContainer = makeContainer(mockMap);
		const mockClient = makeMockClient(mockContainer);

		await createDiceSession(mockClient, {});

		expect(mockMap._data.get(DICE_VALUE_KEY)).toBe(1);
	});

	it("calls container.attach() and uses the returned ID as documentId", async () => {
		const mockMap = makeSharedMap();
		const mockContainer = makeContainer(mockMap, "real-server-id");
		const mockClient = makeMockClient(mockContainer);

		const session = await createDiceSession(mockClient, {});

		expect(mockContainer.attach).toHaveBeenCalledOnce();
		expect(session.documentId).toBe("real-server-id");
	});

	it("does not use any pre-generated ID when attach returns the real one", async () => {
		const mockMap = makeSharedMap();
		const mockContainer = makeContainer(mockMap, "server-assigned-abc123");
		const mockClient = makeMockClient(mockContainer);

		const session = await createDiceSession(mockClient, {});

		// The returned documentId must equal what the server assigned, not a local guess.
		expect(session.documentId).toBe("server-assigned-abc123");
	});
});

describe("createDiceSession — load path", () => {
	it("calls getContainer when documentId is provided", async () => {
		const mockMap = makeSharedMap();
		const mockContainer = makeContainer(mockMap);
		const mockClient = makeMockClient(mockContainer);

		await createDiceSession(mockClient, { documentId: "existing-doc" });

		expect(mockClient.getContainer).toHaveBeenCalledOnce();
		expect(mockClient.createContainer).not.toHaveBeenCalled();
	});

	it("passes the documentId to getContainer", async () => {
		const mockMap = makeSharedMap();
		const mockContainer = makeContainer(mockMap);
		const mockClient = makeMockClient(mockContainer);

		await createDiceSession(mockClient, { documentId: "existing-doc" });

		expect(mockClient.getContainer).toHaveBeenCalledWith(
			"existing-doc",
			expect.anything(),
			"2",
		);
	});

	it("returns the config documentId (does not call attach)", async () => {
		const mockMap = makeSharedMap();
		const mockContainer = makeContainer(mockMap);
		const mockClient = makeMockClient(mockContainer);

		const session = await createDiceSession(mockClient, {
			documentId: "existing-doc",
		});

		expect(session.documentId).toBe("existing-doc");
		expect(mockContainer.attach).not.toHaveBeenCalled();
	});

	it("does not set dice value on load", async () => {
		const mockMap = makeSharedMap();
		const mockContainer = makeContainer(mockMap);
		const mockClient = makeMockClient(mockContainer);

		await createDiceSession(mockClient, { documentId: "existing-doc" });

		expect(mockMap._data.has(DICE_VALUE_KEY)).toBe(false);
	});
});

describe("createDiceSession — disposal", () => {
	it("dispose() calls container.dispose()", async () => {
		const mockMap = makeSharedMap();
		const mockContainer = makeContainer(mockMap);
		const mockClient = makeMockClient(mockContainer);

		const session = await createDiceSession(mockClient, {});
		session.dispose();

		expect(mockContainer.dispose).toHaveBeenCalledOnce();
	});

	it("dispose() also works for the load path", async () => {
		const mockMap = makeSharedMap();
		const mockContainer = makeContainer(mockMap);
		const mockClient = makeMockClient(mockContainer);

		const session = await createDiceSession(mockClient, {
			documentId: "existing-doc",
		});
		session.dispose();

		expect(mockContainer.dispose).toHaveBeenCalledOnce();
	});
});

// ---------------------------------------------------------------------------
// subscribeToDiceMap
// ---------------------------------------------------------------------------

describe("subscribeToDiceMap", () => {
	it("registers a valueChanged listener on the map", () => {
		const mockMap = {
			on: vi.fn().mockReturnThis(),
			off: vi.fn().mockReturnThis(),
		} as unknown as ISharedMap;
		const onChange = vi.fn();

		subscribeToDiceMap(mockMap, onChange);

		expect(mockMap.on).toHaveBeenCalledWith("valueChanged", onChange);
	});

	it("returned cleanup removes the listener", () => {
		const mockMap = {
			on: vi.fn().mockReturnThis(),
			off: vi.fn().mockReturnThis(),
		} as unknown as ISharedMap;
		const onChange = vi.fn();

		const cleanup = subscribeToDiceMap(mockMap, onChange);
		cleanup();

		expect(mockMap.off).toHaveBeenCalledWith("valueChanged", onChange);
	});

	it("onChange is invoked when valueChanged fires", () => {
		const mockMap = makeSharedMap();
		const onChange = vi.fn();

		subscribeToDiceMap(mockMap, onChange);
		mockMap._emit("valueChanged");

		expect(onChange).toHaveBeenCalledOnce();
	});

	it("onChange is NOT invoked after cleanup", () => {
		const mockMap = makeSharedMap();
		const onChange = vi.fn();

		const cleanup = subscribeToDiceMap(mockMap, onChange);
		cleanup();
		mockMap._emit("valueChanged");

		expect(onChange).not.toHaveBeenCalled();
	});
});
