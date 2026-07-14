/**
 * Unit tests for package exports.
 */

import { describe, expect, it } from "vitest";

describe("main entry exports", () => {
	it("exports mount function", async () => {
		const mod = await import("../../src/index.js");
		expect(typeof mod.mount).toBe("function");
	});

	it("exports resolveConfig function", async () => {
		const mod = await import("../../src/index.js");
		expect(typeof mod.resolveConfig).toBe("function");
	});

	it("exports buildTokenEndpoint function", async () => {
		const mod = await import("../../src/index.js");
		expect(typeof mod.buildTokenEndpoint).toBe("function");
	});

	it("exports DEV_ONLY_MINT_CREDENTIAL constant", async () => {
		const mod = await import("../../src/index.js");
		expect(typeof mod.DEV_ONLY_MINT_CREDENTIAL).toBe("string");
	});

	it("exports createTodoSession function", async () => {
		const mod = await import("../../src/index.js");
		expect(typeof mod.createTodoSession).toBe("function");
	});

	it("exports todoListContainerSchema object", async () => {
		const mod = await import("../../src/index.js");
		expect(typeof mod.todoListContainerSchema).toBe("object");
		expect(mod.todoListContainerSchema).toHaveProperty("initialObjects");
	});

	it("exports TodoItem class", async () => {
		const mod = await import("../../src/index.js");
		expect(typeof mod.TodoItem).toBe("function");
	});

	it("exports TodoList class", async () => {
		const mod = await import("../../src/index.js");
		expect(typeof mod.TodoList).toBe("function");
	});
});

describe("sandbag entry exports", () => {
	it("exports a default sandbag object", async () => {
		const mod = await import("../../src/sandbag.js");
		const sandbag = mod.default;
		expect(sandbag).toBeDefined();
	});

	it("sandbag object has id, label, icon, description, and mount", async () => {
		const mod = await import("../../src/sandbag.js");
		const sandbag = mod.default;
		expect(typeof sandbag.id).toBe("string");
		expect(typeof sandbag.label).toBe("string");
		expect(typeof sandbag.icon).toBe("string");
		expect(typeof sandbag.description).toBe("string");
		expect(typeof sandbag.mount).toBe("function");
	});

	it("sandbag id is floodgate-todo-list", async () => {
		const mod = await import("../../src/sandbag.js");
		expect(mod.default.id).toBe("floodgate-todo-list");
	});

	it("sandbag mount is the same function as the main mount", async () => {
		const main = await import("../../src/index.js");
		const sandbagMod = await import("../../src/sandbag.js");
		expect(sandbagMod.default.mount).toBe(main.mount);
	});
});
