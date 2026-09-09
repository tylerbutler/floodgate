import type { IDocumentDeltaConnection } from "@fluidframework/driver-definitions/internal";
import type { ISequencedDocumentMessage } from "@fluidframework/protocol-definitions";

/** Generate a unique document ID for test isolation. */
export function uniqueDocId(prefix = "test"): string {
	return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

export function submitSummary(
	connection: IDocumentDeltaConnection,
	treeHandle: string,
	head: string,
	clientSequenceNumber: number,
	referenceSequenceNumber = 0,
): Promise<ISequencedDocumentMessage> {
	return new Promise((resolve, reject) => {
		let proposalSequenceNumber: number | undefined;
		const cleanup = () => {
			clearTimeout(timer);
			connection.off("op", onOps);
		};
		const onOps = (
			_documentId: string,
			messages: ISequencedDocumentMessage[],
		) => {
			for (const message of messages) {
				if (
					message.type === "summarize" &&
					message.clientId === connection.clientId &&
					message.clientSequenceNumber === clientSequenceNumber
				) {
					proposalSequenceNumber = message.sequenceNumber;
				}
				if (
					proposalSequenceNumber !== undefined &&
					message.referenceSequenceNumber === proposalSequenceNumber &&
					(message.type === "summaryAck" || message.type === "summaryNack")
				) {
					cleanup();
					resolve(message);
					return;
				}
			}
		};
		const timer = setTimeout(() => {
			cleanup();
			reject(new Error("Timed out waiting for summary response"));
		}, 10_000);
		connection.on("op", onOps);
		connection.submit([
			{
				clientSequenceNumber,
				referenceSequenceNumber,
				type: "summarize",
				contents: {
					handle: treeHandle,
					head,
					parents: head === "" ? [] : [head],
					message: `Summary ${clientSequenceNumber}`,
				},
			},
		]);
	});
}

export function acknowledgedHandle(message: ISequencedDocumentMessage): string {
	const handle: unknown = message.contents?.handle;
	if (message.type !== "summaryAck" || typeof handle !== "string") {
		throw new Error(`Expected summaryAck, received ${JSON.stringify(message)}`);
	}
	return handle;
}
