import {
	FloodgateClient,
	RemoteFloodgateTokenProvider,
} from "@tylerbu/floodgate-client";

/** Development-only credential matching the local Floodgate server. */
export const DEV_ONLY_MINT_CREDENTIAL = "floodgate-example-mint-secret";

const DEFAULT_HTTP_URL = "http://localhost:3000";
const DEFAULT_TENANT_ID = "fluid";

/** Connection options for the Floodgate Presence demo. */
export interface FloodgatePresenceConfig {
	httpUrl?: string;
	socketUrl?: string;
	tenantId?: string;
	/**
	 * Credential exchanged at the token-mint endpoint.
	 * The default is for local development only and must not be used in production.
	 */
	mintCredential?: string;
	/** Existing Fluid document ID to load. A new document is created when omitted. */
	documentId?: string;
}

/** Fully resolved Presence demo configuration. */
export interface ResolvedConfig {
	httpUrl: string;
	socketUrl: string | undefined;
	tenantId: string;
	mintCredential: string;
	documentId: string | undefined;
}

export function resolveConfig(
	config: FloodgatePresenceConfig = {},
): ResolvedConfig {
	return {
		httpUrl: config.httpUrl ?? DEFAULT_HTTP_URL,
		socketUrl: config.socketUrl,
		tenantId: config.tenantId ?? DEFAULT_TENANT_ID,
		mintCredential: config.mintCredential ?? DEV_ONLY_MINT_CREDENTIAL,
		documentId: config.documentId,
	};
}

export function buildTokenEndpoint(httpUrl: string, tenantId: string): string {
	return `${httpUrl.replace(/\/+$/, "")}/api/tenants/${tenantId}/token-mint`;
}

/** Creates an authenticated client using Floodgate's remote token-mint flow. */
export async function createFloodgateClient(
	config: FloodgatePresenceConfig = {},
): Promise<FloodgateClient> {
	const resolved = resolveConfig(config);
	const tokenProvider = new RemoteFloodgateTokenProvider(
		buildTokenEndpoint(resolved.httpUrl, resolved.tenantId),
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
