import { useTree } from "@fluidframework/react/alpha";
import type { IFluidContainer, IFluidHandle } from "fluid-framework";
import type { ISharedString } from "fluid-framework/legacy";
import {
	type ChangeEvent,
	type FC,
	type FormEvent,
	useEffect,
	useRef,
	useState,
} from "react";

import {
	CollaborativeInput,
	CollaborativeTextArea,
	SharedStringHelper,
} from "./collaborative-inputs/index.js";
import { createTodoItem, type TodoListContainerSchema } from "./fluid.js";
import type { TodoItem, TodoList } from "./schema.js";

import "./style.css";

/**
 * {@link TodoListAppView} input props.
 */
export interface TodoListAppViewProps {
	readonly todoList: TodoList;
	readonly container: IFluidContainer<TodoListContainerSchema>;
}

/**
 * To-do list application view component.
 */
export const TodoListAppView: FC<TodoListAppViewProps> = (
	props: TodoListAppViewProps,
) => {
	const { todoList, container } = props;

	const [titleString, setTitleString] = useState<ISharedString | undefined>();

	const newItemTextInputRef = useRef<HTMLInputElement>(null);
	useTree(todoList);

	const todoListTitleHandle = todoList.title as IFluidHandle<ISharedString>;

	useEffect(() => {
		todoListTitleHandle
			.get()
			.then((title) => {
				setTitleString(title);
			})
			.catch((error) => {
				console.error("Failed to get to-do list title:", error);
				throw error;
			});
	}, [todoListTitleHandle]);

	if (titleString === undefined) {
		return <div>Loading...</div>;
	}

	const handleCreateClick = (ev: FormEvent<HTMLFormElement>): void => {
		ev.preventDefault();

		const input = newItemTextInputRef.current;
		if (input === null) {
			throw new Error("New item text field missing");
		}
		const valueToInsert = input.value;
		input.value = "";

		createTodoItem({
			container,
			initialTitleText: valueToInsert,
			completed: false,
		})
			.then((todoItem) => {
				todoList.items.insertAtEnd(todoItem);
			})
			.catch((error) => {
				console.error("Failed to create to-do item:", error);
				throw error;
			});
	};

	const todoItemViews = todoList.items.map((todoItem, index) => (
		<div className="item-wrap" key={todoItem.id}>
			<TodoItemView todoItem={todoItem} />
			<button
				className="action-button"
				onClick={() => {
					todoList.items.removeAt(index);
				}}
				type="button"
			>
				X
			</button>
		</div>
	));

	return (
		<div className="todo-view">
			<CollaborativeInput className="todo-title" sharedString={titleString} />
			<form className="new-item-form" onSubmit={handleCreateClick}>
				<input
					className="new-item-text"
					type="text"
					ref={newItemTextInputRef}
					name="itemName"
					placeholder="Add a new to-do item..."
				/>
				<button className="new-item-button" type="submit" name="createItem">
					+
				</button>
			</form>
			<div className="todo-item-list">{todoItemViews}</div>
		</div>
	);
};

/**
 * {@link TodoItemView} input props.
 */
interface TodoItemViewProps {
	readonly todoItem: TodoItem;
}

/**
 * To-do list item view component.
 */
const TodoItemView: FC<TodoItemViewProps> = (props: TodoItemViewProps) => {
	const { todoItem } = props;

	const [itemTitle, setItemTitle] = useState<ISharedString | undefined>(
		undefined,
	);
	const [itemDescription, setItemDescription] = useState<
		ISharedString | undefined
	>(undefined);
	const [detailsVisible, setDetailsVisible] = useState<boolean>(false);
	const [descriptionHelper, setDescriptionHelper] = useState<
		SharedStringHelper | undefined
	>(undefined);

	useTree(todoItem);

	const todoItemTitleHandle = todoItem.title as IFluidHandle<ISharedString>;
	useEffect(() => {
		todoItemTitleHandle
			.get()
			.then((text) => {
				setItemTitle(text);
			})
			.catch((error) => {
				console.error("Failed to get to-do item title:", error);
				throw error;
			});
	}, [todoItemTitleHandle]);

	const todoItemDescriptionHandle =
		todoItem.description as IFluidHandle<ISharedString>;
	useEffect(() => {
		todoItemDescriptionHandle
			.get()
			.then((text) => {
				setItemDescription(text);
			})
			.catch((error) => {
				console.error("Failed to get to-do item description:", error);
				throw error;
			});
	}, [todoItemDescriptionHandle]);

	// Create one SharedStringHelper per itemDescription instance and dispose it
	// on cleanup, so the sequenceDelta listener is never leaked across renders.
	useEffect(() => {
		if (itemDescription === undefined) return;
		const helper = new SharedStringHelper(itemDescription);
		setDescriptionHelper(helper);
		return () => {
			helper.dispose();
		};
	}, [itemDescription]);

	const checkChangedHandler = (e: ChangeEvent<HTMLInputElement>): void => {
		todoItem.completed = e.target.checked;
	};

	if (itemTitle === undefined || itemDescription === undefined) {
		return <div>Loading item...</div>;
	}

	return (
		<div className="todo-item">
			<h2 className="todo-item-header">
				<input
					type="checkbox"
					className="todo-item-checkbox"
					checked={todoItem.completed}
					onChange={checkChangedHandler}
				/>
				<button
					className="todo-item-expand-button"
					name="toggleDetailsVisible"
					onClick={() => {
						setDetailsVisible(!detailsVisible);
					}}
					type="button"
				>
					{detailsVisible ? "\u25B2" : "\u25BC"}
				</button>
				<CollaborativeInput
					sharedString={itemTitle}
					className="todo-item-input"
				/>
			</h2>
			{detailsVisible && descriptionHelper !== undefined && (
				<CollaborativeTextArea
					className="todo-item-details"
					sharedStringHelper={descriptionHelper}
				/>
			)}
		</div>
	);
};
