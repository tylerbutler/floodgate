import type { ITokenProvider } from "@fluidframework/routerlicious-driver";
import { RouterliciousDocumentServiceFactory } from "@fluidframework/routerlicious-driver/internal";
import { describe, expect, it } from "vitest";

import {
	createFloodgateClientAdapter,
	createFloodgateResolvedUrl,
	FloodgateUrlResolver,
} from "../src/index.js";

const tokenProvider: ITokenProvider = {
	fetchOrdererToken: async () => ({ jwt: "test-token" }),
	fetchStorageToken: async () => ({ jwt: "test-token" }),
};

describe("Floodgate client adapter", () => {
	it("builds Routerlicious endpoints for Floodgate", () => {
		const resolvedUrl = createFloodgateResolvedUrl(
			{
				httpUrl: "http://localhost:3000/",
				socketUrl: "http://localhost:3000/",
				tenantId: "tenant-a",
			},
			"document-a",
		);

		expect(resolvedUrl.id).toBe("document-a");
		expect(resolvedUrl.endpoints["ordererUrl"]).toBe("http://localhost:3000");
		expect(resolvedUrl.endpoints["deltaStreamUrl"]).toBe(
			"http://localhost:3000",
		);
		expect(resolvedUrl.endpoints["deltaStorageUrl"]).toBe(
			"http://localhost:3000/documents/tenant-a/document-a/deltas",
		);
		expect(resolvedUrl.endpoints["storageUrl"]).toBe(
			"http://localhost:3000/repos/tenant-a",
		);
	});

	it("creates an official Routerlicious document service factory", () => {
		const adapter = createFloodgateClientAdapter({
			httpUrl: "http://localhost:3000",
			tokenProvider,
		});

		expect(adapter.documentServiceFactory).toBeInstanceOf(
			RouterliciousDocumentServiceFactory,
		);
		expect(adapter.createResolvedUrl("doc").id).toBe("doc");
	});

	it("rejects an empty service URL", () => {
		expect(() =>
			createFloodgateResolvedUrl({ httpUrl: " " }, "document-a"),
		).toThrow("Floodgate httpUrl must not be empty");
	});

	it("resolves create and existing document requests", async () => {
		const resolver = new FloodgateUrlResolver({
			httpUrl: "http://localhost:3000/",
			tenantId: "tenant-a",
		});

		const createRequest = resolver.createCreateNewRequest();
		expect(createRequest.url).toBe("http://localhost:3000/tenant-a/new");
		expect((await resolver.resolve(createRequest)).id).toBe("new");

		const existingRequest = resolver.createRequestForDocument("document-a");
		expect((await resolver.resolve(existingRequest)).id).toBe("document-a");
	});
});
