/**
 * Unit tests for schema exports.
 */

import { describe, expect, it } from "vitest";

describe("schema exports", () => {
	it("exports TodoItem class", async () => {
		const mod = await import("../../src/schema.js");
		expect(typeof mod.TodoItem).toBe("function");
	});

	it("exports TodoList class", async () => {
		const mod = await import("../../src/schema.js");
		expect(typeof mod.TodoList).toBe("function");
	});
});

describe("todoListContainerSchema", () => {
	it("exports todoListContainerSchema object", async () => {
		const mod = await import("../../src/fluid.js");
		expect(typeof mod.todoListContainerSchema).toBe("object");
	});

	it("has initialObjects with a tree property", async () => {
		const mod = await import("../../src/fluid.js");
		expect(mod.todoListContainerSchema).toHaveProperty("initialObjects");
		expect(mod.todoListContainerSchema.initialObjects).toHaveProperty("tree");
	});

	it("has dynamicObjectTypes for SharedString", async () => {
		const mod = await import("../../src/fluid.js");
		expect(mod.todoListContainerSchema).toHaveProperty("dynamicObjectTypes");
		expect(Array.isArray(mod.todoListContainerSchema.dynamicObjectTypes)).toBe(
			true,
		);
		expect(
			(mod.todoListContainerSchema.dynamicObjectTypes as unknown[]).length,
		).toBe(1);
	});

	it("exports createTodoItem function", async () => {
		const mod = await import("../../src/fluid.js");
		expect(typeof mod.createTodoItem).toBe("function");
	});

	it("exports initializeAppForNewContainer function", async () => {
		const mod = await import("../../src/fluid.js");
		expect(typeof mod.initializeAppForNewContainer).toBe("function");
	});

	it("exports loadAppFromExistingContainer function", async () => {
		const mod = await import("../../src/fluid.js");
		expect(typeof mod.loadAppFromExistingContainer).toBe("function");
	});
});
