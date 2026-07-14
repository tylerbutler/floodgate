import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// biome-ignore lint/style/noDefaultExport: correct pattern for config files
export default defineConfig({
	plugins: [react()],
	build: {
		outDir: "dist",
		sourcemap: true,
		target: "esnext",
	},
	server: {
		port: 3003,
		strictPort: true,
		host: true,
	},
	define: {
		__VITE_FLOODGATE_HTTP_URL__: JSON.stringify(
			process.env["VITE_FLOODGATE_HTTP_URL"] ?? "http://localhost:3000",
		),
		__VITE_FLOODGATE_SOCKET_URL__: JSON.stringify(
			process.env["VITE_FLOODGATE_SOCKET_URL"],
		),
		__VITE_FLOODGATE_TENANT_ID__: JSON.stringify(
			process.env["VITE_FLOODGATE_TENANT_ID"] ?? "fluid",
		),
		// Development-only credential matching the local Floodgate launcher.
		__VITE_FLOODGATE_MINT_CREDENTIAL__: JSON.stringify(
			process.env["VITE_FLOODGATE_TOKEN_MINT_SECRET"] ??
				"floodgate-example-mint-secret",
		),
	},
});
