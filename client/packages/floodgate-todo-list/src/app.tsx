/**
 * Standalone Floodgate Todo List application.
 *
 * Reads the document ID from the URL hash and writes the server-assigned ID
 * back to the hash after creating a new container. Configuration is sourced
 * from Vite environment variables with dev-mode defaults.
 */

import type React from "react";
import { createElement, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";

import { createFloodgateClient, DEV_ONLY_MINT_CREDENTIAL } from "./config.js";
import { createTodoSession, type TodoSession } from "./session.js";
import { TodoListAppView } from "./view.js";

// Vite-injected environment variable declarations (dev-mode defaults below)
declare const __VITE_FLOODGATE_HTTP_URL__: string | undefined;
declare const __VITE_FLOODGATE_SOCKET_URL__: string | undefined;
declare const __VITE_FLOODGATE_TENANT_ID__: string | undefined;
declare const __VITE_FLOODGATE_MINT_CREDENTIAL__: string | undefined;

/** Reads the document ID from the URL hash, if present. */
function getDocumentIdFromHash(): string | undefined {
	const hash = window.location.hash;
	return hash.length > 1 ? hash.substring(1) : undefined;
}

/** Writes the document ID into the URL hash. */
function setDocumentIdInHash(documentId: string): void {
	window.location.hash = documentId;
}

interface AppState {
	status: "loading" | "ready" | "error";
	session?: TodoSession;
	error?: string;
}

/** Main Floodgate Todo List application component. */
function App(): React.ReactElement | null {
	const [state, setState] = useState<AppState>({ status: "loading" });
	const sessionRef = useRef<TodoSession | undefined>(undefined);

	useEffect(() => {
		let mounted = true;

		async function initialize(): Promise<void> {
			try {
				const httpUrl =
					typeof __VITE_FLOODGATE_HTTP_URL__ !== "undefined"
						? __VITE_FLOODGATE_HTTP_URL__
						: "http://localhost:3000";
				const socketUrl =
					typeof __VITE_FLOODGATE_SOCKET_URL__ !== "undefined"
						? __VITE_FLOODGATE_SOCKET_URL__
						: undefined;
				const tenantId =
					typeof __VITE_FLOODGATE_TENANT_ID__ !== "undefined"
						? __VITE_FLOODGATE_TENANT_ID__
						: "fluid";
				// ⚠️ DEV-ONLY: floodgate-example-mint-secret is a local dev credential only.
				const mintCredential =
					typeof __VITE_FLOODGATE_MINT_CREDENTIAL__ !== "undefined"
						? __VITE_FLOODGATE_MINT_CREDENTIAL__
						: DEV_ONLY_MINT_CREDENTIAL;

				const floodgateClient = await createFloodgateClient({
					httpUrl,
					socketUrl,
					tenantId,
					mintCredential,
				});

				const session = await createTodoSession(floodgateClient, {
					documentId: getDocumentIdFromHash(),
				});

				if (!mounted) {
					// Component unmounted while async init was in flight — dispose immediately.
					session.dispose();
					return;
				}

				// Write the server-assigned document ID to the URL hash.
				setDocumentIdInHash(session.documentId);
				sessionRef.current = session;
				setState({ status: "ready", session });
			} catch (error) {
				if (mounted) {
					setState({
						status: "error",
						error: error instanceof Error ? error.message : String(error),
					});
				}
			}
		}

		initialize().catch(() => {
			// Errors are handled inside initialize().
		});

		return () => {
			mounted = false;
			sessionRef.current?.dispose();
			sessionRef.current = undefined;
		};
	}, []);

	if (state.status === "loading") {
		return (
			<div style={styles.statusContainer}>
				<div style={styles.spinner} />
				<p>Connecting to Floodgate server...</p>
			</div>
		);
	}

	if (state.status === "error") {
		return (
			<div style={styles.statusContainer}>
				<h2 style={styles.errorTitle}>Floodgate Connection Error</h2>
				<p style={styles.errorMessage}>{state.error}</p>
				<p style={styles.hint}>
					Make sure the Floodgate server is running on{" "}
					<code>http://localhost:3000</code>.
				</p>
				<button
					type="button"
					onClick={() => window.location.reload()}
					style={styles.retryButton}
				>
					Retry
				</button>
			</div>
		);
	}

	if (!state.session) {
		return null;
	}

	return (
		<div>
			{createElement(TodoListAppView, {
				todoList: state.session.todoList,
				container: state.session.container,
			})}
			<div style={styles.footer}>
				<p>
					Document ID: <code>{state.session.documentId}</code>
				</p>
				<button
					type="button"
					onClick={() => {
						window.location.hash = "";
						window.location.reload();
					}}
					style={styles.newButton}
				>
					Create New Document
				</button>
			</div>
		</div>
	);
}

const styles: Record<string, React.CSSProperties> = {
	statusContainer: {
		display: "flex",
		flexDirection: "column",
		alignItems: "center",
		justifyContent: "center",
		padding: "40px",
		backgroundColor: "white",
		borderRadius: "12px",
		boxShadow: "0 2px 10px rgba(0,0,0,0.1)",
		textAlign: "center",
	},
	spinner: {
		width: "40px",
		height: "40px",
		border: "4px solid #f3f3f3",
		borderTop: "4px solid #2196F3",
		borderRadius: "50%",
		animation: "spin 1s linear infinite",
		marginBottom: "20px",
	},
	errorTitle: {
		color: "#d32f2f",
		margin: "0 0 10px 0",
	},
	errorMessage: {
		color: "#666",
		marginBottom: "20px",
	},
	hint: {
		fontSize: "14px",
		color: "#888",
		marginBottom: "20px",
	},
	retryButton: {
		padding: "10px 30px",
		fontSize: "16px",
		color: "white",
		backgroundColor: "#2196F3",
		border: "none",
		borderRadius: "6px",
		cursor: "pointer",
	},
	footer: {
		marginTop: "20px",
		padding: "15px",
		backgroundColor: "white",
		borderRadius: "8px",
		boxShadow: "0 2px 10px rgba(0,0,0,0.1)",
		textAlign: "center",
	},
	newButton: {
		padding: "8px 20px",
		fontSize: "14px",
		color: "#666",
		backgroundColor: "#f5f5f5",
		border: "1px solid #ddd",
		borderRadius: "6px",
		cursor: "pointer",
	},
};

// CSS animation for the loading spinner
const styleElement = document.createElement("style");
styleElement.textContent = `
  @keyframes spin {
    0% { transform: rotate(0deg); }
    100% { transform: rotate(360deg); }
  }
`;
document.head.appendChild(styleElement);

const rootElement = document.getElementById("root");
if (!rootElement) {
	throw new Error("Root element not found");
}

const root = createRoot(rootElement);
root.render(createElement(App, null));
