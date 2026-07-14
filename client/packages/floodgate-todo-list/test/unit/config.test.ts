/**
 * Unit tests for Floodgate Todo List configuration helpers.
 */

import { describe, expect, it } from "vitest";

import {
	buildTokenEndpoint,
	DEV_ONLY_MINT_CREDENTIAL,
	resolveConfig,
} from "../../src/config.js";

describe("resolveConfig", () => {
	it("applies default httpUrl", () => {
		expect(resolveConfig().httpUrl).toBe("http://localhost:3000");
	});

	it("applies default tenantId", () => {
		expect(resolveConfig().tenantId).toBe("fluid");
	});

	it("applies dev-only default mintCredential", () => {
		expect(resolveConfig().mintCredential).toBe(DEV_ONLY_MINT_CREDENTIAL);
	});

	it("overrides httpUrl", () => {
		expect(resolveConfig({ httpUrl: "http://custom:9000" }).httpUrl).toBe(
			"http://custom:9000",
		);
	});

	it("overrides tenantId", () => {
		expect(resolveConfig({ tenantId: "my-tenant" }).tenantId).toBe("my-tenant");
	});

	it("overrides mintCredential", () => {
		expect(resolveConfig({ mintCredential: "my-secret" }).mintCredential).toBe(
			"my-secret",
		);
	});

	it("socketUrl is undefined by default", () => {
		expect(resolveConfig().socketUrl).toBeUndefined();
	});

	it("propagates socketUrl when provided", () => {
		expect(
			resolveConfig({ socketUrl: "http://localhost:3000" }).socketUrl,
		).toBe("http://localhost:3000");
	});

	it("accepts an HTTP URL as socketUrl (Routerlicious handles WS upgrade)", () => {
		const cfg = resolveConfig({ socketUrl: "http://localhost:3000" });
		expect(cfg.socketUrl).toBe("http://localhost:3000");
		expect(cfg.socketUrl).not.toMatch(/^ws/);
	});

	it("documentId is undefined by default", () => {
		expect(resolveConfig().documentId).toBeUndefined();
	});

	it("propagates documentId when provided", () => {
		expect(resolveConfig({ documentId: "some-doc" }).documentId).toBe(
			"some-doc",
		);
	});
});

describe("buildTokenEndpoint", () => {
	it("constructs token-mint URL from httpUrl and tenantId", () => {
		expect(buildTokenEndpoint("http://localhost:3000", "fluid")).toBe(
			"http://localhost:3000/api/tenants/fluid/token-mint",
		);
	});

	it("strips trailing slash from httpUrl", () => {
		expect(buildTokenEndpoint("http://localhost:3000/", "fluid")).toBe(
			"http://localhost:3000/api/tenants/fluid/token-mint",
		);
	});

	it("uses custom tenantId", () => {
		expect(buildTokenEndpoint("http://example.com", "my-tenant")).toBe(
			"http://example.com/api/tenants/my-tenant/token-mint",
		);
	});
});

describe("DEV_ONLY_MINT_CREDENTIAL", () => {
	it("is a non-empty string", () => {
		expect(typeof DEV_ONLY_MINT_CREDENTIAL).toBe("string");
		expect(DEV_ONLY_MINT_CREDENTIAL.length).toBeGreaterThan(0);
	});

	it("matches the local Floodgate server development-only credential", () => {
		expect(DEV_ONLY_MINT_CREDENTIAL).toBe("floodgate-example-mint-secret");
	});
});
