/**
 * Dice session lifecycle utilities.
 *
 * Provides the typed Fluid container schema and the core create/load logic in
 * a form that is independently testable without DOM or React.
 */

import type { ContainerSchema } from "@fluidframework/fluid-static";
import type { ISharedMap } from "@fluidframework/map/legacy";
import { SharedMap } from "@fluidframework/map/legacy";
import type { FloodgateClient } from "@tylerbu/floodgate-client";
import type { FloodgateExampleConfig } from "./config.js";
import { DICE_VALUE_KEY } from "./diceRoller.js";

/**
 * Fluid container schema for the DiceRoller — a single SharedMap.
 *
 * `_diceContainerSchema` uses `satisfies ContainerSchema` for precise
 * inference inside this module. The exported `diceContainerSchema` is typed
 * as `ContainerSchema` so declaration emit avoids unportable references into
 * pnpm's virtual store.
 */
const _diceContainerSchema = {
	initialObjects: { dice: SharedMap },
} satisfies ContainerSchema;

/** Typed container schema — pass to `FloodgateClient.createContainer/getContainer`. */
export const diceContainerSchema: ContainerSchema = _diceContainerSchema;

/** Result of {@link createDiceSession}: the live dice state plus cleanup. */
export interface DiceSession {
	/** The SharedMap storing the dice value. */
	readonly diceMap: ISharedMap;
	/** The Fluid document ID (server-assigned on create, or the supplied ID on load). */
	readonly documentId: string;
	/** Disposes the Fluid container. Call this during unmount. */
	dispose: () => void;
}

/**
 * Creates or loads a Fluid container and returns a {@link DiceSession}.
 *
 * @param client - An already-constructed {@link FloodgateClient}.
 * @param config - Subset of {@link FloodgateExampleConfig}. When
 *   `documentId` is provided the container is loaded; otherwise a new one is
 *   created, initialized with dice value 1, and attached.
 */
export async function createDiceSession(
	client: FloodgateClient,
	config: Pick<FloodgateExampleConfig, "documentId">,
): Promise<DiceSession> {
	if (config.documentId) {
		const { container } = await client.getContainer(
			config.documentId,
			_diceContainerSchema,
			"2",
		);
		// container.initialObjects.dice is ISharedMap — typed by _diceContainerSchema
		return {
			diceMap: container.initialObjects.dice,
			documentId: config.documentId,
			dispose: () => container.dispose(),
		};
	}

	const { container } = await client.createContainer(_diceContainerSchema, "2");
	const diceMap = container.initialObjects.dice;
	// Initialize before attaching so the value is present from the first op.
	diceMap.set(DICE_VALUE_KEY, 1);
	// The server assigns the canonical document ID; capture it here.
	const documentId = await container.attach();
	return {
		diceMap,
		documentId,
		dispose: () => container.dispose(),
	};
}
