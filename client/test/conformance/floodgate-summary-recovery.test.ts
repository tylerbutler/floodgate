import { execFileSync, spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import type { ISequencedDocumentMessage } from "@fluidframework/protocol-definitions";
import { beforeAll, describe, expect, it } from "vitest";
import {
	createFloodgateResolvedUrl,
	createFloodgateServiceFactory,
	createFloodgateTestClient,
	FLOODGATE_JWT_SECRET,
	FLOODGATE_TENANT_ID,
	FLOODGATE_TOKEN_MINT_SECRET,
	generateFloodgateToken,
	isLeveeProxyTarget,
	RUN_ROUTERLICIOUS_COMPAT,
} from "./floodgate-target.js";
import { acknowledgedHandle, submitSummary, uniqueDocId } from "./helpers.js";

const root = fileURLToPath(new URL("../../../", import.meta.url));

async function availablePort(): Promise<number> {
	const listener = createServer();
	await new Promise<void>((resolve, reject) => {
		listener.once("error", reject);
		listener.listen(0, "127.0.0.1", resolve);
	});
	const address = listener.address();
	await new Promise<void>((resolve, reject) => {
		listener.close((error) => (error ? reject(error) : resolve()));
	});
	if (!address || typeof address === "string") {
		throw new Error("Expected a local TCP port");
	}
	return address.port;
}

function startServer(port: number, directory: string) {
	// The shipment script execs erl, so this PID is the runtime, not a launcher.
	const child = spawn(
		"sh",
		[join(root, "build/erlang-shipment/entrypoint.sh"), "run"],
		{
			cwd: root,
			env: {
				...process.env,
				PORT: String(port),
				FLOODGATE_STORAGE_BACKEND: "shelf",
				FLOODGATE_DATA_DIR: directory,
				FLOODGATE_JWT_SECRET,
				FLOODGATE_TOKEN_MINT_SECRET,
			},
			stdio: ["ignore", "pipe", "pipe"],
		},
	);
	let output = "";
	let spawnError: Error | undefined;
	const capture = (chunk: Buffer) => {
		output = (output + chunk.toString()).slice(-20_000);
	};
	child.stdout.on("data", capture);
	child.stderr.on("data", capture);
	child.once("error", (error) => {
		spawnError = error;
	});
	const closed = new Promise<void>((resolve) => {
		child.once("close", () => resolve());
	});
	return { child, closed, output: () => output, error: () => spawnError };
}

type Server = ReturnType<typeof startServer>;

async function waitForServer(server: Server, url: string): Promise<void> {
	const deadline = Date.now() + 30_000;
	while (Date.now() < deadline) {
		const error = server.error();
		if (error) throw error;
		if (server.child.exitCode !== null || server.child.signalCode !== null) {
			throw new Error(`Floodgate exited before startup:\n${server.output()}`);
		}
		try {
			const response = await fetch(`${url}/health`, {
				signal: AbortSignal.timeout(2000),
			});
			if (
				response.ok &&
				server.child.exitCode === null &&
				server.child.signalCode === null
			) {
				return;
			}
		} catch (error) {
			if (
				!(error instanceof TypeError) ||
				!(error.cause instanceof Error) ||
				!("code" in error.cause) ||
				error.cause.code !== "ECONNREFUSED"
			) {
				throw error;
			}
		}
		await delay(50);
	}
	throw new Error(`Floodgate startup timed out:\n${server.output()}`);
}

async function stopServer(server: Server): Promise<void> {
	if (server.child.exitCode === null && server.child.signalCode === null) {
		server.child.kill("SIGTERM");
	}
	const timer = setTimeout(() => server.child.kill("SIGKILL"), 5000);
	try {
		await server.closed;
	} finally {
		clearTimeout(timer);
	}
}

describe.runIf(RUN_ROUTERLICIOUS_COMPAT && !isLeveeProxyTarget)(
	"Floodgate persistent summary recovery",
	() => {
		beforeAll(() => {
			execFileSync("gleam", ["export", "erlang-shipment"], {
				cwd: root,
				stdio: "pipe",
			});
		}, 60_000);

		it("reads history before reconnect and extends it after a Shelf process restart", async () => {
			const directory = await mkdtemp(join(tmpdir(), "floodgate-summary-"));
			let server: Server | undefined;
			try {
				const port = await availablePort();
				const url = `http://127.0.0.1:${port}`;
				const documentId = uniqueDocId("persistent-summary");
				const token = await generateFloodgateToken(documentId);
				const request = async (
					path: string,
					body?: object,
				): Promise<Response> => {
					const response = await fetch(`${url}${path}`, {
						method: body ? "POST" : "GET",
						headers: {
							Authorization: `Bearer ${token}`,
							"Content-Type": "application/json",
						},
						body: body ? JSON.stringify(body) : undefined,
					});
					expect(response.ok, `${path}: ${response.status}`).toBe(true);
					return response;
				};
				const upload = async (content: string): Promise<string> => {
					const put = async (kind: string, body: object): Promise<string> => {
						const response = await request(
							`/repos/${FLOODGATE_TENANT_ID}/git/${kind}`,
							body,
						);
						const value: unknown = await response.json();
						if (
							!value ||
							typeof value !== "object" ||
							!("sha" in value) ||
							typeof value.sha !== "string"
						) {
							throw new Error("Object response has no SHA");
						}
						return value.sha;
					};
					const blob = await put("blobs", { content, encoding: "utf-8" });
					return put("trees", {
						tree: [
							{ path: "file.txt", mode: "100644", type: "blob", sha: blob },
						],
					});
				};
				const openService = () =>
					createFloodgateServiceFactory().createDocumentService(
						createFloodgateResolvedUrl(documentId, url, url),
					);
				server = startServer(port, directory);
				await waitForServer(server, url);
				await request(`/documents/${FLOODGATE_TENANT_ID}`, { id: documentId });
				const service = await openService();
				const connection = await service.connectToDeltaStream(
					createFloodgateTestClient("before-restart"),
				);
				const responses: ISequencedDocumentMessage[] = [];
				const collect = (
					_id: string,
					messages: ISequencedDocumentMessage[],
				) => {
					responses.push(
						...messages.filter((message) => message.type === "summaryAck"),
					);
				};
				connection.on("op", collect);
				let first: string;
				let second: string;
				try {
					first = acknowledgedHandle(
						await submitSummary(connection, await upload("first"), "", 1),
					);
					second = acknowledgedHandle(
						await submitSummary(connection, await upload("second"), first, 2),
					);
					expect(responses.map(acknowledgedHandle)).toEqual([first, second]);
				} finally {
					connection.off("op", collect);
					connection.dispose();
				}
				const readLog = async (): Promise<{
					value: Array<{ type: string; data?: string }>;
				}> =>
					(
						await request(`/deltas/${FLOODGATE_TENANT_ID}/${documentId}`)
					).json();
				let before = await readLog();
				const disconnectDeadline = Date.now() + 5000;
				while (
					!before.value.some(
						(op) =>
							op.type === "leave" &&
							op.data === JSON.stringify(connection.clientId),
					)
				) {
					if (Date.now() >= disconnectDeadline) {
						throw new Error("Writer disconnect was not persisted");
					}
					await delay(20);
					before = await readLog();
				}
				await stopServer(server);
				server = startServer(port, directory);
				await waitForServer(server, url);

				// A fresh factory avoids proving persistence with driver caches.
				const recovered = await openService();
				const storage = await recovered.connectToStorage();
				const versions = await storage.getVersions(null, 10);
				expect(versions.map((version) => version.id)).toEqual([second, first]);
				for (const [index, content] of ["second", "first"].entries()) {
					const snapshot = await storage.getSnapshotTree(versions[index]);
					const blob = snapshot?.blobs["file.txt"];
					if (!blob) throw new Error("Recovered snapshot has no file.txt");
					expect(Buffer.from(await storage.readBlob(blob)).toString()).toBe(
						content,
					);
				}
				expect(
					(await storage.getVersions(null, 1)).map((version) => version.id),
				).toEqual([second]);
				const after = await readLog();
				expect(after).toEqual(before);

				const reconnected = await recovered.connectToDeltaStream(
					createFloodgateTestClient("after-restart"),
				);
				try {
					const response = await submitSummary(
						reconnected,
						await upload("third"),
						second,
						1,
					);
					const third = acknowledgedHandle(response);
					expect(response.sequenceNumber).toBe(
						response.referenceSequenceNumber + 1,
					);
					expect(
						(await storage.getVersions(null, 10)).map((version) => version.id),
					).toEqual([third, second, first]);
					const log = await readLog();
					expect(
						log.value.filter((op) => op.type === "summarize"),
					).toHaveLength(3);
					expect(
						log.value.filter((op) => op.type === "summaryAck"),
					).toHaveLength(3);
					expect(
						log.value.filter((op) => op.type === "summaryNack"),
					).toHaveLength(0);
				} finally {
					reconnected.dispose();
				}
			} catch (error) {
				throw new Error(
					`Persistent summary recovery failed:\n${server?.output() ?? ""}`,
					{
						cause: error,
					},
				);
			} finally {
				if (server) await stopServer(server);
				await rm(directory, { recursive: true, force: true });
			}
		}, 90_000);
	},
);
