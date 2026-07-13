/**
 * Executable Floodgate release-readiness gate.
 *
 * This suite is not network-gated. It keeps the conformance manifest aligned
 * while ADR-004 preserves Levee as an independent supported server stack.
 */

import { describe, expect, it } from "vitest";
import {
	computeFloodgateReadiness,
	countOutstandingConformanceTodos,
	countTrackedConformanceTodos,
	readFloodgateReadinessManifest,
} from "./floodgate-readiness.js";

describe("Floodgate release readiness gate", () => {
	it("keeps the floodgate-readiness.json manifest in sync with the conformance suite", () => {
		const manifest = readFloodgateReadinessManifest();
		const actualTodoCount = countOutstandingConformanceTodos();

		expect(
			actualTodoCount,
			"The number of `it.todo(...)` gaps in floodgate-routerlicious.test.ts " +
				"changed without updating `expectedOutstandingTodoCount` in " +
				"floodgate-readiness.json. Update the manifest (and, if the count " +
				"reached 0, revisit `readyForFloodgateRelease` and ADR-003) " +
				"in the same change that touches the conformance suite.",
		).toBe(manifest.expectedOutstandingTodoCount);
	});

	it("requires the release flag to match the conformance state", () => {
		const readiness = computeFloodgateReadiness();

		expect(readiness.manifestMatchesReality).toBe(true);

		if (
			readiness.actualTodoCount > 0 ||
			!readiness.liveStorageBackendsVerified
		) {
			expect(readiness.manifest.readyForFloodgateRelease).toBe(false);
			expect(readiness.ready).toBe(false);
		} else {
			expect(readiness.manifest.readyForFloodgateRelease).toBe(true);
			expect(readiness.ready).toBe(true);
		}
	});

	it("requires full live conformance for ETS and actor-memory", () => {
		const readiness = computeFloodgateReadiness();

		expect(readiness.manifest.requiredLiveStorageBackends).toEqual([
			"ets",
			"memory",
		]);
		expect(readiness.manifest.verifiedLiveStorageBackends).toBeInstanceOf(
			Array,
		);
		expect(
			readiness.manifest.verifiedLiveStorageBackends.every((backend) =>
				readiness.manifest.requiredLiveStorageBackends.includes(backend),
			),
		).toBe(true);
		expect(readiness.liveStorageBackendsVerified).toBe(
			readiness.manifest.requiredLiveStorageBackends.every((backend) =>
				readiness.manifest.verifiedLiveStorageBackends.includes(backend),
			),
		);
	});

	it("makes standalone Floodgate the required release target", () => {
		const manifest = readFloodgateReadinessManifest();

		expect(manifest.requiredReleaseTarget).toBe("floodgate-direct");
		expect(manifest.conformanceTargetsTracked).toEqual(
			expect.arrayContaining(["floodgate-direct", "levee-proxy"]),
		);
	});

	it("declares the full create/load/sync/reconnect/summaries/signals surface from ADR-002", () => {
		const manifest = readFloodgateReadinessManifest();

		expect(manifest.requiredConformanceCategories).toEqual(
			expect.arrayContaining([
				"create",
				"load",
				"sync",
				"reconnect",
				"summaries",
				"signals",
			]),
		);
	});

	it("records the two coexisting client and transport stacks", () => {
		const manifest = readFloodgateReadinessManifest();

		expect(manifest.coexistingStacks.levee).toEqual({
			client: "@tylerbu/levee-client",
			driver: "@tylerbu/levee-driver",
			transport: "Phoenix Channels",
		});
		expect(manifest.coexistingStacks.floodgate).toEqual({
			client: "@tylerbu/floodgate-client",
			driver: "@fluidframework/routerlicious-driver",
			transport: "Engine.IO/Socket.IO",
		});
	});

	it("rejects a release-ready flag while any release condition remains", () => {
		const manifest = readFloodgateReadinessManifest();

		if (manifest.readyForFloodgateRelease) {
			expect(manifest.expectedOutstandingTodoCount).toBe(0);
			expect(countOutstandingConformanceTodos()).toBe(0);
			expect(
				manifest.requiredLiveStorageBackends.every((backend) =>
					manifest.verifiedLiveStorageBackends.includes(backend),
				),
			).toBe(true);
		}
	});

	it("does not count Levee-proxy-only gaps against Floodgate release", () => {
		expect(countOutstandingConformanceTodos()).toBeLessThan(
			countTrackedConformanceTodos(),
		);
	});
});
