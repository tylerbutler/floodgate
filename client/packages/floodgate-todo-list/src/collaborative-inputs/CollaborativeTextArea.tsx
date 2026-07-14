import {
	type CSSProperties,
	type FC,
	type FormEvent,
	useCallback,
	useEffect,
	useRef,
	useState,
} from "react";

import type {
	ISharedStringHelperTextChangedEventArgs,
	SharedStringHelper,
} from "./SharedStringHelper.js";

/**
 * {@link CollaborativeTextArea} input props.
 */
export interface ICollaborativeTextAreaProps {
	/**
	 * The SharedStringHelper that will store the text from the textarea.
	 */
	sharedStringHelper: SharedStringHelper;

	/**
	 * Whether or not the control should be read-only.
	 * @defaultValue `false`
	 */
	readOnly?: boolean;

	/**
	 * Whether `spellCheck` should be enabled.
	 * @defaultValue `false`
	 */
	spellCheck?: boolean;

	className?: string;
	style?: CSSProperties;
}

/**
 * Given a SharedStringHelper, produces a collaborative text area element.
 */
export const CollaborativeTextArea: FC<ICollaborativeTextAreaProps> = (
	props: ICollaborativeTextAreaProps,
) => {
	const { sharedStringHelper, readOnly, spellCheck, className, style } = props;
	const textareaRef = useRef<HTMLTextAreaElement>(null);
	const selectionStartRef = useRef<number>(0);
	const selectionEndRef = useRef<number>(0);

	const [text, setText] = useState<string>(sharedStringHelper.getText());

	const setTextareaSelection = useCallback(
		(newStart: number, newEnd: number): void => {
			if (!textareaRef.current) {
				throw new Error(
					"Trying to set selection without current textarea ref?",
				);
			}
			const textareaElement = textareaRef.current;
			textareaElement.selectionStart = newStart;
			textareaElement.selectionEnd = newEnd;
		},
		[],
	);

	const storeSelectionInReact = useCallback((): void => {
		if (!textareaRef.current) {
			throw new Error(
				"Trying to remember selection without current textarea ref?",
			);
		}
		const textareaElement = textareaRef.current;
		selectionStartRef.current = textareaElement.selectionStart;
		selectionEndRef.current = textareaElement.selectionEnd;
	}, []);

	const handleChange = (_ev: FormEvent<HTMLTextAreaElement>): void => {
		if (!textareaRef.current) {
			throw new Error("Handling change without current textarea ref?");
		}
		const textareaElement = textareaRef.current;
		const newText = textareaElement.value;
		const newCaretPosition = textareaElement.selectionStart;

		const oldText = text;
		const oldSelectionStart = selectionStartRef.current;
		const oldSelectionEnd = selectionEndRef.current;

		storeSelectionInReact();
		setText(newText);

		const isTextInserted = newCaretPosition - oldSelectionStart > 0;
		if (isTextInserted) {
			const insertedText = newText.slice(oldSelectionStart, newCaretPosition);
			const isTextReplaced = oldSelectionEnd - oldSelectionStart > 0;
			if (isTextReplaced) {
				sharedStringHelper.replaceText(
					insertedText,
					oldSelectionStart,
					oldSelectionEnd,
				);
			} else {
				sharedStringHelper.insertText(insertedText, oldSelectionStart);
			}
		} else {
			const charactersDeleted = oldText.length - newText.length;
			sharedStringHelper.removeText(
				newCaretPosition,
				newCaretPosition + charactersDeleted,
			);
		}
	};

	useEffect(() => {
		const handleTextChanged = (
			event: ISharedStringHelperTextChangedEventArgs,
		): void => {
			const newText = sharedStringHelper.getText();
			setText(newText);

			if (!event.isLocal) {
				const newSelectionStart = event.transformPosition(
					selectionStartRef.current,
				);
				const newSelectionEnd = event.transformPosition(
					selectionEndRef.current,
				);
				setTextareaSelection(newSelectionStart, newSelectionEnd);
				storeSelectionInReact();
			}
		};

		sharedStringHelper.on("textChanged", handleTextChanged);
		return () => {
			sharedStringHelper.off("textChanged", handleTextChanged);
		};
	}, [sharedStringHelper, setTextareaSelection, storeSelectionInReact]);

	return (
		<textarea
			rows={20}
			cols={50}
			ref={textareaRef}
			className={className}
			style={style}
			spellCheck={spellCheck ?? false}
			readOnly={readOnly ?? false}
			onBeforeInput={storeSelectionInReact}
			onKeyDown={storeSelectionInReact}
			onClick={storeSelectionInReact}
			onContextMenu={storeSelectionInReact}
			onChange={handleChange}
			value={text}
		/>
	);
};
