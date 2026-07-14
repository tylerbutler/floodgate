import { createElement, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";

import { createFloodgateClient, DEV_ONLY_MINT_CREDENTIAL } from "./config.js";
import { createPresenceSession, type PresenceSession } from "./session.js";
import { PresenceAppView } from "./view.js";

declare const __VITE_FLOODGATE_HTTP_URL__: string | undefined;
declare const __VITE_FLOODGATE_SOCKET_URL__: string | undefined;
declare const __VITE_FLOODGATE_TENANT_ID__: string | undefined;
declare const __VITE_FLOODGATE_MINT_CREDENTIAL__: string | undefined;

interface AppState {
	status: "loading" | "ready" | "error";
	session?: PresenceSession;
	error?: string;
}

function documentIdFromHash(): string | undefined {
	return window.location.hash.length > 1
		? window.location.hash.substring(1)
		: undefined;
}

function App(): React.ReactElement {
	const [state, setState] = useState<AppState>({ status: "loading" });
	const sessionRef = useRef<PresenceSession>();

	useEffect(() => {
		let mounted = true;

		const initialize = async (): Promise<void> => {
			try {
				const client = await createFloodgateClient({
					httpUrl:
						typeof __VITE_FLOODGATE_HTTP_URL__ === "undefined"
							? "http://localhost:3000"
							: __VITE_FLOODGATE_HTTP_URL__,
					socketUrl:
						typeof __VITE_FLOODGATE_SOCKET_URL__ === "undefined"
							? undefined
							: __VITE_FLOODGATE_SOCKET_URL__,
					tenantId:
						typeof __VITE_FLOODGATE_TENANT_ID__ === "undefined"
							? "fluid"
							: __VITE_FLOODGATE_TENANT_ID__,
					mintCredential:
						typeof __VITE_FLOODGATE_MINT_CREDENTIAL__ === "undefined"
							? DEV_ONLY_MINT_CREDENTIAL
							: __VITE_FLOODGATE_MINT_CREDENTIAL__,
				});
				const session = await createPresenceSession(client, {
					documentId: documentIdFromHash(),
				});

				if (!mounted) {
					session.dispose();
					return;
				}
				window.location.hash = session.documentId;
				document.title = `Floodgate Presence · ${session.documentId}`;
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
		};

		void initialize();
		return () => {
			mounted = false;
			sessionRef.current?.dispose();
			sessionRef.current = undefined;
		};
	}, []);

	if (state.status === "loading") {
		return (
			<output className="presence-status">
				<span className="presence-spinner" />
				<strong>Opening your presence room…</strong>
				<p>Connecting to Floodgate</p>
			</output>
		);
	}

	if (state.status === "error" || !state.session) {
		return (
			<div className="presence-status is-error" role="alert">
				<strong>Could not connect to Floodgate</strong>
				<p>{state.error ?? "Unknown connection error"}</p>
				<button type="button" onClick={() => window.location.reload()}>
					Try again
				</button>
			</div>
		);
	}

	return createElement(PresenceAppView, {
		tracker: state.session.tracker,
		documentId: state.session.documentId,
		onCreateNew: () => {
			window.location.hash = "";
			window.location.reload();
		},
	});
}

const rootElement = document.getElementById("root");
if (!rootElement) {
	throw new Error("Root element not found");
}
createRoot(rootElement).render(createElement(App));
