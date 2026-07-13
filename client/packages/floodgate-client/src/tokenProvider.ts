/**
 * Token provider for Floodgate remote authentication.
 */

import type {
	ITokenProvider,
	ITokenResponse,
} from "@fluidframework/routerlicious-driver";

/**
 * User identity returned by the Floodgate token-mint endpoint.
 *
 * @public
 */
export interface FloodgateIdentity {
	readonly id: string;
	readonly name: string;
}

/**
 * Token provider that fetches JWTs from the Floodgate `POST /api/tenants/:tenant/token-mint` endpoint.
 *
 * @remarks
 * Caches tokens until one minute before server-reported expiry and honors the
 * Routerlicious `refresh` flag. After the first successful fetch the resolved
 * user identity is available via {@link RemoteFloodgateTokenProvider.resolvedUser}.
 *
 * @example
 * ```typescript
 * const tokenProvider = new RemoteFloodgateTokenProvider(
 *   "http://localhost:3000/api/tenants/fluid/token-mint",
 *   process.env.FLOODGATE_TOKEN_MINT_SECRET,
 * );
 * const user = await tokenProvider.resolveUser("fluid");
 * const client = new FloodgateClient({
 *   connection: { httpUrl: "http://localhost:3000", tenantId: "fluid", tokenProvider, user },
 * });
 * ```
 *
 * @public
 */
export class RemoteFloodgateTokenProvider implements ITokenProvider {
	private readonly tokenEndpoint: string;
	private readonly authCredential: string;
	private readonly cache = new Map<
		string,
		{ token: string; expiresAt: number }
	>();
	private _resolvedUser: FloodgateIdentity | undefined;

	/**
	 * @param tokenEndpoint - Full URL to the token-mint endpoint, e.g.
	 *   `http://localhost:3000/api/tenants/fluid/token-mint`
	 * @param authCredential - Bearer credential (`FLOODGATE_TOKEN_MINT_SECRET`)
	 */
	public constructor(tokenEndpoint: string, authCredential: string) {
		this.tokenEndpoint = tokenEndpoint;
		this.authCredential = authCredential;
	}

	/** Fetches a JWT for orderer operations. */
	public async fetchOrdererToken(
		tenantId: string,
		documentId?: string,
		refresh?: boolean,
	): Promise<ITokenResponse> {
		return this.fetchToken(tenantId, documentId ?? "", refresh);
	}

	/** Fetches a JWT for storage operations. */
	public async fetchStorageToken(
		tenantId: string,
		documentId: string,
		refresh?: boolean,
	): Promise<ITokenResponse> {
		return this.fetchToken(tenantId, documentId, refresh);
	}

	/** User identity returned by the server, available after the first successful fetch. */
	public get resolvedUser(): FloodgateIdentity | undefined {
		return this._resolvedUser;
	}

	/**
	 * Forces a token fetch and returns the server-resolved user identity.
	 * Call this before constructing {@link FloodgateClient} when user info is needed upfront.
	 *
	 * @param tenantId - The tenant ID
	 * @param documentId - Optional document ID included in the request body (defaults to `""`)
	 */
	public async resolveUser(
		tenantId: string,
		documentId = "",
	): Promise<FloodgateIdentity> {
		await this.fetchToken(tenantId, documentId, /* refresh */ true);
		// fetchToken always sets _resolvedUser on success (user is required); this is a safety net
		if (this._resolvedUser === undefined) {
			throw new Error(
				"Floodgate token-mint endpoint did not return user info. Ensure the server is up to date.",
			);
		}
		return this._resolvedUser;
	}

	private async fetchToken(
		tenantId: string,
		documentId: string,
		refresh?: boolean,
	): Promise<ITokenResponse> {
		const cacheKey = `${tenantId}:${documentId}`;

		if (!refresh) {
			const cached = this.cache.get(cacheKey);
			if (cached !== undefined && cached.expiresAt > Date.now()) {
				return { jwt: cached.token };
			}
		}

		const response = await fetch(this.tokenEndpoint, {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				Authorization: `Bearer ${this.authCredential}`,
			},
			body: JSON.stringify({ tenantId, documentId }),
		});

		if (!response.ok) {
			throw new Error(
				`Floodgate token-mint request failed: ${response.status} ${response.statusText}`,
			);
		}

		// Clear stale resolved identity before validating the new payload.
		// If any validation below throws, _resolvedUser remains undefined.
		this._resolvedUser = undefined;

		const data = (await response.json()) as Record<string, unknown>;

		if (typeof data["jwt"] !== "string") {
			throw new Error(
				"Floodgate token-mint response is missing required 'jwt' field.",
			);
		}

		// user is required on every successful response
		const rawUser = data["user"];
		if (rawUser === undefined || rawUser === null) {
			throw new Error(
				"Floodgate token-mint response is missing required 'user' field.",
			);
		}
		const u = rawUser as Partial<{ id: unknown; name: unknown }>;
		if (typeof u.id !== "string" || typeof u.name !== "string") {
			throw new Error(
				"Floodgate token-mint response 'user' field has unexpected shape.",
			);
		}
		const newUser: FloodgateIdentity = { id: u.id, name: u.name };

		// expiresIn must be a finite positive number
		const rawExpiresIn = data["expiresIn"];
		if (
			typeof rawExpiresIn !== "number" ||
			!Number.isFinite(rawExpiresIn) ||
			rawExpiresIn <= 0
		) {
			throw new Error(
				"Floodgate token-mint response 'expiresIn' must be a finite positive number.",
			);
		}

		// All validations passed — apply state atomically
		const jwt = data["jwt"];
		this._resolvedUser = newUser;
		this.cache.set(cacheKey, {
			token: jwt,
			expiresAt: Date.now() + rawExpiresIn * 1000 - 60_000,
		});

		return { jwt };
	}
}
