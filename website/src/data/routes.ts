export interface Route {
	method: string;
	path: string;
	desc: string;
}

export interface RouteGroup {
	id: string;
	label: string;
	routes: Route[];
}

// The single source of truth for the HTTP surface. /docs/http-surface renders
// all of it; /architecture renders the excerpt selected below.
export const routeGroups: RouteGroup[] = [
	{
		id: "health",
		label: "health",
		routes: [
			{ method: "GET", path: "/health", desc: 'readiness probe — {"status":"ok"}' },
		],
	},
	{
		id: "admin-auth",
		label: "admin & auth",
		routes: [
			{ method: "GET", path: "/admin/*", desc: "shared Lustre admin SPA" },
			{ method: "GET", path: "/auth/github", desc: "begin GitHub OAuth" },
			{ method: "GET", path: "/auth/github/callback", desc: "complete GitHub OAuth" },
			{ method: "GET", path: "/api/auth/config", desc: "UI auth capabilities" },
			{ method: "GET", path: "/api/auth/me", desc: "current cookie/bearer admin" },
			{ method: "POST", path: "/api/auth/logout", desc: "end the admin session" },
		],
	},
	{
		id: "tenants",
		label: "tenant api",
		routes: [
			{ method: "GET", path: "/api/tenants", desc: "list tenants (admin session or key)" },
			{ method: "POST", path: "/api/tenants", desc: "create a tenant (admin session or key)" },
			{ method: "GET", path: "/api/tenants/:id", desc: "show a tenant with its secrets (admin session or key)" },
			{ method: "DELETE", path: "/api/tenants/:id", desc: "delete a tenant (admin session or key)" },
			{ method: "POST", path: "/api/tenants/:id/secrets/:slot", desc: "regenerate secret slot 1 or 2 (admin session or key)" },
			{ method: "POST", path: "/api/tenants/:tenant/token-mint", desc: "mint a document token (dev/integration)" },
		],
	},
	{
		id: "documents",
		label: "documents & deltas",
		routes: [
			{ method: "POST", path: "/documents/:tenant", desc: "create a document (id from body, or generated)" },
			{ method: "POST", path: "/documents/:tenant/:id", desc: "create a document with an explicit id" },
			{ method: "GET", path: "/documents/:tenant/:id", desc: "document metadata" },
			{ method: "GET", path: "/documents/:tenant/session/:id", desc: "session discovery" },
			{ method: "GET", path: "/documents/:tenant/:id/deltas", desc: "ops catch-up" },
			{ method: "GET", path: "/deltas/:tenant/:id", desc: "ops catch-up (Levee-style path)" },
		],
	},
	{
		id: "git",
		label: "git-like storage",
		routes: [
			{ method: "GET", path: "/repos/:tenant/commits", desc: "commit history" },
			{ method: "GET", path: "/repos/:tenant/git/refs", desc: "list refs" },
			{ method: "POST", path: "/repos/:tenant/git/refs", desc: "create a ref" },
			{ method: "GET", path: "/repos/:tenant/git/refs/*path", desc: "read a ref" },
			{ method: "PATCH", path: "/repos/:tenant/git/refs/*path", desc: "update a ref" },
			{ method: "POST", path: "/repos/:tenant/git/{blobs,trees,commits}", desc: "create a git object" },
			{ method: "GET", path: "/repos/:tenant/git/{blobs,trees,commits}/:sha", desc: "read a git object" },
		],
	},
];

export const routeId = (r: Route) =>
	`${r.method}-${r.path}`
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, "-")
		.replace(/^-+|-+$/g, "");

const allRoutes = routeGroups.flatMap((g) => g.routes);

/** The excerpt /architecture shows, named by path so it tracks the real list. */
export const excerptPaths = [
	"/health",
	"/documents/:tenant",
	"/documents/:tenant/:id",
	"/documents/:tenant/:id/deltas",
	"/repos/:tenant/git/refs",
	"/repos/:tenant/git/{blobs,trees,commits}",
	"/api/tenants",
];

export const routeExcerpt: Route[] = excerptPaths.map((path) => {
	const route = allRoutes.find((r) => r.path === path);
	if (!route) throw new Error(`Excerpt references an unknown route: ${path}`);
	return route;
});
