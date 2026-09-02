---
target: the admin site
total_score: 19
max_score: 40
na_heuristics: 
p0_count: 1
p1_count: 3
timestamp: 2026-09-02T20-36-05Z
slug: admin-src-levee-admin
---
Method: dual-agent (A: `4e07c6e9-92a8-414b-a1b9-20ac17174fa0` · B: `9bae6ea1-9a44-4358-af0e-c30dc0e3fe7a`)

## Design Health Score

| # | Heuristic | Score | Key issue |
|---|---|---:|---|
| 1 | Visibility of System Status | 3 | Async states exist, but there is no active-route indicator or announced live status. |
| 2 | Match System / Real World | 2 | The UI still calls Floodgate “Levee”; technical labels such as “SN” and “token mint” lack context. |
| 3 | User Control and Freedom | 2 | The authenticated shell has no visible route back to Dashboard. |
| 4 | Consistency and Standards | 2 | Document tooling uses many classes with no CSS; destructive actions use inconsistent safeguards. |
| 5 | Error Prevention | 3 | Tenant deletion is well guarded; secret rotation is not guarded to the same standard. |
| 6 | Recognition Rather Than Recall | 2 | Opaque IDs and secrets have no copy action; document status is color-only. |
| 7 | Flexibility and Efficiency | 0 | No shortcuts, batch actions, or other expert accelerators are present. |
| 8 | Aesthetic and Minimalist Design | 2 | Basic CRUD views are clean, but the core document-debugging views lack a finished visual system. |
| 9 | Error Recovery | 2 | Errors are plain but generic and often do not tell the operator what to do next. |
| 10 | Help and Documentation | 1 | There is almost no contextual help or first-run guidance. |
| **Total** |  | **19/40** | **Major improvement required** |

## Design Specificity Verdict

**The product-specific depth is strong, but the shell is generic and the identity is wrong.** Git object browsing, operation streams, tenant connection URLs, and two-slot secret rotation are authentic to Floodgate’s operational domain. The surrounding indigo-on-gray CRUD shell could belong to almost any admin product, and its only persistent identity signal says **Levee**, an obsolete predecessor name.

The stale naming appears in the browser title (`admin/index.html:6`), authenticated nav (`admin/src/levee_admin.gleam:954`), dashboard welcome card (`admin/src/levee_admin/pages/dashboard.gleam:57`), and copyable client configuration (`admin/src/levee_admin/pages/tenant_detail.gleam:363`). The last item needs a correctness check, not a blind text replacement: the current client API name must match the package users actually install.

**Deterministic scan:** the detector returned **0 findings**, but it ran in degraded regex mode because its HTML/CSS parser modules were unavailable. It scanned only `admin/index.html`; `.gleam` views are outside its file support. Selector matching and computed contrast were not evaluated, so this is an undercount, not a clean bill of health. There were no detector false positives.

**Visual overlays:** none. No browser automation tool is available in this session, so no mutable page, screenshot, injection, or console overlay could be created. The SPA bundle was also absent before a build, and protected routes require authentication.

## Overall Impression

The admin site understands its data better than it understands the operator’s journey. Its best material—the live document state, operation stream, refs, summaries, and Git objects—is buried behind a generic shell and appears unfinished. The largest opportunity is to turn document investigation into the product’s clear operational center, with persistent navigation and safety patterns that match the consequences of each action.

## What’s Working

1. **Tenant deletion has a strong guardrail.** It repeats the tenant ID, requires an exact typed match, and disables the destructive action until the match succeeds.
2. **Secrets use a security-conscious default.** Stored tenant responses do not reveal secret values; the UI reveals a new value only after regeneration.
3. **Tenant connection details are practical.** The page derives HTTP, WebSocket, and token-mint URLs and produces a tenant-specific client configuration instead of forcing manual substitution.

## Priority Issues

**[P0] Core document investigation views have no complete visual implementation**

