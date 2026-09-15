---
name: Floodgate
description: A powder-coated operations status wall for a fault-isolated Fluid server on the BEAM.
colors:
  command-navy: "#10233f"
  raised-navy: "#183458"
  command-ink: "#172b46"
  secondary-ink: "#496078"
  warm-paper: "#f4f0e6"
  reading-panel: "#fffdf7"
  divider: "#b7c1cb"
  structural-line: "#8292a3"
  action-yellow: "#f0b429"
  action-yellow-soft: "#f8dc7e"
  fault-red: "#d94f59"
  healthy-green: "#16845b"
  protocol-blue: "#2f6fb2"
  link-blue: "#1d5f9b"
  navy-reading-text: "#dce7f2"
typography:
  display:
    fontFamily: '"Barlow Condensed", "Arial Narrow", sans-serif'
    fontSize: "clamp(3rem, 7vw, 5.5rem)"
    fontWeight: 700
    lineHeight: 0.92
    letterSpacing: "-0.025em"
  headline:
    fontFamily: '"Barlow Condensed", "Arial Narrow", sans-serif'
    fontSize: "clamp(2rem, 4vw, 3.15rem)"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "-0.015em"
  body:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "1.0625rem"
    fontWeight: 400
    lineHeight: 1.65
    letterSpacing: "normal"
  lede:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "clamp(1.15rem, 2.2vw, 1.45rem)"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "normal"
  label:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "0.78rem"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "0.08em"
  mono:
    fontFamily: '"SFMono-Regular", Consolas, "Liberation Mono", monospace'
    fontSize: "0.82rem"
    fontWeight: 700
    lineHeight: 1.55
    letterSpacing: "-0.015em"
rounded:
  control: "3px"
  code: "4px"
  panel: "5px"
  shell: "8px"
  pill: "999px"
spacing:
  xs: "0.5rem"
  sm: "1rem"
  md: "1.5rem"
  lg: "2.5rem"
  xl: "4.5rem"
components:
  action:
    backgroundColor: "{colors.command-navy}"
    textColor: "{colors.reading-panel}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "0.75rem 1.1rem"
    height: "3rem"
  action-hover:
    backgroundColor: "{colors.action-yellow}"
    textColor: "{colors.command-navy}"
    rounded: "{rounded.control}"
  command:
    backgroundColor: "{colors.command-navy}"
    textColor: "{colors.reading-panel}"
    typography: "{typography.mono}"
    rounded: "{rounded.code}"
    padding: "1rem 1.1rem"
  copy-control:
    backgroundColor: "{colors.action-yellow}"
    textColor: "{colors.command-navy}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "0.4rem 0.65rem"
    height: "2.4rem"
  reading-panel:
    backgroundColor: "{colors.reading-panel}"
    textColor: "{colors.command-ink}"
    rounded: "{rounded.panel}"
    padding: "clamp(1.25rem, 4vw, 3rem)"
  launch-panel:
    backgroundColor: "{colors.action-yellow}"
    textColor: "{colors.command-navy}"
    rounded: "{rounded.panel}"
    padding: "clamp(1.25rem, 3vw, 2rem)"
---

# Design System: Floodgate

## Overview

**Creative North Star: "The Operations Status Wall"**

Floodgate looks like a powder-coated incident-command surface, not a generic developer landing page. Deep navy shells hold warm white reading plates, yellow action plates, and blue operational panels. Inset lines, visible fasteners, status lamps, and colored state rails make each unit feel replaceable and independently monitored.

The system is dense but calm. Large condensed headings state the operating claim; plain body text explains it; monospace tags and commands show the machine evidence. Fault, restart, and recovery stay visible as neighboring states rather than becoming decoration.

**Key Characteristics:**
- Powder-coated navy, white, yellow, and blue panel materials.
- Structural borders, inset rims, fasteners, and state rails instead of generic cards.
- Condensed display type paired with readable system text and compact monospace evidence.
- A warm ruled-paper field behind a compact, bounded operations shell.
- Progressive enhancement and explicit motion, contrast, and focus behavior.

