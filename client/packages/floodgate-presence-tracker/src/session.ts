import { SharedMap } from "@fluidframework/map/legacy";
import {
	getPresenceAlpha,
	type PresenceWithNotifications,
} from "@fluidframework/presence/alpha";
import type {
	FloodgateClient,
	FloodgateContainerServices,
} from "@tylerbu/floodgate-client";
import {
	ConnectionState,
	type ContainerSchema,
	type IFluidContainer,
} from "fluid-framework";

import type { FloodgatePresenceConfig } from "./config.js";
import { PresenceTracker } from "./presenceTracker.js";

/** A SharedMap placeholder keeps persisted and ephemeral state clearly separate. */
const _presenceContainerSchema = {
	initialObjects: {
		metadata: SharedMap,
	},
} as const satisfies ContainerSchema;

/** Public schema used to create and load Presence demo containers. */
export const presenceContainerSchema: ContainerSchema =
	_presenceContainerSchema;

export type PresenceContainerSchema = ContainerSchema;

export interface PresenceSession {
	readonly container: IFluidContainer<PresenceContainerSchema>;
	readonly documentId: string;
	readonly services: FloodgateContainerServices;
	readonly tracker: PresenceTracker;
	dispose: () => void;
}

async function waitForConnectedClient(
	container: IFluidContainer<PresenceContainerSchema>,
	services: FloodgateContainerServices,
): Promise<void> {
	const connected = (): boolean =>
		container.connectionState === ConnectionState.Connected &&
		services.audience.getMyself() !== undefined;
	if (connected()) {
		return;
	}
	await new Promise<void>((resolve, reject) => {
		const cleanup = (): void => {
			container.off("connected", onConnectionChanged);
			services.audience.off("membersChanged", onConnectionChanged);
		};
		const onConnectionChanged = (): void => {
			if (connected()) {
				clearTimeout(timeout);
				cleanup();
				resolve();
			}
		};
		const timeout = setTimeout(() => {
			cleanup();
			reject(new Error("Timed out waiting for the Fluid container to connect"));
		}, 10_000);
		container.on("connected", onConnectionChanged);
		services.audience.on("membersChanged", onConnectionChanged);
	});
}

/** Creates or loads a Floodgate container and initializes Fluid Presence. */
export async function createPresenceSession(
	client: FloodgateClient,
	config: Pick<FloodgatePresenceConfig, "documentId">,
): Promise<PresenceSession> {
	const { container, services } = config.documentId
		? await client.getContainer(
				config.documentId,
				_presenceContainerSchema,
				"2",
			)
		: await client.createContainer(_presenceContainerSchema, "2");

	try {
		// Start Presence while detached so it observes this client's first
		// audience join during attach.
		const presence: PresenceWithNotifications = getPresenceAlpha(container);
		// The map is deliberately not populated: Presence data is not persisted.
		const documentId = config.documentId ?? (await container.attach());

		// Presence needs the current connection ID when its system workspace starts.
		// Floodgate container creation can resolve just before audience connectivity.
		await waitForConnectedClient(container, services);
		const tracker = new PresenceTracker(presence);
		let disposed = false;

		return {
			container,
			documentId,
			services,
			tracker,
			dispose: () => {
				if (!disposed) {
					disposed = true;
					tracker.dispose();
					container.dispose();
				}
			},
		};
	} catch (error) {
		container.dispose();
		throw error;
	}
}
