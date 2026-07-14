import { MergeTreeDeltaType } from "@fluidframework/merge-tree/legacy";
import type {
	SequenceDeltaEvent,
	SharedString,
} from "@fluidframework/sequence/legacy";

import { TypedEventEmitter } from "./TypedEventEmitter.js";

export interface ISharedStringHelperTextChangedEventArgs {
	/**
	 * Whether the change originated from the local client.
	 */
	isLocal: boolean;

	/**
	 * A callback function that translates pre-change positions in the sequence into
	 * post-change positions (e.g. to track caret position after remote changes).
	 */
	transformPosition: (oldPosition: number) => number;
}

interface ISharedStringHelperEvents {
	[key: string]: unknown[];
	textChanged: [ISharedStringHelperTextChangedEventArgs];
}

/**
 * Given a SharedString, provides a friendly API for use with collaborative text inputs.
 */
export class SharedStringHelper extends TypedEventEmitter<ISharedStringHelperEvents> {
	private readonly _sharedString: SharedString;
	private _latestText: string;

	constructor(sharedString: SharedString) {
		super();
		this._sharedString = sharedString;
		this._latestText = this._sharedString.getText();
		this._sharedString.on("sequenceDelta", this.sequenceDeltaHandler);
	}

	/**
	 * Gets the full text stored in the SharedString as a string.
	 */
	public getText(): string {
		return this._latestText;
	}

	/**
	 * Insert the string provided at the given position.
	 */
	public insertText(text: string, pos: number): void {
		this._sharedString.insertText(pos, text);
	}

	/**
	 * Remove the text within the given range.
	 */
	public removeText(start: number, end: number): void {
		this._sharedString.removeText(start, end);
	}

	/**
	 * Insert the string provided at the given start position, and remove the text that
	 * (prior to the insertion) is within the given range.
	 */
	public replaceText(text: string, start: number, end: number): void {
		this._sharedString.replaceText(start, end, text);
	}

	/**
	 * Detaches this helper from the underlying SharedString. Call when the owning
	 * component unmounts so the `sequenceDelta` listener is not leaked.
	 */
	public dispose(): void {
		this._sharedString.off("sequenceDelta", this.sequenceDeltaHandler);
	}

	/**
	 * Called when the data of the SharedString changes. Updates cached text and emits
	 * the "textChanged" event with a transformPosition function for caret tracking.
	 */
	private readonly sequenceDeltaHandler = (event: SequenceDeltaEvent): void => {
		this._latestText = this._sharedString.getText();
		const isLocal = event.isLocal;

		const op = event.opArgs.op;
		let transformPosition: (oldPosition: number) => number;
		if (op.type === MergeTreeDeltaType.INSERT) {
			transformPosition = (oldPosition: number): number => {
				if (op.pos1 === undefined) {
					throw new Error("pos1 undefined");
				}
				if (op.seg === undefined) {
					throw new Error("seg undefined");
				}
				const changeStartPosition = op.pos1;
				const changeLength = (op.seg as string).length;
				return oldPosition <= changeStartPosition
					? oldPosition
					: oldPosition + changeLength;
			};
		} else if (op.type === MergeTreeDeltaType.REMOVE) {
			transformPosition = (oldPosition: number): number => {
				if (op.pos1 === undefined) {
					throw new Error("pos1 undefined");
				}
				if (op.pos2 === undefined) {
					throw new Error("pos2 undefined");
				}
				const changeStartPosition = op.pos1;
				const changeEndPosition = op.pos2;
				const changeLength = changeEndPosition - changeStartPosition;
				if (oldPosition <= changeStartPosition) {
					return oldPosition;
				}
				if (oldPosition > changeEndPosition - 1) {
					return oldPosition - changeLength;
				}
				return changeStartPosition;
			};
		} else {
			throw new Error(
				"Don't know how to handle op types beyond insert and remove",
			);
		}

		this.emit("textChanged", { isLocal, transformPosition });
	};
}
