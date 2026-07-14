/**
 * Configuration types and helpers for the Floodgate Todo List example.
 */

import {
	FloodgateClient,
	RemoteFloodgateTokenProvider,
} from "@tylerbu/floodgate-client";

/**
 * Default token mint credential for local development.
 *
 * @remarks
 * **⚠️ DEV-ONLY.** Matches `FLOODGATE_TOKEN_MINT_SECRET` on the local
 * Floodgate server. NEVER use this value in production.
 */
export const DEV_ONLY_MINT_CREDENTIAL = "floodgate-example-mint-secret";

const DEFAULT_HTTP_URL = "http://localhost:3000";
const DEFAULT_TENANT_ID = "fluid";

/**
 * Configuration options for the Floodgate Todo List example.
 */
export interface FloodgateTodoListConfig {
	/** HTTP URL of the Floodgate server. Defaults to `http://localhost:3000`. */
	httpUrl?: string;
	/** Optional WebSocket URL. Falls back to httpUrl when omitted. */
	socketUrl?: string;
	/** Tenant ID. Defaults to `"fluid"`. */
	tenantId?: string;
	/**
	 * Token mint credential.
	 * Defaults to {@link DEV_ONLY_MINT_CREDENTIAL}.
	 * **⚠️ DEV-ONLY.** Never use the default in production.
	 */
	mintCredential?: string;
	/** Document ID to load. When omitted, a new document is created. */
	documentId?: string;
}

/**
 * Resolved configuration with all defaults applied.
 */
export interface ResolvedConfig {
	httpUrl: string;
	socketUrl: string | undefined;
	tenantId: string;
	mintCredential: string;
	documentId: string | undefined;
}

/**
 * Applies defaults to a partial config and returns a fully resolved config.
 */
export function resolveConfig(
	config: FloodgateTodoListConfig = {},
): ResolvedConfig {
	return {
		httpUrl: config.httpUrl ?? DEFAULT_HTTP_URL,
		socketUrl: config.socketUrl,
		tenantId: config.tenantId ?? DEFAULT_TENANT_ID,
		mintCredential: config.mintCredential ?? DEV_ONLY_MINT_CREDENTIAL,
		documentId: config.documentId,
	};
}

/**
 * Constructs the full token-mint endpoint URL.
 */
export function buildTokenEndpoint(httpUrl: string, tenantId: string): string {
	return `${httpUrl.replace(/\/+$/, "")}/api/tenants/${tenantId}/token-mint`;
}

/**
 * Creates a {@link FloodgateClient} by resolving user identity from the
 * token-mint endpoint.
 *
 * @remarks
 * Makes a network request to the Floodgate server to exchange the
 * `mintCredential` for a JWT and resolve the server-assigned user identity.
 */
export async function createFloodgateClient(
	config: FloodgateTodoListConfig = {},
): Promise<FloodgateClient> {
	const resolved = resolveConfig(config);
	const tokenEndpoint = buildTokenEndpoint(resolved.httpUrl, resolved.tenantId);
	const tokenProvider = new RemoteFloodgateTokenProvider(
		tokenEndpoint,
		resolved.mintCredential,
	);
	const user = await tokenProvider.resolveUser(resolved.tenantId);

	return new FloodgateClient({
		connection: {
			httpUrl: resolved.httpUrl,
			socketUrl: resolved.socketUrl,
			tenantId: resolved.tenantId,
			tokenProvider,
			user,
		},
	});
}
