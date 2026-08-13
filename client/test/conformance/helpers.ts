/** Generate a unique document ID for test isolation. */
export function uniqueDocId(prefix = "test"): string {
	return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}
