/**
 * DiceRoller model and React view for the Floodgate example.
 *
 * Uses a SharedMap to store and synchronize the dice value across all
 * connected clients.
 */

import type { ISharedMap } from "@fluidframework/map/legacy";
import type React from "react";
import { useEffect, useState } from "react";

/** Stable SharedMap key for the dice value. */
export const DICE_VALUE_KEY = "diceValue";

const diceFaces = ["⚀", "⚁", "⚂", "⚃", "⚄", "⚅"];

/**
 * Subscribes `onChange` to the SharedMap's `valueChanged` event.
 *
 * @returns A cleanup function that unsubscribes the listener — suitable for
 *   use as a `useEffect` return value.
 */
export function subscribeToDiceMap(
	diceMap: ISharedMap,
	onChange: () => void,
): () => void {
	diceMap.on("valueChanged", onChange);
	return () => diceMap.off("valueChanged", onChange);
}

interface DiceRollerViewProps {
	diceMap: ISharedMap;
}

/**
 * React component that renders the Floodgate DiceRoller.
 *
 * Subscribes to SharedMap `valueChanged` events to keep the displayed value
 * in sync across all connected clients. The container is disposed by the
 * parent (mount / App) on unmount.
 */
export function DiceRollerView({
	diceMap,
}: DiceRollerViewProps): React.ReactElement {
	const [value, setValue] = useState(diceMap.get<number>(DICE_VALUE_KEY) ?? 1);

	useEffect(() => {
		const handleValueChanged = (): void => {
			setValue(diceMap.get<number>(DICE_VALUE_KEY) ?? 1);
		};
		return subscribeToDiceMap(diceMap, handleValueChanged);
	}, [diceMap]);

	const handleClick = (): void => {
		diceMap.set(DICE_VALUE_KEY, Math.floor(Math.random() * 6) + 1);
	};

	const diceChar = diceFaces[value - 1] ?? "?";

	return (
		<div style={styles.container}>
			<h1 style={styles.title}>Floodgate DiceRoller</h1>
			<div style={styles.diceContainer}>
				<span style={styles.dice}>{diceChar}</span>
				<span style={styles.value}>Value: {value}</span>
			</div>
			<button type="button" onClick={handleClick} style={styles.button}>
				Roll
			</button>
			<p style={styles.hint}>
				Open this page in another tab to see real-time sync!
			</p>
		</div>
	);
}

const styles: Record<string, React.CSSProperties> = {
	container: {
		display: "flex",
		flexDirection: "column",
		alignItems: "center",
		padding: "20px",
		backgroundColor: "white",
		borderRadius: "12px",
		boxShadow: "0 2px 10px rgba(0,0,0,0.1)",
	},
	title: {
		margin: "0 0 20px 0",
		color: "#333",
		fontSize: "24px",
	},
	diceContainer: {
		display: "flex",
		flexDirection: "column",
		alignItems: "center",
		marginBottom: "20px",
	},
	dice: {
		fontSize: "120px",
		lineHeight: "1",
		color: "#333",
	},
	value: {
		fontSize: "18px",
		color: "#666",
		marginTop: "10px",
	},
	button: {
		padding: "12px 48px",
		fontSize: "18px",
		fontWeight: "bold",
		color: "white",
		backgroundColor: "#2196F3",
		border: "none",
		borderRadius: "8px",
		cursor: "pointer",
		transition: "background-color 0.2s",
	},
	hint: {
		marginTop: "20px",
		fontSize: "14px",
		color: "#888",
		textAlign: "center",
	},
};
