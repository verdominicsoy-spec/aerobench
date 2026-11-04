AeroBench polish pass
Paste everything below the line into a Claude Code session in /Users/warthog/aerobench.

----------------------------------------------------------------------

You're polishing AeroBench, a native macOS SwiftUI app (app/AeroBench, logic in app/AeroBenchKit). I use it alone as a Formula Student aero engineer. It's a working tool I spend hours in, not a product for strangers. The goal is an app that's easier to use and stops feeling machine-made. You're cleared to change AeroBench. Behaviour and numbers must not change unless an item below says so.

GROUND RULES

- Load the sage37-swift skill and the glassout-swift skill and follow them. Both were rewritten in November 2026 to follow the usability research below, so where AeroBench's own Sage37.swift or Glassout.swift disagrees with the skill, the skill wins and the app's file changes.
- Optimise for one expert user on a Mac: density, keyboard, speed and habit beat discoverability and hand-holding.
- Do the shared design-system changes first (part 1), then go one tool at a time in this order: Prism Layer, Jobs, Project, Lap Sim, Flow Field, CAD Viewer, Wing Lab (biggest, last).
- For each tool: screenshot it, list every visible element as keep / cut / change with a one-line reason tied to a principle below, make the changes, screenshot again (save before and after to docs/polish/shots/), run swift test in app/AeroBenchKit and the Debug build, then commit that tool on its own.
- When an item says cut, cut it. Don't move the text into a tooltip instead.
- Don't add features. Undo, menus, shortcuts and right-click menus are the only new behaviour, and they're listed.
- Run graphify update . after code changes.
- If something here would break a workflow I rely on, stop and ask instead of guessing.

THE PRINCIPLES AND WHERE THEY COME FROM

These come from published sources, not taste. Cite the one you're applying when you justify a change.

1. Every word earns its place. Apple HIG, Writing: check each word, use fewer if you can, most important first, verb labels, errors next to the problem saying how to fix it, no "we". Nielsen heuristic 8 (aesthetic and minimalist design).
2. Consistency and standards. Nielsen heuristic 4, Jakob's law: one control looks and behaves one way everywhere, the way Mac apps already work. Raskin, The Humane Interface: one way to do each thing so use becomes habit; no hidden modes.
3. User control and freedom. Nielsen heuristic 3: undo and redo for every edit.
4. The Mac is keyboard, menus and precision. Apple HIG, Designing for macOS: every command in the menu bar, keyboard shortcuts, more content in fewer nested levels with less modality, resizable windows.
5. Show the data, minimise interaction. Bret Victor, Magic Ink: design the display first, put enough on screen to decide without clicking, use context and history so I type less, make every action change something visibly at once. Tufte: spend ink on data, erase non-data ink.
6. Status and feedback. Nielsen heuristic 1, Norman, Doherty threshold (about 400 ms): every action answers immediately and visibly.
7. Less, but better. Rams, principles 5 and 10.
8. Glass belongs to the functional layer. Apple HIG, Materials: Liquid Glass for controls and navigation, never the content layer, used sparingly.
9. What reads as machine-made (impeccable.style's catalogue, the Fountain Institute's seven tells, cross-checked): glass as decoration, glowing accents on dark, patterned backgrounds, nested cards, the hero-metric layout, tiny uppercase tracked labels, flat grey type hierarchy, label + sublabel + hint + tooltip repeating one point, centred everything, bouncy easing, identical card grids. The common cause: nobody made a decision, so everything got the same default treatment.

PART 1: BRING THE DESIGN SYSTEM IN LINE (approved, do these)

- Content panes become solid. s37Pane and s37Region draw surface with a 1 pt separator hairline (controlBorder under Increase Contrast): no sheen, no gradient rim, no material. Delete Sage37Refract.metal, the layerEffect in S37Root, S37PaneKey, S37PaneFrame and S37PaneRegistration. S37Root becomes plain bg plus content.
- Backdrops go. Delete S37Motifs.swift and every S37Motif reference (Tool.motif in ContentView, the motif parameter on S37Root, motifCrossfade). Interfaces sit on plain bg. This reverses the space-filling curves added on 2 and 3 November on purpose: the sources call a patterned background non-data ink and a machine-made tell.
- Motion eases out with no overshoot. S37.Motion.press, toggle, thumb and lens become timingCurve(0.2, 0, 0, 1) at 0.24, 0.28, 0.36 and 0.32 s. The dock thumb settles rather than springs.
- Retire S37Spotlight from the app (it's unused since Prism Layer dropped it; delete it).
- Header: the tool title drops to Fraunces 24 (title-sm), since the dock already names the tool. Keep the takeaway only where it says something the screen doesn't show (Prism Layer's currently repeats its three values: remove it there).
- Glassout to the new spec: GOScreen becomes a solid tube with a separator hairline (no bezel, no glass rim, no shadow); delete GOTubeCRT, GOGlow and every glow modifier, the faceplate sheen and goTubeInset; GOMeta, GOPlainButton and every label drop .textCase(.uppercase) and tracking; GOPlainButton loses its [ ] brackets. The Jobs log (LogView) is the only console left and becomes plain monospaced lines.

