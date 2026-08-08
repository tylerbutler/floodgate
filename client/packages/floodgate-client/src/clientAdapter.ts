import type { IRequest } from "@fluidframework/core-interfaces";
import type {
	IResolvedUrl,
	IUrlResolver,
} from "@fluidframework/driver-definitions/internal";
import type { ITokenProvider } from "@fluidframework/routerlicious-driver";
import { RouterliciousDocumentServiceFactory } from "@fluidframework/routerlicious-driver/internal";

const DEFAULT_TENANT_ID = "fluid";
const TRAILING_SLASH = /\/+$/;

export interface FloodgateConnectionConfig {
	readonly httpUrl: string;
	readonly socketUrl?: string;
	readonly tenantId?: string;
	readonly tokenProvider: ITokenProvider;
}

export interface FloodgateDriverPolicies {
	readonly enableDiscovery?: boolean;
	readonly enableLongPollingDowngrade?: boolean;
	readonly enableRestLess?: boolean;
}

export interface FloodgateClientAdapter {
	readonly documentServiceFactory: RouterliciousDocumentServiceFactory;
	readonly urlResolver: FloodgateUrlResolver;
	createResolvedUrl(documentId: string): IResolvedUrl;
}

export class FloodgateUrlResolver implements IUrlResolver {
	private readonly connection: Omit<FloodgateConnectionConfig, "tokenProvider">;

	public constructor(
		connection: Omit<FloodgateConnectionConfig, "tokenProvider">,
	) {
		this.connection = connection;
	}

	public async resolve(request: IRequest): Promise<IResolvedUrl> {
		return createFloodgateResolvedUrl(
			this.connection,
			this.documentIdFromUrl(request.url),
		);
	}

	public async getAbsoluteUrl(
		resolvedUrl: IResolvedUrl,
		relativeUrl: string,
	): Promise<string> {
		return relativeUrl.length > 0
			? `${resolvedUrl.url.replace(TRAILING_SLASH, "")}/${relativeUrl}`
			: resolvedUrl.url;
	}

	public createCreateNewRequest(): IRequest {
		const httpUrl = normalizeBaseUrl(this.connection.httpUrl, "httpUrl");
		const tenantId = this.connection.tenantId ?? DEFAULT_TENANT_ID;
		return { url: `${httpUrl}/${tenantId}/new` };
	}

	public createRequestForDocument(documentId: string): IRequest {
		const resolvedUrl = createFloodgateResolvedUrl(this.connection, documentId);
		return { url: resolvedUrl.url };
	}

	private documentIdFromUrl(value: string): string {
		if (!(value.includes("/") || value.includes(":"))) {
			return value;
		}

		const path =
			value.startsWith("http://") || value.startsWith("https://")
				? new URL(value).pathname
				: value;
		const segments = path.split("/").filter((segment) => segment.length > 0);
		const documentId = segments.at(-1);
		if (documentId === undefined || documentId.length === 0) {
			throw new Error(`Unable to resolve Floodgate document URL: ${value}`);
		}
		return documentId;
	}
}

export function createFloodgateResolvedUrl(
	connection: Omit<FloodgateConnectionConfig, "tokenProvider">,
	documentId: string,
): IResolvedUrl {
	const httpUrl = normalizeBaseUrl(connection.httpUrl, "httpUrl");
	const socketUrl = normalizeBaseUrl(
		connection.socketUrl ?? httpUrl,
		"socketUrl",
	);
	const tenantId = connection.tenantId ?? DEFAULT_TENANT_ID;

	if (tenantId.length === 0) {
		throw new Error("Floodgate tenantId must not be empty");
	}

	return {
		type: "fluid",
		id: documentId,
		url: `${httpUrl}/${tenantId}/${documentId}`,
		tokens: {},
		endpoints: {
			ordererUrl: httpUrl,
			deltaStorageUrl: `${httpUrl}/documents/${tenantId}/${documentId}/deltas`,
			deltaStreamUrl: socketUrl,
			storageUrl: `${httpUrl}/repos/${tenantId}`,
		},
	};
}

/**
 * Resolves the driver policies Floodgate actually supports.
 *
 * Only the keys named in {@link FloodgateDriverPolicies} are read. Spreading the
 * caller's object here would let a widened (non-literal) argument slip past
 * excess-property checking and set policies Floodgate cannot serve — notably
 * `enableWholeSummaryUpload`, which routes storage through
 * `GET|POST|DELETE /repos/:tenantId/git/summaries`. Floodgate's router only
 * whitelists `blobs|trees|commits|refs`, so those requests 404.
 */
export function resolveFloodgateDriverPolicies(
	policies: FloodgateDriverPolicies = {},
): Required<FloodgateDriverPolicies> & { enableWholeSummaryUpload: false } {
	return {
		enableDiscovery: policies.enableDiscovery ?? false,
		enableLongPollingDowngrade: policies.enableLongPollingDowngrade ?? false,
		enableRestLess: policies.enableRestLess ?? true,
		enableWholeSummaryUpload: false,
	};
}

export function createFloodgateDocumentServiceFactory(
	tokenProvider: ITokenProvider,
	policies: FloodgateDriverPolicies = {},
): RouterliciousDocumentServiceFactory {
	return new RouterliciousDocumentServiceFactory(
		tokenProvider,
		resolveFloodgateDriverPolicies(policies),
	);
}

export function createFloodgateClientAdapter(
	connection: FloodgateConnectionConfig,
	policies?: FloodgateDriverPolicies,
): FloodgateClientAdapter {
	const { tokenProvider, ...resolvedUrlConfig } = connection;
	const urlResolver = new FloodgateUrlResolver(resolvedUrlConfig);

	return {
		documentServiceFactory: createFloodgateDocumentServiceFactory(
			tokenProvider,
			policies,
		),
		urlResolver,
		createResolvedUrl: (documentId) =>
			createFloodgateResolvedUrl(resolvedUrlConfig, documentId),
	};
}

function normalizeBaseUrl(value: string, field: string): string {
	const normalized = value.trim().replace(TRAILING_SLASH, "");

	if (normalized.length === 0) {
		throw new Error(`Floodgate ${field} must not be empty`);
	}

	return normalized;
}
