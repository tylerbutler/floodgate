import { describe, expect, it } from "vitest";

import {
	buildTokenEndpoint,
	DEV_ONLY_MINT_CREDENTIAL,
	resolveConfig,
} from "../../src/config.js";

describe("Floodgate Presence configuration", () => {
	it("applies local development defaults", () => {
		expect(resolveConfig()).toStrictEqual({
			httpUrl: "http://localhost:3000",
			socketUrl: undefined,
			tenantId: "fluid",
			mintCredential: DEV_ONLY_MINT_CREDENTIAL,
			documentId: undefined,
		});
	});

	it("preserves explicit connection and document values", () => {
		expect(
			resolveConfig({
				httpUrl: "https://floodgate.example",
				socketUrl: "https://socket.example",
				tenantId: "team",
				mintCredential: "credential",
				documentId: "room-1",
			}),
		).toStrictEqual({
			httpUrl: "https://floodgate.example",
			socketUrl: "https://socket.example",
			tenantId: "team",
			mintCredential: "credential",
			documentId: "room-1",
		});
	});

	it("builds a token endpoint without duplicate slashes", () => {
		expect(buildTokenEndpoint("https://example.test///", "tenant")).toBe(
			"https://example.test/api/tenants/tenant/token-mint",
		);
	});
});
