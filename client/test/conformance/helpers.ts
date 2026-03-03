/**
 * Shared helpers for levee-driver integration tests.
 *
 * Provides server configuration, availability checking, unique document IDs,
 * and authenticated HTTP request helpers.
 */

import { SignJWT } from "jose";
import { v4 as uuid } from "uuid";
import type { LeveeUser } from "../../src/contracts.js";
import { LeveeDocumentServiceFactory } from "../../src/leveeDocumentServiceFactory.js";
import { InsecureLeveeTokenProvider } from "../../src/tokenProvider.js";
import { LeveeUrlResolver } from "../../src/urlResolver.js";

// biome-ignore lint/style/noProcessEnv: test configuration from environment
export const LEVEE_HTTP_URL =
	process.env["LEVEE_HTTP_URL"] ?? "http://localhost:4000";
// biome-ignore lint/style/noProcessEnv: test configuration from environment
export const LEVEE_SOCKET_URL =
	process.env["LEVEE_SOCKET_URL"] ?? "ws://localhost:4000/socket";
// biome-ignore lint/style/noProcessEnv: test configuration from environment
export const LEVEE_TENANT_KEY =
	process.env["LEVEE_TENANT_KEY"] ?? "dev-tenant-secret-key";
// biome-ignore lint/style/noProcessEnv: test configuration from environment
export const LEVEE_DEBUG =
	// biome-ignore lint/style/noProcessEnv: test configuration from environment
	process.env["LEVEE_DEBUG"] === "true" || process.env["LEVEE_DEBUG"] === "1";
export const LEVEE_TENANT_ID = "fluid";

export const TEST_USER: LeveeUser = {
	id: "integration-test-user",
	name: "Integration Test",
};

/**
 * Check if the Levee server is reachable. Result is cached for the process lifetime.
 */
let _serverAvailable: boolean | undefined;
export async function isServerRunning(): Promise<boolean> {
	if (_serverAvailable !== undefined) {
		return _serverAvailable;
	}
	try {
		const controller = new AbortController();
		const timeout = setTimeout(() => controller.abort(), 2000);
		const response = await fetch(`${LEVEE_HTTP_URL}/health`, {
			signal: controller.signal,
		});
		clearTimeout(timeout);
		_serverAvailable = response.ok;
	} catch {
		_serverAvailable = false;
	}

	if (!_serverAvailable) {
		console.log(
			"\n⚠️  Levee server not running. Integration tests will be skipped.",
		);
		console.log("   Start the server with: docker compose up -d");
		console.log(`   Expected server at: ${LEVEE_HTTP_URL}\n`);
	}

	return _serverAvailable;
}

/**
 * Generate a unique document ID for test isolation.
 */
export function uniqueDocId(prefix = "test"): string {
	return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

/**
 * Create a configured token provider for tests.
 */
export function createTestTokenProvider(
	user: LeveeUser = TEST_USER,
): InsecureLeveeTokenProvider {
	return new InsecureLeveeTokenProvider(LEVEE_TENANT_KEY, user);
}

/**
 * Create a configured URL resolver for tests.
 */
export function createTestUrlResolver(): LeveeUrlResolver {
	return new LeveeUrlResolver(LEVEE_SOCKET_URL, LEVEE_HTTP_URL);
}

/**
 * Create a configured document service factory for tests.
 */
export function createTestFactory(
	user: LeveeUser = TEST_USER,
): LeveeDocumentServiceFactory {
	const tokenProvider = createTestTokenProvider(user);
	return new LeveeDocumentServiceFactory(tokenProvider, LEVEE_DEBUG);
}

/**
 * Generate a signed JWT for making authenticated HTTP requests in tests.
 */
export async function generateTestToken(
	documentId = "",
	scopes: string[] = ["doc:read", "doc:write", "summary:write"],
	tenantId: string = LEVEE_TENANT_ID,
): Promise<string> {
	const now = Math.floor(Date.now() / 1000);
	const secret = new TextEncoder().encode(LEVEE_TENANT_KEY);

	return new SignJWT({
		documentId,
		tenantId,
		scopes,
		user: TEST_USER,
		ver: "1.0",
		jti: uuid(),
	})
		.setProtectedHeader({ alg: "HS256" })
		.setIssuedAt(now)
		.setExpirationTime(now + 3600)
		.sign(secret);
}

/**
 * Make an authenticated HTTP request to the Levee server.
 */
export async function authenticatedFetch(
	path: string,
	options: {
		method?: string;
		body?: unknown;
		documentId?: string;
		scopes?: string[];
		tenantId?: string;
		token?: string;
	} = {},
): Promise<Response> {
	const token =
		options.token ??
		(await generateTestToken(
			options.documentId ?? "",
			options.scopes,
			options.tenantId,
		));

	const headers: Record<string, string> = {
		Authorization: `Bearer ${token}`,
	};

	let body: string | undefined;
	if (options.body !== undefined) {
		headers["Content-Type"] = "application/json";
		body = JSON.stringify(options.body);
	}

	return fetch(`${LEVEE_HTTP_URL}${path}`, {
		method: options.method ?? "GET",
		headers,
		body,
	});
}
