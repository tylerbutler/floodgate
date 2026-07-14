/**
 * Todo session lifecycle utilities.
 *
 * Provides the typed Fluid container schema and the core create/load logic in
 * a form that is independently testable without DOM or React.
 */

import type { FloodgateClient } from "@tylerbu/floodgate-client";
import type { IFluidContainer } from "fluid-framework";
import type { FloodgateTodoListConfig } from "./config.js";
import {
	initializeAppForNewContainer,
	loadAppFromExistingContainer,
	type TodoListContainerSchema,
	todoListContainerSchema,
} from "./fluid.js";
import type { TodoList } from "./schema.js";

/**
 * Result of {@link createTodoSession}: the live todo state plus cleanup.
 */
export interface TodoSession {
	/** The collaborative todo list root. */
	readonly todoList: TodoList;
	/** The underlying Fluid container (needed for dynamic SharedString creation). */
	readonly container: IFluidContainer<TodoListContainerSchema>;
	/** The Fluid document ID (server-assigned on create, or the supplied ID on load). */
	readonly documentId: string;
	/** Disposes the Fluid container. Call this during unmount. */
	dispose: () => void;
}

/**
 * Creates or loads a Fluid container and returns a {@link TodoSession}.
 *
 * @param client - An already-constructed {@link FloodgateClient}.
 * @param config - Subset of {@link FloodgateTodoListConfig}. When
 *   `documentId` is provided the container is loaded; otherwise a new one is
 *   created, initialized with default todo items, and attached.
 */
export async function createTodoSession(
	client: FloodgateClient,
	config: Pick<FloodgateTodoListConfig, "documentId">,
): Promise<TodoSession> {
	if (config.documentId) {
		const { container } = await client.getContainer(
			config.documentId,
			todoListContainerSchema,
			"2",
		);
		const todoList = loadAppFromExistingContainer(container);
		return {
			todoList,
			container,
			documentId: config.documentId,
			dispose: () => container.dispose(),
		};
	}

	const { container } = await client.createContainer(
		todoListContainerSchema,
		"2",
	);
	// Initialize before attaching so all initial data is present from the first op.
	const todoList = await initializeAppForNewContainer(container);
	// The server assigns the canonical document ID; capture it here.
	const documentId = await container.attach();
	return {
		todoList,
		container,
		documentId,
		dispose: () => container.dispose(),
	};
}
