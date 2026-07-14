import {
	type ContainerSchema,
	type IFluidContainer,
	SharedTree,
	TreeViewConfiguration,
} from "fluid-framework";
import { SharedString } from "fluid-framework/legacy";

import { TodoItem, TodoList } from "./schema.js";

/**
 * Schema for the Floodgate Todo List application.
 *
 * Uses a root `SharedTree` DDS plus dynamically-created `SharedString` DDSs
 * for collaborative text fields.
 */
export const todoListContainerSchema = {
	initialObjects: {
		tree: SharedTree,
	},
	dynamicObjectTypes: [SharedString],
} as const satisfies ContainerSchema;

/**
 * Container schema type for the Todo List application.
 */
export type TodoListContainerSchema = typeof todoListContainerSchema;

const treeViewConfig = new TreeViewConfiguration({
	schema: TodoList,
	enableSchemaValidation: true,
});

/**
 * Loads the application model from an existing Fluid Container.
 */
export function loadAppFromExistingContainer(
	container: IFluidContainer<TodoListContainerSchema>,
): TodoList {
	const tree = container.initialObjects.tree;
	const treeView = tree.viewWith(treeViewConfig);
	if (!treeView.compatibility.canView) {
		throw new Error("Expected container data to be compatible with app schema");
	}
	return treeView.root;
}

/**
 * Initializes the application model for a newly created Fluid Container.
 *
 * Populates the initial TodoList contents, then returns the live root.
 */
export async function initializeAppForNewContainer(
	container: IFluidContainer<TodoListContainerSchema>,
): Promise<TodoList> {
	const tree = container.initialObjects.tree;
	const treeView = tree.viewWith(treeViewConfig);
	if (!treeView.compatibility.canInitialize) {
		throw new Error(
			"Expected container data to be compatible with TodoList schema",
		);
	}

	const initialTodoList = await createInitialTodoList(container);
	treeView.initialize(initialTodoList);

	return treeView.root;
}

/**
 * Create the initial `TodoList` tree for the application.
 */
async function createInitialTodoList(
	container: IFluidContainer,
): Promise<TodoList> {
	const listTitle = await container.create(SharedString);
	listTitle.insertText(0, "My to-do list");

	const todoItem1 = await createTodoItem({
		container,
		completed: false,
		initialTitleText: "Buy groceries",
	});
	const todoItem2 = await createTodoItem({
		container,
		completed: true,
		initialTitleText: "Walk the dog",
	});

	return new TodoList({
		title: listTitle.handle,
		items: [todoItem1, todoItem2],
	});
}

/**
 * Creates a new {@link TodoItem} using the provided Fluid container to
 * generate `SharedString` DDSs for the item's title and description.
 */
export async function createTodoItem({
	container,
	completed,
	initialTitleText,
	initialDescriptionText,
}: {
	container: IFluidContainer;
	completed: boolean;
	initialTitleText?: string;
	initialDescriptionText?: string;
}): Promise<TodoItem> {
	const title = await container.create(SharedString);
	if (initialTitleText !== undefined) {
		title.insertText(0, initialTitleText);
	}
	const description = await container.create(SharedString);
	if (initialDescriptionText !== undefined) {
		description.insertText(0, initialDescriptionText);
	}
	return new TodoItem({
		title: title.handle,
		description: description.handle,
		completed,
	});
}
