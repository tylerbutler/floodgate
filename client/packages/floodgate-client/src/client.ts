import { AttachState } from "@fluidframework/container-definitions";
import type {
	IContainer,
	IFluidModuleWithDetails,
} from "@fluidframework/container-definitions/internal";
import {
	createDetachedContainer,
	type ILoaderProps,
	loadExistingContainer,
} from "@fluidframework/container-loader/internal";
import type {
	ConfigTypes,
	ITelemetryBaseLogger,
} from "@fluidframework/core-interfaces";
import type { IClient, IUser } from "@fluidframework/driver-definitions";
import type {
	CompatibilityMode,
	ContainerSchema,
	IFluidContainer,
	IMember,
	IServiceAudience,
} from "@fluidframework/fluid-static";
import {
	createDOProviderContainerRuntimeFactory,
	createFluidContainer,
	createServiceAudience,
} from "@fluidframework/fluid-static/internal";
import type { ITokenProvider } from "@fluidframework/routerlicious-driver";
import { wrapConfigProviderWithDefaults } from "@fluidframework/telemetry-utils/internal";

import {
	createFloodgateClientAdapter,
	type FloodgateConnectionConfig,
	type FloodgateDriverPolicies,
} from "./clientAdapter.js";

export interface FloodgateUser extends IUser {
	readonly name: string;
}

export interface FloodgateMember extends IMember {
	readonly name: string;
}

export interface FloodgateContainerServices {
	readonly audience: IServiceAudience<FloodgateMember>;
}

export interface FloodgateClientConnectionConfig
	extends Omit<FloodgateConnectionConfig, "tokenProvider"> {
	readonly tokenProvider: ITokenProvider;
	readonly user: FloodgateUser;
}

export interface FloodgateClientProps {
	readonly connection: FloodgateClientConnectionConfig;
	readonly logger?: ITelemetryBaseLogger;
	readonly driverPolicies?: FloodgateDriverPolicies;
}

export class FloodgateClient {
	private readonly adapter: ReturnType<typeof createFloodgateClientAdapter>;
	private readonly logger: ITelemetryBaseLogger | undefined;
	private readonly user: FloodgateUser;

	public constructor(properties: FloodgateClientProps) {
		const { user, ...connection } = properties.connection;
		this.adapter = createFloodgateClientAdapter(
			connection,
			properties.driverPolicies,
		);
		this.logger = properties.logger;
		this.user = user;
	}

	public async createContainer<TContainerSchema extends ContainerSchema>(
		containerSchema: TContainerSchema,
		compatibilityMode: CompatibilityMode,
	): Promise<{
		container: IFluidContainer<TContainerSchema>;
		services: FloodgateContainerServices;
	}> {
		const container = await createDetachedContainer({
			...this.getLoaderProps(containerSchema, compatibilityMode),
			codeDetails: {
				package: "no-dynamic-package",
				config: {},
			},
		});

		const attach = async (): Promise<string> => {
			if (container.attachState !== AttachState.Detached) {
				throw new Error(
					"Cannot attach container. Container is not in detached state.",
				);
			}
			await container.attach(this.adapter.urlResolver.createCreateNewRequest());
			if (container.resolvedUrl === undefined) {
				throw new Error("Resolved URL not available on attached container");
			}
			return container.resolvedUrl.id;
		};

		const fluidContainer = await createFluidContainer<TContainerSchema>({
			container,
		});
		fluidContainer.attach = attach;
		return {
			container: fluidContainer,
			services: this.getContainerServices(container),
		};
	}

	public async getContainer<TContainerSchema extends ContainerSchema>(
		id: string,
		containerSchema: TContainerSchema,
		compatibilityMode: CompatibilityMode,
	): Promise<{
		container: IFluidContainer<TContainerSchema>;
		services: FloodgateContainerServices;
	}> {
		const container = await loadExistingContainer({
			...this.getLoaderProps(containerSchema, compatibilityMode),
			request: this.adapter.urlResolver.createRequestForDocument(id),
		});
		return {
			container: await createFluidContainer<TContainerSchema>({ container }),
			services: this.getContainerServices(container),
		};
	}

	private getContainerServices(
		container: IContainer,
	): FloodgateContainerServices {
		return {
			audience: createServiceAudience({
				container,
				createServiceMember: createFloodgateAudienceMember,
			}),
		};
	}

	private getLoaderProps(
		schema: ContainerSchema,
		compatibilityMode: CompatibilityMode,
	): ILoaderProps {
		const containerRuntimeFactory = createDOProviderContainerRuntimeFactory({
			schema,
			compatibilityMode,
		});
		const load = async (): Promise<IFluidModuleWithDetails> => ({
			module: { fluidExport: containerRuntimeFactory },
			details: { package: "no-dynamic-package", config: {} },
		});
		const client: IClient = {
			details: {
				capabilities: { interactive: true },
				environment: "floodgate-client",
			},
			permission: [],
			scopes: [],
			user: this.user,
			mode: "write",
		};
		const featureGates: Record<string, ConfigTypes> = {
			"Fluid.Container.ForceWriteConnection": true,
		};

		return {
			urlResolver: this.adapter.urlResolver,
			documentServiceFactory: this.adapter.documentServiceFactory,
			codeLoader: { load },
			logger: this.logger,
			options: { client },
			configProvider: wrapConfigProviderWithDefaults(undefined, featureGates),
		};
	}
}

function createFloodgateAudienceMember(client: IClient): FloodgateMember {
	const user = client.user as Partial<FloodgateUser>;
	if (typeof user.id !== "string" || typeof user.name !== "string") {
		throw new Error('Specified user was not of type "FloodgateUser".');
	}
	return {
		id: user.id,
		name: user.name,
		connections: [],
	};
}