PART 2: WHY AEROBENCH FEELS MACHINE-MADE TODAY (measured on 3 November)

- Too many words. 81 explanatory strings over 60 characters in Views/, 54 .help() tooltips, 205 .font(.caption...) uses and 128 .foregroundStyle(.secondary). Screens carry header notes, section notes, field hints and tooltips that overlap.
- Two control languages. 119 plain Button("...") with system styling against 13 S37ButtonStyle buttons. Ten system .pickerStyle(.segmented) pickers (CADViewerView 90 and 314, LapSimView 367, FlowFieldView 43 and 748, TrackEditorView 80, WingLabView 667, 1690, 1818, 2020) beside S37Segmented. Nine system Forms with grouped sections inside sage37 panes.
- No undo anywhere. Zero UndoManager use.
- Thin menu bar. 14 keyboard shortcuts in the whole app; the menus have project items and Help. Running the panel solver, RANS or the optimiser, building a flow field and opening a CAD file aren't in any menu.
- Nesting. Cards inside sections inside panes: Wing Lab's "Live estimate" and "RANS CFD" mini cards, Lap Sim's Sensitivities group box inside a form section inside a pane.
- Modes and duplicate paths. Flow Field has Calibrate / Explore and, inside Calibrate, Quick Setup / All Settings. Wing Lab hides its results behind five tabs.
- Centred empty states. All 7 ContentUnavailableView uses are centred.
- Typing what the app already knows. Prism Layer asks for velocity and reference length the project already holds.

Line numbers may have moved; find the code by what it does.

PART 3: CHANGES PER TOOL, IN PRIORITY ORDER

1. Copy diet (1, 9). A sentence stays only if it changes what I do next. Remove header notes that restate the screen. One explanation per thing, never label + sublabel + hint + tooltip together. Background explanations go behind one "How it's calculated" disclosure per tool, or into the Solver Accuracy window. Keep a glossary in docs/polish/glossary.md (near wall thickness, reference length, y+, total thickness and so on) and use those words everywhere. Target: at least half the visible explanatory text gone, and no tooltip that repeats its label.
2. One control language (2). Write a mapping table first: primary action means S37ButtonStyle(.prominent), one per tool; other actions S37ButtonStyle(); switching views of the same thing means S37Segmented; dense field rows use one shared row component (label left, recessed field, unit). Then convert all 119 buttons, the ten system segmented pickers and the nine Forms. Native controls stay only where sage37 has no equivalent (Stepper, Menu), styled the same on every screen.
3. Undo and redo (3). Register undo through the environment's undoManager for every document edit: Wing Lab element add, remove, drag, section and number changes; track editor points; Lap Sim car values; Prism inputs. Edit > Undo names the action ("Undo Move Flap 1").
4. Menus and keyboard (4). A View menu with the seven tools on Cmd-1 to Cmd-7. One menu per tool for its actions, standard shortcuts where they exist, disabled when they can't run. Every button that runs something also exists in a menu. Right-click menus on list rows: a job gets Reveal in Finder, Copy Log and Run Again; a wing element gets Duplicate and Remove.
5. Flatten (5, 9). One level of container per section: group with spacing and hairlines, not boxes in boxes. Show results side by side when the window is wide enough (Wing Lab: pressure and polar together) instead of always tabbing. Every tool's panes fill the window and reflow (three columns, two, one), the way Prism Layer does now.
6. Context over input (5). Prism Layer, and any tool asking for flow conditions, starts from the project's own speed and lengths and remembers the last values per project. Edited values stay edited.
7. Errors at the field (1, 6). Replace Prism Layer's "Every value must be a number above zero..." with a critical outline on the offending field and a short fix under it. Same pattern everywhere input is validated.
8. Type hierarchy (9). At most three text levels per screen: value, label, note. Captions only for real metadata. Monospaced digits for numbers. Fewer grey captions overall.
9. Empty states (1, 9). Replace every ContentUnavailableView with a left-aligned headline, one plain line and the action as a button.
10. Modes (2). Fold Flow Field's Quick Setup and All Settings into one panel with the advanced fields behind a disclosure. Keep Calibrate / Explore only if they're really separate jobs, and if so make the current one unmistakable.

DONE MEANS

- Part 1 landed in its own commit, with before and after screenshots of every tool.
- Every tool has been through keep / cut / change, with shots in docs/polish/shots/.
- Visible explanatory text at least halved; no tooltip repeats its label.
- One control style per control type, app-wide; no glass on content; no backdrop pattern; no overshoot.
- Undo works for every document edit, and every action is in a menu.
- Tests pass and the build runs. One commit per tool.
- A short entry in docs/DECISIONS.md recording the November 2026 design-system changes and why.
