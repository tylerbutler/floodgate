import { createElement } from "react";
import { createRoot, type Root } from "react-dom/client";

import {
	createFloodgateClient,
	type FloodgatePresenceConfig,
} from "./config.js";
import { createPresenceSession } from "./session.js";
import { PresenceAppView } from "./view.js";

export type MountConfig = FloodgatePresenceConfig;

function createSafeShareUrl(documentId: string): string {
	const url = new URL(window.location.href);
	url.searchParams.set("documentId", documentId);
	url.searchParams.delete("mintCredential");
	url.searchParams.delete("authToken");
	return url.toString();
}

/** Mounts the Floodgate Presence demo into a Sandbag-compatible host. */
export async function mount(
	element: HTMLElement,
	config: MountConfig = {},
): Promise<{ unmount: () => void; documentId: string }> {
	const client = await createFloodgateClient(config);
	const session = await createPresenceSession(client, config);
	const root: Root = createRoot(element);

	root.render(
		createElement(PresenceAppView, {
			tracker: session.tracker,
			documentId: session.documentId,
			shareUrl: createSafeShareUrl(session.documentId),
		}),
	);

	return {
		documentId: session.documentId,
		unmount: () => {
			root.unmount();
			session.dispose();
		},
	};
}
