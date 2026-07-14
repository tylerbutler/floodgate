import { describe, expect, it } from "vitest";

describe("Floodgate Presence package exports", () => {
	it("exports the public lifecycle and Presence helpers", async () => {
		const module = await import("../../src/index.js");
		expect(typeof module.mount).toBe("function");
		expect(typeof module.createPresenceSession).toBe("function");
		expect(typeof module.PresenceTracker).toBe("function");
		expect(module.presenceContainerSchema.initialObjects).toHaveProperty(
			"metadata",
		);
	});

	it("exports a separately named Sandbag descriptor", async () => {
		const module = await import("../../src/sandbag.js");
		expect(module.default).toMatchObject({
			id: "floodgate-presence",
			label: "Floodgate Presence",
			icon: "🫧",
		});
		expect(typeof module.default.mount).toBe("function");
	});
});
