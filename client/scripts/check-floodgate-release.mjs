import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

const httpUrl = (
	process.env.FLOODGATE_HTTP_URL ?? "http://localhost:3000"
).replace(/\/$/, "");

try {
	const response = await fetch(httpUrl, {
		signal: AbortSignal.timeout(2_000),
	});

	if (response.status >= 500) {
		throw new Error(`Floodgate returned HTTP ${response.status}`);
	}
} catch (error) {
	console.error(
		`Floodgate release readiness requires a running floodgate-direct target at ${httpUrl}.`,
	);
	console.error(error);
	process.exit(1);
}

const command = process.platform === "win32" ? "pnpm.cmd" : "pnpm";
const result = spawnSync(
	command,
	[
		"exec",
		"vitest",
		"run",
		"packages/levee-driver/test/integration/floodgate-readiness.test.ts",
		"packages/levee-driver/test/integration/floodgate-routerlicious.test.ts",
	],
	{
		env: {
			...process.env,
			FLOODGATE_ROUTERLICIOUS_COMPAT: "1",
			FLOODGATE_TARGET_LABEL: "floodgate-direct",
		},
		stdio: "inherit",
	},
);

if (result.status !== 0) {
	process.exit(result.status ?? 1);
}

const manifest = JSON.parse(
	readFileSync(
		new URL(
			"../packages/levee-driver/test/integration/floodgate-readiness.json",
			import.meta.url,
		),
		"utf8",
	),
);
const conformanceSource = readFileSync(
	new URL(
		"../packages/levee-driver/test/integration/floodgate-routerlicious.test.ts",
		import.meta.url,
	),
	"utf8",
);
const todoBlocks = conformanceSource.match(/\bit\.todo\([\s\S]*?\);/g) ?? [];
const floodgateTodoCount = todoBlocks.filter(
	(todo) => !todo.includes("[levee-proxy target]"),
).length;
const unverifiedStorageBackends = manifest.requiredLiveStorageBackends.filter(
	(backend) => !manifest.verifiedLiveStorageBackends.includes(backend),
);

if (
	!manifest.readyForFloodgateRelease ||
	floodgateTodoCount > 0 ||
	unverifiedStorageBackends.length > 0
) {
	console.error(
		"Floodgate is not release-ready: " +
			`${floodgateTodoCount} required conformance gaps remain; ` +
			`unverified storage backends: ${unverifiedStorageBackends.join(", ") || "none"}.`,
	);
	process.exit(1);
}
