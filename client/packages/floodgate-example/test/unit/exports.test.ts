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

	it("exports createDiceSession function", async () => {
		const mod = await import("../../src/index.js");
		expect(typeof mod.createDiceSession).toBe("function");
	});

	it("exports subscribeToDiceMap function", async () => {
		const mod = await import("../../src/index.js");
		expect(typeof mod.subscribeToDiceMap).toBe("function");
	});

	it("exports diceContainerSchema object", async () => {
		const mod = await import("../../src/index.js");
		expect(typeof mod.diceContainerSchema).toBe("object");
		expect(mod.diceContainerSchema).toHaveProperty("initialObjects");
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

	it("sandbag id is floodgate-dice-roller", async () => {
		const mod = await import("../../src/sandbag.js");
		expect(mod.default.id).toBe("floodgate-dice-roller");
	});

	it("sandbag mount is the same function as the main mount", async () => {
		const main = await import("../../src/index.js");
		const sandbagMod = await import("../../src/sandbag.js");
		expect(sandbagMod.default.mount).toBe(main.mount);
	});
});
