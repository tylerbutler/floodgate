/**
 * Sandbag-compatible mount function for the Floodgate Todo List.
 */

import { createElement } from "react";
import { createRoot, type Root } from "react-dom/client";

import {
	createFloodgateClient,
	type FloodgateTodoListConfig,
} from "./config.js";
import { createTodoSession } from "./session.js";
import { TodoListAppView } from "./view.js";

/**
 * Configuration accepted by {@link mount}.
 */
export type MountConfig = FloodgateTodoListConfig;

/**
 * Mounts the Floodgate Todo List into `element`.
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
	const session = await createTodoSession(floodgateClient, config);

	const root: Root = createRoot(element);
	root.render(
		createElement(TodoListAppView, {
			todoList: session.todoList,
			container: session.container,
		}),
	);

	return {
		unmount: () => {
			root.unmount();
			session.dispose();
		},
		documentId: session.documentId,
	};
}
