export interface DocNode {
	slug: string;
	href: string;
	title: string;
	summary: string;
}

// Order here is the canonical Next/Prev chain for the info-style docs nodes.
export const docNodes: DocNode[] = [
	{
		slug: "getting-started",
		href: "/docs/getting-started",
		title: "Getting Started",
		summary: "Build and run Floodgate locally with gleam or just.",
	},
	{
		slug: "configuration",
		href: "/docs/configuration",
		title: "Configuration",
		summary: "Every environment variable: core, storage, and limits.",
	},
	{
		slug: "multi-tenancy",
		href: "/docs/multi-tenancy",
		title: "Multi-tenancy",
		summary: "Tenants, rotating secret slots, and the admin API.",
	},
	{
		slug: "presence",
		href: "/docs/presence",
		title: "Presence",
		summary: "Server-backed presence_v1 on both wire protocols.",
	},
	{
		slug: "http-surface",
		href: "/docs/http-surface",
		title: "HTTP Surface",
		summary: "The full REST endpoint reference.",
	},
	{
		slug: "development",
		href: "/docs/development",
		title: "Development",
		summary: "Build, test, and the cross-server conformance suites.",
	},
];

export function nodeNav(slug: string) {
	const idx = docNodes.findIndex((n) => n.slug === slug);
	if (idx === -1) throw new Error(`Unknown doc node: ${slug}`);
	return {
		node: docNodes[idx],
		prev: idx > 0 ? docNodes[idx - 1] : null,
		next: idx < docNodes.length - 1 ? docNodes[idx + 1] : null,
	};
}
