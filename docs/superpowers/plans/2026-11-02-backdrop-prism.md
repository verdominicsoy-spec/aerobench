# Per-tab backdrops and Prism Layer re-layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dot grid and shared airfoil bloom with a quiet line-art motif per tool, and put the Prism Layer tab in sage37 reading order.

**Architecture:** `S37Root` takes an `S37Motif` (plain, wing, track, floor, vortex, prism); `S37Backdrop` draws it in one Canvas, keyed by motif so it redraws only on a switch or resize, cross-faded under the refraction. Prism Layer publishes its live takeaway through a preference key the tool header reads, and its view becomes a lead row over two columns.

**Tech Stack:** SwiftUI, Canvas, macOS app target (file-system synchronised groups, so new files need no project edit).

**Spec:** `docs/superpowers/specs/2026-11-02-backdrop-prism-design.md`

## Global Constraints

- No animation loop, no scroll-linked drawing; backdrop redraws only on motif change or resize.
- Cross-fade 0.36 s; none with Reduce Motion. Increase Contrast stays plain `bg`.
- Dot grid removed everywhere.
- STAR setting names unchanged, each on one line; console column at least 460 pt.
- All sizes on the 4 pt grid.

## Review Focus

- A 900 pt-wide window: Prism Layer columns must not overlap or clip; console names stay on one line.
- Invalid Prism inputs (zero velocity, stretching 1): the takeaway says what to fix, no crash.
- Switching tools quickly: the cross-fade must not leave two motifs stacked.
- Content scrolled to the bottom: nothing hidden under the dock.
- Labels in the header corner still read over the Wing Lab streamlines.

These are checked by running the app (Task 3); the change is visual, with no logic a unit test would pin.

---

### Task 1: Per-tab motifs

**Files:**
- Create: `app/AeroBench/S37Motifs.swift`
- Modify: `app/AeroBench/Sage37.swift` (backdrop and `S37Root`)
- Modify: `app/AeroBench/Views/ContentView.swift` (`Tool.motif`, pass to `S37Root`)

**Interfaces:**
- Produces: `enum S37Motif: Equatable { case plain, wing, track, floor, vortex, prism }`, `S37Root(motif: S37Motif) { content }`, `extension Tool { var motif: S37Motif }`.

- [ ] Add `S37Motif` and one drawing function per case in `S37Motifs.swift`: `static func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ motif: S37Motif)`. Every case fills `bg` and the faint ochre glow first. Wing: Joukowski streamlines round an inverted section pitched 9°, top-right band, alpha fading toward the left. Track: skidpad rings plus a contour racing line, bottom right. Floor: perspective grid in the bottom third, fading to the horizon. Vortex: a von Kármán street trailing right. Prism: horizontal lines along the bottom, gaps growing 1.2 times upward.
- [ ] `S37Backdrop(motif:)` equatable on `motif`; `S37Root` gains `var motif: S37Motif = .plain`, cross-fades with `.id(motif)` and `.transition(.opacity)`, animation nil under Reduce Motion.
- [ ] Delete the dot grid and the airfoil bloom (no other references).
- [ ] Map `Tool.motif`: project and jobs plain, wingLab wing, lapSim track, cadViewer floor, flowField vortex, prismLayer prism.
- [ ] Build: `xcodebuild -project AeroBench.xcodeproj -scheme AeroBench build`, expected `** BUILD SUCCEEDED **`.

### Task 2: Prism Layer re-layout

**Files:**
- Modify: `app/AeroBench/Views/PrismLayerView.swift`
- Modify: `app/AeroBench/Views/ContentView.swift` (`ToolHeader` takeaway)

**Interfaces:**
- Produces: `struct ToolTakeawayKey: PreferenceKey` (`String?`, last non-nil wins); `ToolHeader(selection:takeaway:)` shows `takeaway ?? selection.note`.

- [ ] Prism Layer sets `.preference(key: ToolTakeawayKey.self, value:)`: "5 layers: 2.933 mm first cell, 22.12 mm in all." or, with bad inputs, "Every value must be above zero, and stretching above 1."
- [ ] Lead row: `S37Spotlight` (label "Near wall thickness", note "Prism Layer Near Wall Thickness in STAR") beside a stat strip pane with Layers, Total, Reynolds cells; under 10 layers the Layers cell carries a clay capsule "Lower the stretching".
- [ ] Below: inputs as an `s37Pane` of three groups (Flow, Element, Also needed) with one-line fields (label, field, unit) and one-line notes whose full text is a `.help` tooltip, plus a collapsed "Where the numbers come from" `DisclosureGroup`; console on the right with `minWidth: 460`.
- [ ] One `ScrollView` for the page, bottom padding clearing the dock.
- [ ] Build, expected `** BUILD SUCCEEDED **`.

### Task 3: Check and commit

- [ ] Run the app at about 900 pt and full screen; visit every tab and walk the Review Focus list.
- [ ] Commit spec, plan and code.