## Colors

The palette combines a dark command shell and warm reading field with one action color and three operational state colors.

### Primary
- **Command Navy:** The main shell, navigation, command background, primary action, and structural ink.
- **Raised Navy:** Hovered navigation and scrollbar thumbs; use it only to lift an element within a navy field.
- **Action Yellow:** The active navigation state, launch plate, copy controls, focus outlines, selection, and recovery sweep.
- **Soft Action Yellow:** Linked text on navy and highlighted success copy inside blue panels.

### Secondary
- **Protocol Blue:** Protocol evidence panels, neutral state lamps and rails, and the docs panel top edge.
- **Link Blue:** Inline links on light reading surfaces.

### Tertiary
- **Fault Red:** Process failure and destructive or fault state rails.
- **Healthy Green:** Recovered and ready states, including footer status and successful log lines.

### Neutral
- **Warm Paper:** The ruled page field around all panels.
- **Reading Panel:** Warm white for readable panel interiors and text on navy.
- **Command Ink:** Main body text and strong headings on light surfaces.
- **Secondary Ink:** Notes, metadata, log tags, and lower-emphasis text.
- **Divider:** Row separators and quiet rules.
- **Structural Line:** Strong panel edges and hierarchy separators.
- **Navy Reading Text:** Long-form supporting text on dark panels.

### Named Rules

**The State Has a Name Rule.** Never rely on red, yellow, green, or blue alone. Pair every state color with a tag, label, or outcome.

**The Yellow Means Action Rule.** Reserve solid yellow for active navigation, launch surfaces, copy controls, focus, selection, and the recovery transition. Do not use it as ambient decoration.

**The Warm Field Rule.** Reading surfaces are warm paper or warm white; do not introduce cool gray application backgrounds.

## Typography

**Display Font:** Barlow Condensed (with Arial Narrow and sans-serif fallback)  
**Body Font:** The platform UI stack (with Segoe UI and sans-serif fallback)  
**Label/Mono Font:** SFMono-Regular (with Consolas, Liberation Mono, and monospace fallback)

**Character:** Barlow Condensed gives the wall compact, high-authority labels without consuming horizontal space. The system body stack keeps long explanations familiar and legible, while monospace is limited to commands, paths, routes, tags, and machine output.

### Hierarchy
- **Display** (700, fluid display scale, 0.92): Page promises and document titles. Keep hero promises near 19 characters per line and document titles near 15.
- **Headline** (700, fluid section scale, 1): Section rules, panel headings, and operational group names.
- **Body** (400, base reading scale, 1.65): Explanations and docs. Keep paragraphs at a maximum reading measure of 70 characters.
- **Lede** (400, fluid introductory scale, 1.5): The first explanatory paragraph on the hero; keep it to approximately 57 characters per line.
- **Label** (700, compact scale, 0.08em): Uppercase paths, modes, and utility metadata.
- **Mono** (700, compact scale, 1.55): Commands, log tags, HTTP methods, routes, and counters; disable ligatures in inline code.

### Named Rules

**The Three Voices Rule.** Use condensed type for human-facing authority, the body stack for explanation, and monospace only for machine-facing evidence.

**The Short Display Rule.** Balance display headings and constrain their measure. Do not use the condensed face for paragraphs.

## Layout

The desktop shell is bounded at 74rem and centered. Main content uses fluid side padding from 1.25rem to 2.5rem, fluid top padding from 1.5rem to 3.5rem, and 6rem of closing space. The page background has a 2rem horizontal rule rhythm; recurring component spacing follows the extracted 0.5rem, 1rem, 1.5rem, 2.5rem, and 4.5rem scale.

The first viewport uses a 12-column wall. The promise spans all columns, then the recovery plate takes eight columns and the fixed launch plate takes four. At 54em and below, both plates span the wall; the launch plate first becomes a two-column internal layout. At 44em and below, it becomes a block and moves before the recovery proof so the launch command remains early without hiding the recovery story.

