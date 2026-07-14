import type {
	SequenceDeltaEvent,
	SharedString,
} from "@fluidframework/sequence/legacy";
import {
	Component,
	type CSSProperties,
	createRef,
	type FormEvent,
	type RefObject,
} from "react";

/**
 * {@link CollaborativeInput} input props.
 */
export interface ICollaborativeInputProps {
	/**
	 * The SharedString that will store the input value.
	 */
	sharedString: SharedString;

	/**
	 * Whether or not the control should be read-only.
	 * @defaultValue `false`
	 */
	readOnly?: boolean;

	/**
	 * Whether spellCheck should be enabled.
	 * @defaultValue `true`
	 */
	spellCheck?: boolean;
	className?: string;
	style?: CSSProperties;
	disabled?: boolean;
	onInput?: (sharedString: SharedString) => void;
}

/**
 * {@link CollaborativeInput} component state.
 */
interface ICollaborativeInputState {
	selectionEnd: number;
	selectionStart: number;
}

/**
 * Given a SharedString, produces a collaborative input element.
 */
export class CollaborativeInput extends Component<
	ICollaborativeInputProps,
	ICollaborativeInputState
> {
	private readonly inputElementRef: RefObject<HTMLInputElement>;

	constructor(props: ICollaborativeInputProps) {
		super(props);

		this.inputElementRef = createRef<HTMLInputElement>();

		this.state = {
			selectionEnd: 0,
			selectionStart: 0,
		};

		this.handleInput = this.handleInput.bind(this);
		this.updateSelection = this.updateSelection.bind(this);
	}

	private readonly sequenceDeltaListener = (ev: SequenceDeltaEvent): void => {
		if (!ev.isLocal) {
			this.updateInputFromSharedString();
		}
	};

	public override componentDidMount(): void {
		this.props.sharedString.on("sequenceDelta", this.sequenceDeltaListener);
		this.updateInputFromSharedString();
	}

	public override componentWillUnmount(): void {
		this.props.sharedString.off("sequenceDelta", this.sequenceDeltaListener);
	}

	public override componentDidUpdate(
		prevProps: ICollaborativeInputProps,
	): void {
		if (prevProps.sharedString !== this.props.sharedString) {
			this.updateInputFromSharedString();
		}
	}

	public override render(): JSX.Element {
		return (
			<input
				className={this.props.className}
				style={this.props.style}
				readOnly={this.props.readOnly ?? false}
				spellCheck={this.props.spellCheck ?? true}
				ref={this.inputElementRef}
				disabled={this.props.disabled}
				onBeforeInput={this.updateSelection}
				onKeyDown={this.updateSelection}
				onClick={this.updateSelection}
				onContextMenu={this.updateSelection}
				onInput={this.handleInput}
			/>
		);
	}

	private updateInputFromSharedString(): void {
		const text = this.props.sharedString.getText();
		if (
			this.inputElementRef.current &&
			this.inputElementRef.current.value !== text
		) {
			this.inputElementRef.current.value = text;
		}
	}

	private readonly handleInput = (ev: FormEvent<HTMLInputElement>): void => {
		const newText = ev.currentTarget.value;
		const newPosition = ev.currentTarget.selectionStart ?? 0;
		const isTextInserted = newPosition - this.state.selectionStart > 0;
		if (isTextInserted) {
			const insertedText = newText.slice(
				this.state.selectionStart,
				newPosition,
			);
			const changeRangeLength =
				this.state.selectionEnd - this.state.selectionStart;
			if (changeRangeLength === 0) {
				this.props.sharedString.insertText(
					this.state.selectionStart,
					insertedText,
				);
			} else {
				this.props.sharedString.replaceText(
					this.state.selectionStart,
					this.state.selectionEnd,
					insertedText,
				);
			}
		} else {
			this.props.sharedString.removeText(newPosition, this.state.selectionEnd);
		}
		this.props.onInput?.(this.props.sharedString);
	};

	private readonly updateSelection = (): void => {
		if (!this.inputElementRef.current) {
			return;
		}

		const selectionEnd = this.inputElementRef.current.selectionEnd ?? 0;
		const selectionStart = this.inputElementRef.current.selectionStart ?? 0;
		this.setState({ selectionEnd, selectionStart });
	};
}