- **Why it matters:** Classes for tabs, data tables, status dots, operation entries, Git objects, breadcrumbs, code blocks, and SHA links are used throughout `document_detail.gleam` and `document_list.gleam` but have no rules in `admin/index.html`. The most important operational workflow therefore falls back toward browser-default presentation.
- **Fix:** Add a coherent, responsive system for tab navigation, dense data tables, status labels, operation history, code content, and Git object navigation. Include overflow behavior for narrow screens.
- **Suggested command:** `/impeccable harden`

**[P1] Obsolete Levee naming misidentifies the product**

- **Why it matters:** Every authenticated page, the browser tab, the dashboard, and a copyable integration sample tell operators they are using a different product. This damages trust and can propagate incorrect client code.
- **Fix:** Replace user-visible branding with Floodgate, update maintainer-facing comments, and verify the correct client package/class before changing the code sample.
- **Suggested command:** `/impeccable clarify`

**[P1] The authenticated shell has no real navigation**

- **Why it matters:** The brand is a plain heading and the shell exposes only a user name and Logout. Deep pages have local parent links but no discoverable route to Dashboard or Tenants.
- **Fix:** Make the product mark a Dashboard link and add persistent Dashboard and Tenants destinations with an active state.
- **Suggested command:** `/impeccable layout`

**[P1] Secret rotation is under-protected and ends without operational guidance**

- **Why it matters:** One confirmation click can invalidate all tokens signed with a secret. Afterward, the operator gets no copy action and no explicit instruction to update affected client configuration.
- **Fix:** State the blast radius before confirmation, use a stronger confirmation pattern, add one-click copy, and make the success state explain the next required action.
- **Suggested command:** `/impeccable harden`

**[P2] High-stakes workflows end weakly**

- **Why it matters:** Successful tenant deletion redirects silently, and regenerated secrets must be selected manually. The user receives the least reassurance at the moments with the most risk.
- **Fix:** Carry an explicit deletion confirmation into the tenant list and provide copy actions for secrets and opaque identifiers.
- **Suggested command:** `/impeccable polish`

## Cognitive Load

The site passes single-focus, chunking, grouping, one-task-at-a-time, and basic progressive-disclosure checks. It fails three checks, which gives it **moderate cognitive load**:

- **Visual hierarchy:** Dashboard cards have nearly identical visual weight, so “Welcome,” tenant status, and quick actions compete.
- **Minimal choices:** Tenant Detail exposes routine navigation, two reveal actions, two rotations, and deletion in one uninterrupted column.
- **Working memory:** Operators must manually select secrets and retype opaque tenant IDs.

The five Document Detail tabs also cross the four-choice guideline. That is defensible for an expert tool only if the tab model is visually clear and preserves state; the missing tab styling removes that support.

## Emotional Journey

Secret rotation starts with appropriate warning language, then collapses into a thin success message at the point where the operator must safely capture and deploy the new secret. Tenant deletion creates justified friction, but its ending is a silent redirect. Both flows need stronger closure: confirm exactly what changed, identify the affected tenant or slot, and tell the operator what to do next.

## Persona Red Flags

**Alex, power operator:** There are no shortcuts, batch actions, persistent destinations, or fast copy controls. Repeated tenant operations require full navigation and one-item-at-a-time interaction.

**Sam, accessibility-dependent operator:** The delete-confirmation input has only a placeholder, dynamic alerts lack live-region semantics, and document session state is conveyed by a color dot without a text label.

**Riley, stress tester:** Secret rotation has a much weaker guardrail than tenant deletion despite its broad blast radius. Riley can also reach deep document tooling whose tabs, tables, and status indicators do not have corresponding CSS.

## Minor Observations

- “SN” should be written as “Sequence number” unless the abbreviation is established nearby.
- Error text such as “Failed to load tenant” should distinguish likely cause and give a recovery action.
- The Git Objects empty state is good contextual guidance and should be the model for other empty states.
- Confirmation states have no Escape-to-cancel behavior.
- No product context or design authority files exist yet; this critique therefore uses the implementation itself as visual evidence.

## Questions to Consider

- Why does secret rotation get less protection than tenant deletion when it can disconnect every client signed with that secret?
- What would change if document investigation—not generic tenant CRUD—set the visual language for the whole admin site?
- Which identity should the client-configuration sample use at the API level, not only in its display copy?