Architecture uses a flexible content column and a 17rem sticky system-map rail. At 64em and below, the rail moves above the article and becomes static; its links form two columns until 44em, then one. The process tree uses nested semantic lists with continuous blue connector rails; node names and descriptions share one compact row on wide screens, while descriptions move below their node names on narrow screens. Docs use a 62rem reading plate. Reference rows become true three-column tables at 60em and stay stacked below it.

Every docs surface places the complete section navigation between its breadcrumb and title. The navigation uses an adaptive equal-width grid with the current page on yellow; below 44em it becomes two columns so all destinations remain visible without horizontal scrolling.

At 44em and below, navigation wraps to a full-width row, the path disappears, body text drops to 1rem, log rows collapse or tighten, and the mobile proof strip summarizes the isolation result. Sticky search moves lower to clear the wrapped navigation. Preserve source order, reading order, and usable controls when a grid changes.

**The Neighbor Isolation Rule.** Large surfaces may share a wall, but each must keep its own border, inset rim, state rail, and padding. Do not merge operational units into an undifferentiated feature grid.

## Elevation & Depth

Depth is structural, not atmospheric. Powder texture, dark outer strokes, inset rims, and restrained navy-tinted shadows make panels read as coated plates mounted to the wall. Flat text sections remain on the ruled paper. Increased-contrast mode removes panel shadows, so borders and tonal separation must carry the hierarchy by themselves.

### Shadow Vocabulary
- **Mounted Panel** (`0 18px 42px rgba(16, 35, 63, 0.12)`): Shared outer shadow for hero, docs, and architecture plates.
- **Sticky Search** (`0 10px 24px rgba(16, 35, 63, 0.18)`): Stronger compact shadow for the sticky grep bar.
- **Powder-Coat Inset:** A one-pixel structural rim plus a soft inset navy tint; use on mounted colored and reading plates.
- **State Sweep:** A temporary yellow inset wash plus the row's own 0.45rem state rail; use only for the recovery sequence.

### Named Rules

**The Mounted, Not Floating Rule.** A panel earns depth through an outer stroke, inset rim, material texture, and visible fasteners. Do not use a shadow by itself to make a generic card.

**The Contrast-Safe Structure Rule.** Every elevated surface must remain distinct when shadows are removed.

## Shapes

The system uses compact industrial corners: 3px for controls and navigation, 4px for code and search fields, 5px for mounted plates, and 8px only for the enclosing hero shell. Full pills are reserved for small status chips and scrollbar thumbs. Borders are visible and structural: mounted panels use approximately 0.22rem to 0.24rem outer strokes plus inset one-pixel rims.

Fasteners belong at exposed panel corners. Large shells use all four corners; inset proof, launch, and docs plates use the exposed top pair unless their mounting context calls for all four. State vocabulary combines a circular lamp with a vertical rail. Architecture navigation uses rectangular rails because it maps systems rather than reporting a live event.

Icons are authored SVG marks, not font glyphs. Use a 20px view box for inline arrows, round line caps and joins, current-color strokes, and `aria-hidden` on decorative icons. External-link and text-action arrows use source SVG assets.

**The Tight Radius Rule.** Corners must look fabricated, not soft. Do not apply large consumer-app radii to plates or controls.

## Components

### Actions
- **Shape:** Compact rectangular control with a 3px corner and 2px navy border.
- **Primary:** Navy with warm white text, strong weight, at least 3rem high, and 0.75rem by 1.1rem padding.
- **Hover / Focus:** Hover swaps to yellow on light fields and warm white on the yellow launch plate. Keyboard focus uses a 3px yellow outline with a 4px offset.
- **Text action:** Underlined yellow text on navy with an authored right-arrow asset; use for an explanatory route, not the principal launch action.

### Commands
- **Style:** Navy 4px code bar, monospace command, yellow `$` prompt, and an end-aligned yellow copy control. On the yellow launch plate, invert the command field to warm white with a navy border.
- **Behavior:** Hide copy controls until JavaScript is ready. Announce copy status through the button, reset after three seconds, and select the command as a manual fallback when clipboard access fails.
- **Warnings and output:** Put destructive consequences immediately after the command and bind them to the copy control with `aria-describedby`. Use separate green output fields for successful responses.

