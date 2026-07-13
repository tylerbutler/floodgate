import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
	type FloodgateIdentity,
	RemoteFloodgateTokenProvider,
} from "../src/tokenProvider.js";

const ENDPOINT = "http://localhost:3000/api/tenants/fluid/token-mint";
const CREDENTIAL = "test-mint-secret";
const TENANT_ID = "fluid";
const DOCUMENT_ID = "doc-1";

const mockUser: FloodgateIdentity = { id: "user-1", name: "Test User" };

function makeOkResponse(
	overrides: Partial<{ jwt: string; expiresIn: number; user: object }> = {},
): Response {
	return new Response(
		JSON.stringify({
			jwt: "test-jwt-token",
			expiresIn: 3600,
			user: mockUser,
			...overrides,
		}),
		{ status: 200, headers: { "Content-Type": "application/json" } },
	);
}

/** Build a 200 response with an arbitrary (possibly invalid) body for validation tests. */
function makeRawOkResponse(body: Record<string, unknown>): Response {
	return new Response(JSON.stringify(body), {
		status: 200,
		headers: { "Content-Type": "application/json" },
	});
}

describe("RemoteFloodgateTokenProvider", () => {
	// biome-ignore lint/suspicious/noExplicitAny: mock spy
	let fetchSpy: ReturnType<typeof vi.fn<any, any>>;

	beforeEach(() => {
		fetchSpy = vi
			.fn()
			.mockImplementation(() => Promise.resolve(makeOkResponse()));
		vi.stubGlobal("fetch", fetchSpy);
	});

	afterEach(() => {
		vi.unstubAllGlobals();
	});

	describe("request shape", () => {
		it("POSTs tenantId and documentId to the token endpoint", async () => {
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID);

			expect(fetchSpy).toHaveBeenCalledOnce();
			const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
			expect(url).toBe(ENDPOINT);
			expect(init.method).toBe("POST");
			const body = JSON.parse(init.body as string) as Record<string, unknown>;
			expect(body).toMatchObject({
				tenantId: TENANT_ID,
				documentId: DOCUMENT_ID,
			});
		});

		it("defaults documentId to empty string when omitted from fetchOrdererToken", async () => {
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await provider.fetchOrdererToken(TENANT_ID);

			const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
			const body = JSON.parse(init.body as string) as Record<string, unknown>;
			expect(body["documentId"]).toBe("");
		});

		it("sets Content-Type to application/json", async () => {
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID);

			const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
			expect((init.headers as Record<string, string>)["Content-Type"]).toBe(
				"application/json",
			);
		});
	});

	describe("bearer authorization", () => {
		it("sends Authorization: Bearer <credential>", async () => {
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID);

			const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
			expect((init.headers as Record<string, string>)["Authorization"]).toBe(
				`Bearer ${CREDENTIAL}`,
			);
		});
	});

	describe("caching", () => {
		it("returns the cached token on a second call without re-fetching", async () => {
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			const first = await provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID);
			const second = await provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID);

			expect(fetchSpy).toHaveBeenCalledOnce();
			expect(second.jwt).toBe(first.jwt);
		});

		it("shares the cached token between orderer and storage for the same document", async () => {
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID);
			await provider.fetchStorageToken(TENANT_ID, DOCUMENT_ID);

			expect(fetchSpy).toHaveBeenCalledOnce();
		});

		it("re-fetches when the cached token is past the 1-minute-early expiry", async () => {
			// expiresIn: 59 s → expiresAt = now + 59_000 - 60_000 = now - 1_000 → already expired
			fetchSpy.mockResolvedValueOnce(
				makeOkResponse({ jwt: "old-token", expiresIn: 59 }),
			);
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID);
			await provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID);

			expect(fetchSpy).toHaveBeenCalledTimes(2);
		});

		it("uses separate cache entries for different documents", async () => {
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await provider.fetchOrdererToken(TENANT_ID, "doc-a");
			await provider.fetchOrdererToken(TENANT_ID, "doc-b");

			expect(fetchSpy).toHaveBeenCalledTimes(2);
		});
	});

	describe("refresh", () => {
		it("bypasses the orderer token cache when refresh=true", async () => {
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID);
			await provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID, true);

			expect(fetchSpy).toHaveBeenCalledTimes(2);
		});

		it("bypasses the storage token cache when refresh=true", async () => {
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await provider.fetchStorageToken(TENANT_ID, DOCUMENT_ID);
			await provider.fetchStorageToken(TENANT_ID, DOCUMENT_ID, true);

			expect(fetchSpy).toHaveBeenCalledTimes(2);
		});

		it("updates the cache entry after a forced refresh", async () => {
			fetchSpy
				.mockResolvedValueOnce(makeOkResponse({ jwt: "first-token" }))
				.mockResolvedValueOnce(makeOkResponse({ jwt: "second-token" }));

			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID);
			const refreshed = await provider.fetchOrdererToken(
				TENANT_ID,
				DOCUMENT_ID,
				true,
			);
			// subsequent read hits the new cache
			const cached = await provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID);

			expect(refreshed.jwt).toBe("second-token");
			expect(cached.jwt).toBe("second-token");
			expect(fetchSpy).toHaveBeenCalledTimes(2);
		});
	});

	describe("user resolution", () => {
		it("resolvedUser is undefined before any fetch", () => {
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			expect(provider.resolvedUser).toBeUndefined();
		});

		it("populates resolvedUser after the first successful fetch", async () => {
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID);
			expect(provider.resolvedUser).toEqual(mockUser);
		});

		it("resolveUser returns the server-provided user identity", async () => {
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			const user = await provider.resolveUser(TENANT_ID, DOCUMENT_ID);
			expect(user).toEqual(mockUser);
		});

		it("resolveUser accepts an optional documentId and defaults to empty string", async () => {
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			const user = await provider.resolveUser(TENANT_ID);
			expect(user).toEqual(mockUser);
			const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
			const body = JSON.parse(init.body as string) as Record<string, unknown>;
			expect(body["documentId"]).toBe("");
		});

		it("resolveUser throws when the server omits the user field", async () => {
			fetchSpy.mockResolvedValueOnce(
				new Response(
					JSON.stringify({ jwt: "test-jwt-token", expiresIn: 3600 }),
					{ status: 200, headers: { "Content-Type": "application/json" } },
				),
			);
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await expect(provider.resolveUser(TENANT_ID)).rejects.toThrow(
				"missing required 'user' field",
			);
		});
	});

	describe("error handling", () => {
		it("throws with status code for a 401 Unauthorized response", async () => {
			fetchSpy.mockResolvedValueOnce(
				new Response(JSON.stringify({ error: "unauthorized" }), {
					status: 401,
					statusText: "Unauthorized",
				}),
			);
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await expect(
				provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID),
			).rejects.toThrow("401");
		});

		it("throws for a 500 Internal Server Error", async () => {
			fetchSpy.mockResolvedValueOnce(
				new Response(null, {
					status: 500,
					statusText: "Internal Server Error",
				}),
			);
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await expect(
				provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID),
			).rejects.toThrow("500");
		});

		it("throws a descriptive error when the response is missing the jwt field", async () => {
			fetchSpy.mockResolvedValueOnce(
				new Response(JSON.stringify({ expiresIn: 3600 }), {
					status: 200,
					headers: { "Content-Type": "application/json" },
				}),
			);
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await expect(
				provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID),
			).rejects.toThrow("missing required 'jwt' field");
		});

		it("throws when the response user field has an unexpected shape", async () => {
			fetchSpy.mockResolvedValueOnce(
				new Response(
					JSON.stringify({ jwt: "test-token", user: { id: 42, name: "bad" } }),
					{ status: 200, headers: { "Content-Type": "application/json" } },
				),
			);
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await expect(
				provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID),
			).rejects.toThrow("unexpected shape");
		});
	});

	describe("user required on every fetch", () => {
		it("throws when the response is missing the user field on fetchOrdererToken", async () => {
			fetchSpy.mockResolvedValueOnce(makeOkResponse({ user: undefined }));
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await expect(
				provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID),
			).rejects.toThrow("missing required 'user' field");
		});

		it("clears resolvedUser when a refresh response is missing the user field", async () => {
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID);
			expect(provider.resolvedUser).toEqual(mockUser);

			fetchSpy.mockResolvedValueOnce(makeOkResponse({ user: undefined }));
			await expect(
				provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID, true),
			).rejects.toThrow("missing required 'user' field");
			expect(provider.resolvedUser).toBeUndefined();
		});

		it("resolveUser throws (not stale data) when refresh response is missing user", async () => {
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await provider.resolveUser(TENANT_ID);

			fetchSpy.mockResolvedValueOnce(makeOkResponse({ user: undefined }));
			await expect(provider.resolveUser(TENANT_ID)).rejects.toThrow(
				"missing required 'user' field",
			);
		});
	});

	describe("expiresIn validation", () => {
		it("throws when expiresIn is missing from the response", async () => {
			fetchSpy.mockResolvedValueOnce(makeOkResponse({ expiresIn: undefined }));
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await expect(
				provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID),
			).rejects.toThrow("'expiresIn' must be a finite positive number");
		});

		it("throws when expiresIn is a string", async () => {
			fetchSpy.mockResolvedValueOnce(
				makeRawOkResponse({
					jwt: "t",
					expiresIn: "3600",
					user: mockUser,
				}),
			);
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await expect(
				provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID),
			).rejects.toThrow("'expiresIn' must be a finite positive number");
		});

		it("throws when expiresIn is zero", async () => {
			fetchSpy.mockResolvedValueOnce(
				makeRawOkResponse({ jwt: "t", expiresIn: 0, user: mockUser }),
			);
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await expect(
				provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID),
			).rejects.toThrow("'expiresIn' must be a finite positive number");
		});

		it("throws when expiresIn is negative", async () => {
			fetchSpy.mockResolvedValueOnce(
				makeRawOkResponse({ jwt: "t", expiresIn: -60, user: mockUser }),
			);
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await expect(
				provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID),
			).rejects.toThrow("'expiresIn' must be a finite positive number");
		});

		it("throws when expiresIn is null (covers NaN/Infinity after JSON round-trip)", async () => {
			fetchSpy.mockResolvedValueOnce(
				makeRawOkResponse({ jwt: "t", expiresIn: null, user: mockUser }),
			);
			const provider = new RemoteFloodgateTokenProvider(ENDPOINT, CREDENTIAL);
			await expect(
				provider.fetchOrdererToken(TENANT_ID, DOCUMENT_ID),
			).rejects.toThrow("'expiresIn' must be a finite positive number");
		});
	});
});
