/**
 * Subscribe to an event and resolve when a condition is met, or reject on
 * timeout. The subscription is ALWAYS removed — on both success and timeout
 * paths — so callers never need to handle cleanup themselves.
 *
 * @param subscribe - Registers the event handler and returns an `unsubscribe`
 *   function that removes it. Called exactly once.
 * @param condition - Called on every event. The promise resolves when it
 *   returns `true`.
 * @param timeoutMs - Maximum milliseconds to wait before rejecting.
 * @param timeoutMessage - Rejection message used on timeout.
 */
export function waitForCondition(
	subscribe: (handler: () => void) => () => void,
	condition: () => boolean,
	timeoutMs: number,
	timeoutMessage: string,
): Promise<void> {
	return new Promise<void>((resolve, reject) => {
		// Declare `timer` with `let` so the subscribe callback can reference it
		// before the timeout assignment on the next line.
		let timer: ReturnType<typeof setTimeout>;
		const unsub = subscribe(() => {
			if (condition()) {
				clearTimeout(timer);
				unsub();
				resolve();
			}
		});
		timer = setTimeout(() => {
			unsub();
			reject(new Error(timeoutMessage));
		}, timeoutMs);
	});
}
