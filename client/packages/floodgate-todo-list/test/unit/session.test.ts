/**
 * Unit tests for Todo session lifecycle.
 *
 * Tests create vs load dispatch, attach ID propagation, tree initialization,
 * and container disposal — all without a live Floodgate server.
 *
 * `initializeAppForNewContainer` and `loadAppFromExistingContainer` are mocked
 * out so these tests exercise only the session lifecycle, not the SharedTree
 * schema validation (which requires a live Fluid runtime).
 */

import type { FloodgateClient } from "@tylerbu/floodgate-client";
import type { IFluidContainer } from "fluid-framework";
import { describe, expect, it, vi } from "vitest";

// Mock the fluid module to avoid hitting the real SharedTree schema validation.
vi.mock("../../src/fluid.js", () => ({
	todoListContainerSchema: {
		initialObjects: { tree: {} },
		dynamicObjectTypes: [],
	},
	initializeAppForNewContainer: vi
		.fn()
		.mockResolvedValue({ items: [], title: null }),
	loadAppFromExistingContainer: vi
		.fn()
		.mockReturnValue({ items: [], title: null }),
}));

import type { TodoListContainerSchema } from "../../src/fluid.js";
import { initializeAppForNewContainer } from "../../src/fluid.js";
import { createTodoSession } from "../../src/session.js";

// ---------------------------------------------------------------------------
// Minimal fakes
// ---------------------------------------------------------------------------

/** Fake IFluidContainer. */
function makeContainer(attachId = "server-doc-id") {
	return {
		initialObjects: { tree: {} },
		attach: vi.fn().mockResolvedValue(attachId),
		dispose: vi.fn<[], void>(),
	} as unknown as IFluidContainer<TodoListContainerSchema> & {
		attach: ReturnType<typeof vi.fn>;
		dispose: ReturnType<typeof vi.fn>;
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
// createTodoSession — create path
// ---------------------------------------------------------------------------

describe("createTodoSession — create path", () => {
	it("calls createContainer when documentId is absent", async () => {
		const mockContainer = makeContainer();
		const mockClient = makeMockClient(mockContainer);

		await createTodoSession(mockClient, {});

		expect(mockClient.createContainer).toHaveBeenCalledOnce();
		expect(mockClient.getContainer).not.toHaveBeenCalled();
	});

	it("calls container.attach() on create", async () => {
		const mockContainer = makeContainer("server-assigned-id");
		const mockClient = makeMockClient(mockContainer);

		await createTodoSession(mockClient, {});

		expect(mockContainer.attach).toHaveBeenCalledOnce();
	});

	it("returns the server-assigned documentId from attach()", async () => {
		const mockContainer = makeContainer("real-server-id");
		const mockClient = makeMockClient(mockContainer);

		const session = await createTodoSession(mockClient, {});

		expect(session.documentId).toBe("real-server-id");
	});

	it("does not use any pre-generated ID — documentId comes only from attach()", async () => {
		const mockContainer = makeContainer("server-assigned-abc123");
		const mockClient = makeMockClient(mockContainer);

		const session = await createTodoSession(mockClient, {});

		expect(session.documentId).toBe("server-assigned-abc123");
	});

	it("initializes before attach: createContainer → initialize → attach", async () => {
		const callOrder: string[] = [];
		const mockContainer = makeContainer();
		vi.spyOn(mockContainer, "attach").mockImplementation(async () => {
			callOrder.push("attach");
			return "doc-id";
		});
		const mockClient = makeMockClient(mockContainer);
		vi.spyOn(mockClient, "createContainer").mockImplementation(async () => {
			callOrder.push("createContainer");
			return { container: mockContainer, services: {} };
		});
		vi.mocked(initializeAppForNewContainer).mockImplementationOnce(async () => {
			callOrder.push("initialize");
			return { items: [], title: null } as unknown as Awaited<
				ReturnType<typeof initializeAppForNewContainer>
			>;
		});

		await createTodoSession(mockClient, {});

		expect(callOrder).toStrictEqual([
			"createContainer",
			"initialize",
			"attach",
		]);
	});
});

// ---------------------------------------------------------------------------
// createTodoSession — load path
// ---------------------------------------------------------------------------

describe("createTodoSession — load path", () => {
	it("calls getContainer when documentId is provided", async () => {
		const mockContainer = makeContainer();
		const mockClient = makeMockClient(mockContainer);

		await createTodoSession(mockClient, { documentId: "existing-doc" });

		expect(mockClient.getContainer).toHaveBeenCalledOnce();
		expect(mockClient.createContainer).not.toHaveBeenCalled();
	});

	it("passes the documentId to getContainer", async () => {
		const mockContainer = makeContainer();
		const mockClient = makeMockClient(mockContainer);

		await createTodoSession(mockClient, { documentId: "existing-doc" });

		expect(mockClient.getContainer).toHaveBeenCalledWith(
			"existing-doc",
			expect.anything(),
			"2",
		);
	});

	it("returns the config documentId on load (does not call attach)", async () => {
		const mockContainer = makeContainer();
		const mockClient = makeMockClient(mockContainer);

		const session = await createTodoSession(mockClient, {
			documentId: "existing-doc",
		});

		expect(session.documentId).toBe("existing-doc");
		expect(mockContainer.attach).not.toHaveBeenCalled();
	});
});

// ---------------------------------------------------------------------------
// createTodoSession — session shape
// ---------------------------------------------------------------------------

describe("createTodoSession — session shape", () => {
	it("returns a todoList on create", async () => {
		const mockContainer = makeContainer();
		const mockClient = makeMockClient(mockContainer);

		const session = await createTodoSession(mockClient, {});

		expect(session.todoList).toBeDefined();
	});

	it("returns a container on create", async () => {
		const mockContainer = makeContainer();
		const mockClient = makeMockClient(mockContainer);

		const session = await createTodoSession(mockClient, {});

		expect(session.container).toBe(mockContainer);
	});

	it("returns a todoList on load", async () => {
		const mockContainer = makeContainer();
		const mockClient = makeMockClient(mockContainer);

		const session = await createTodoSession(mockClient, {
			documentId: "doc-123",
		});

		expect(session.todoList).toBeDefined();
	});

	it("returns the container on load", async () => {
		const mockContainer = makeContainer();
		const mockClient = makeMockClient(mockContainer);

		const session = await createTodoSession(mockClient, {
			documentId: "doc-123",
		});

		expect(session.container).toBe(mockContainer);
	});
});

// ---------------------------------------------------------------------------
// createTodoSession — disposal
// ---------------------------------------------------------------------------

describe("createTodoSession — disposal", () => {
	it("dispose() calls container.dispose() on create path", async () => {
		const mockContainer = makeContainer();
		const mockClient = makeMockClient(mockContainer);

		const session = await createTodoSession(mockClient, {});
		session.dispose();

		expect(mockContainer.dispose).toHaveBeenCalledOnce();
	});

	it("dispose() calls container.dispose() on load path", async () => {
		const mockContainer = makeContainer();
		const mockClient = makeMockClient(mockContainer);

		const session = await createTodoSession(mockClient, {
			documentId: "existing-doc",
		});
		session.dispose();

		expect(mockContainer.dispose).toHaveBeenCalledOnce();
	});
});
