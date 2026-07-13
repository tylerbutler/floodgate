/**
 * Sandbag-compatible mount function for the Floodgate DiceRoller.
 */

import { createElement } from "react";
import { createRoot, type Root } from "react-dom/client";

import {
	createFloodgateClient,
	type FloodgateExampleConfig,
} from "./config.js";
import { DiceRollerView } from "./diceRoller.js";
import { createDiceSession } from "./session.js";

/**
 * Configuration accepted by {@link mount}.
 */
export type MountConfig = FloodgateExampleConfig;

/**
 * Mounts the Floodgate DiceRoller into `element`.
 *
 * @param element - DOM element to render into.
 * @param config - Connection configuration. When `documentId` is omitted, a
 *   new document is created and its server-assigned ID is returned. When
 *   provided, the existing document is loaded.
 * @returns An object with `unmount` (disposes the container and removes the
 *   React root) and `documentId` (the server-assigned or loaded document ID).
 */
export async function mount(
	element: HTMLElement,
	config: MountConfig = {},
): Promise<{ unmount: () => void; documentId: string }> {
	const floodgateClient = await createFloodgateClient(config);
	const session = await createDiceSession(floodgateClient, config);

	const root: Root = createRoot(element);
	root.render(createElement(DiceRollerView, { diceMap: session.diceMap }));

	return {
		unmount: () => {
			root.unmount();
			session.dispose();
		},
		documentId: session.documentId,
	};
}
