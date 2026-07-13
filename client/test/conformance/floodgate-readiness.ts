/**
 * Release-readiness gate for the standalone Floodgate server.
 *
 * ADR-004 keeps Levee and Floodgate as independent supported stacks, so this
 * gate measures whether Floodgate can be released with its official
 * Routerlicious client path. It does not authorize removing Phoenix code.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const COMPAT_TEST_FILE = fileURLToPath(
	new URL("./floodgate-routerlicious.test.ts", import.meta.url),
);

const MANIFEST_FILE = fileURLToPath(
	new URL("./floodgate-readiness.json", import.meta.url),
);

export interface FloodgateReadinessManifest {
	adr: string;
	architectureDecision: string;
	conformanceSuite: string;
	requiredReleaseTarget: string;
	conformanceTargetsTracked: string[];
	requiredLiveStorageBackends: string[];
	verifiedLiveStorageBackends: string[];
	requiredConformanceCategories: string[];
	coexistingStacks: {
		levee: {
			client: string;
			driver: string;
			transport: string;
		};
		floodgate: {
			client: string;
			driver: string;
			transport: string;
		};
	};
	expectedOutstandingTodoCount: number;
	lastVerifiedAt: string;
	readyForFloodgateRelease: boolean;
	notes: string;
}

export interface FloodgateReadiness {
	/** Manifest contents as checked into `floodgate-readiness.json`. */
	manifest: FloodgateReadinessManifest;
	/** Live count of `it.todo(...)` calls in the conformance suite. */
	actualTodoCount: number;
	/** True when `actualTodoCount` matches the manifest's declared count. */
	manifestMatchesReality: boolean;
	/** True when every required backend has a recorded full live suite pass. */
	liveStorageBackendsVerified: boolean;
	/**
	 * True only when the manifest declares Floodgate release-ready and there
	 * are zero outstanding conformance gaps and all required backend runs are
	 * recorded.
	 */
	ready: boolean;
}

/** Reads and parses the repo-tracked Floodgate readiness manifest. */
export function readFloodgateReadinessManifest(): FloodgateReadinessManifest {
	const raw = readFileSync(MANIFEST_FILE, "utf8");
	return JSON.parse(raw) as FloodgateReadinessManifest;
}

/**
 * Counts outstanding `it.todo(...)` gaps required for standalone Floodgate.
 * Todos explicitly tagged `[levee-proxy target]` remain tracked in the shared
 * suite but do not block an independent Floodgate release.
 */
export function countOutstandingConformanceTodos(): number {
	const todoBlocks = readTodoBlocks();

	return todoBlocks.filter((todo) => !todo.includes("[levee-proxy target]"))
		.length;
}

/** Counts every tracked todo across both conformance targets. */
export function countTrackedConformanceTodos(): number {
	return readTodoBlocks().length;
}

function readTodoBlocks(): string[] {
	const source = readFileSync(COMPAT_TEST_FILE, "utf8");
	return source.match(/\bit\.todo\([\s\S]*?\);/g) ?? [];
}

/** Computes Floodgate release readiness from live and declared state. */
export function computeFloodgateReadiness(): FloodgateReadiness {
	const manifest = readFloodgateReadinessManifest();
	const actualTodoCount = countOutstandingConformanceTodos();
	const manifestMatchesReality =
		actualTodoCount === manifest.expectedOutstandingTodoCount;
	const liveStorageBackendsVerified =
		manifest.requiredLiveStorageBackends.length > 0 &&
		manifest.requiredLiveStorageBackends.every((backend) =>
			manifest.verifiedLiveStorageBackends.includes(backend),
		);

	return {
		manifest,
		actualTodoCount,
		manifestMatchesReality,
		liveStorageBackendsVerified,
		ready:
			manifest.readyForFloodgateRelease &&
			actualTodoCount === 0 &&
			liveStorageBackendsVerified,
	};
}