### Mounted Panels
- **Corner Style:** 5px plate corners inside the 8px hero shell.
- **Background:** Navy, warm white, yellow, or protocol blue according to function.
- **Shadow Strategy:** Mounted-panel shadow plus an inset structural rim; shadows disappear in increased-contrast mode.
- **Border:** Dark or state-colored outer stroke, with fasteners and powder texture.
- **Internal Padding:** Fluid 1.25rem to 3rem, based on reading density.

### Recovery Log
- **Style:** Ruled rows with a lamp, compact monospace tag, message, and a left state rail.
- **State:** Blue is normal, red is failure, yellow is restart, and green is resumed or untouched. The words remain visible when color is unavailable.
- **Motion:** Failure, restart, and recovery rows sweep in sequence over 5.5 seconds with an emphasized deceleration curve. Disable the sequence under reduced motion.

### Documentation
- **Reading plate:** Warm white, no more than 62rem wide, with blue top edge, structural outer border, top fasteners, and mounted-panel depth.
- **Hierarchy:** Breadcrumb-like uppercase node head, large condensed title, 70-character body measure, ruled lists, and explicit previous/all/next footer links.
- **Reference rows:** Stack by default and align into three columns at 60em. Inline code uses a muted red-brown to separate symbols from prose without treating them as errors.
- **Filter:** Sticky navy grep bar with a warm white search field, live result count, highlighted matches, `/` focus, and Escape clear/blur behavior. Keep it hidden when JavaScript is unavailable.

### Navigation
- **Style:** Sticky navy top bar with a 4px yellow lower edge, condensed uppercase brand, compact path, and right-aligned site links.
- **State:** Current page is solid yellow with navy text; hover and focus use raised navy. Set `aria-current="page"`.
- **Mobile:** Hide the path and wrap site links into an equal-width full row at 44em.

### Architecture Rail
- **Style:** Sticky navy map plate with one labeled colored rail per anchor and ruled navigation rows.
- **Responsive:** Move above the article at 64em and use two columns, then one column at 44em.

### Accessibility Behavior

Provide a keyboard-revealed skip link, visible focus on links and controls, semantic headings and navigation labels, and text labels for every colored state. Decorative SVGs and fasteners stay outside the accessibility tree. Live copy and filter messages use polite announcements. Under `prefers-reduced-motion: reduce`, remove smooth scrolling and the recovery animation. Under `prefers-contrast: more`, darken secondary text and rules and remove shadows.

### Asset Provenance

Every shipping raster must have a source-adjacent provenance record. The powder texture records its authored SVG source and rasterization method in `public/materials/PROVENANCE.json`. The Open Graph raster has its own `.provenance.json` with direction, seed, authored HTML source, generator, date, and dimensions. Keep authored SVG icons and fasteners as source assets; regenerate derived rasters from their recorded source rather than editing the raster.

## Do's and Don'ts

### Do:
- **Do** keep the navy shell, warm reading field, yellow action plate, and labeled red/green/blue state system.
- **Do** construct important surfaces from border, inset rim, powder texture, fasteners, and restrained depth.
- **Do** preserve the 70-character reading measure and the display/body/mono role split.
- **Do** keep launch commands copyable, warnings adjacent, and no-JavaScript states honest.
- **Do** preserve keyboard focus, skip navigation, reduced-motion, and increased-contrast behavior.
- **Do** attach provenance to each shipping raster and record enough information to regenerate it.

### Don't:
- **Don't** replace the wall with a generic hero followed by interchangeable feature cards.
- **Don't** use state colors without a textual tag or outcome.
- **Don't** use large soft radii, borderless floating cards, or shadow as the only depth cue.
- **Don't** turn monospace into a body face or Barlow Condensed into paragraph text.
- **Don't** show inert copy or search controls before their behavior is available.
- **Don't** introduce untraceable raster decoration or hand-edit a generated raster.
