Pit Wall polish pass
Paste everything below the line into a Claude Code session in ~/Downloads/pitwall-port-kit.

----------------------------------------------------------------------

Pit Wall is my native macOS SwiftUI dashboard: Today, Lectures, FS intel, F1 and Roles behind one dock, kept current from the pitwall-data repo. The app target is PitWall/ (TodayView, LecturesView, FSView, F1View, F1Charts, RolesView, SyncConsole, Components, Dock, Shell, Bloom, Sage37), and the logic and tests are in PitWallCore/. It's built on my sage37 design system with a glassout sync console.

The goal is an app that's fundamentally easier to use and stops feeling machine-made. You're cleared to change Pit Wall. The data, the sync and every calculation in PitWallCore must not change.

GROUND RULES

- Load the sage37-swift and glassout-swift skills and follow them. Both were rewritten in November 2026 to follow the usability research below. Where Pit Wall's own Sage37.swift, Bloom.swift or SyncConsole.swift disagrees with a skill, the skill wins.
- Before changing anything, ask me briefly: who besides me uses Pit Wall, and what I open it for most days (the one or two questions it must answer at a glance). Default if I don't answer: just me, and Today is the screen that matters most.
- Do the shared design-system changes first (part 1), then one view at a time: Today, Lectures, FS intel, F1, Roles, Settings, the sync console.
- For each view: screenshot it, write down what it has to answer in two seconds and whether the first thing your eye lands on answers it, list every visible element as keep / cut / change with a one-line reason tied to a principle below, make the changes, screenshot again (before and after into docs/polish/shots/), run swift test in PitWallCore and the Debug build (README has the commands), then commit that view on its own.
- When an item says cut, cut it. Don't move the text into a tooltip.
- Don't add features. Menus, shortcuts, right-click menus and undo (where something is editable, such as applied ticks on Roles) are the only new behaviour.
- If something would break a workflow I rely on, stop and ask instead of guessing.

THE PRINCIPLES AND WHERE THEY COME FROM

Cite the one you're applying when you justify a change.

1. Show the data, minimise interaction. Bret Victor, Magic Ink. Pit Wall is pure information software, so this matters most: design the display before any interaction, put enough on screen to decide without clicking, arrange data so comparisons are visible, use context (time, date, what's next) and history so I don't navigate, and treat every click and every tab as a cost.
2. Spend ink on data. Tufte: maximise data ink, erase non-data ink and redundant data ink, no chartjunk. Apply it to F1Charts and every stat.
3. Every word earns its place. Apple HIG, Writing; Nielsen heuristic 8.
4. Consistency and standards. Nielsen heuristic 4, Jakob's law, Raskin's one way to do each thing and no hidden modes.
5. System status. Nielsen heuristic 1: how fresh the data is, and whether a sync is running, should be visible where you look, in plain words.
6. The Mac is keyboard, menus and precision. Apple HIG, Designing for macOS.
7. Glass belongs to the functional layer. Apple HIG, Materials: never the content layer, used sparingly.
8. Less, but better. Rams, principles 5 and 10.
9. What reads as machine-made (impeccable.style's catalogue, the Fountain Institute's seven tells): glass as decoration, glowing accents on dark, patterned or decorative backgrounds, nested cards, the hero-metric layout, tiny uppercase tracked labels, flat grey type hierarchy, label + sublabel + hint + tooltip repeating one point, centred everything, bouncy easing, identical card grids, status dots used as decoration.

PART 1: BRING THE DESIGN SYSTEM IN LINE (approved, do these)

- Content panes become solid surface with a 1 pt separator hairline. Delete the refraction shader (Sage37Refract.metal), its layerEffect and the pane registration. The root becomes plain bg plus content.
- The blooms leave the interface. Delete Bloom.swift's backdrop use and the bloom cross-fade; every view sits on plain bg. (The blooms stay in the design system for covers and slides only.)
- Motion eases out with no overshoot: timingCurve(0.2, 0, 0, 1) for press, toggle, thumb and lens. Views swap in place with a short opacity change, no rise.
- The spotlight tile and Fraunces hero figure leave the interface. Where a view leads with one big number beside small ones (Today's countdown, any stat row), replace it with a stat strip: equal cells, one figure size, ordered by what you read first.
- Header: no metadata line above the title; the tool title is Fraunces 24; the takeaway stays only if it says something the view doesn't already show.
- The sync console follows the new glassout: a solid tube with a hairline, no bezel, glow, scanlines, sheen or uppercase labels, no type-on reply, no bracketed buttons. Lines appear when printed.

PART 2: MEASURE BEFORE CHANGING

Record these per view in docs/polish/pitwall-audit.md before part 3, with numbers and file:line references: long explanatory strings, .help() tooltips, caption and secondary-text counts, system controls against sage37 components, keyboard shortcuts and menu commands, UndoManager use, container nesting depth, centred empty states, and how data age and sync state are shown.

PART 3: CHANGES PER VIEW, IN PRIORITY ORDER

1. Answer first (1). Whatever the view exists to answer is the first thing on screen, readable in two seconds, with no click.
2. Copy diet (3, 9). A sentence stays only if it changes what I do next. One explanation per thing. At least half the visible explanatory text gone; no tooltip repeats its label.
3. One control language (4). A mapping table first, then one style per control type across the app.
4. Data freshness (5). One plain line per tool ("Synced 2 h ago"), clay only if it's stale enough to matter, and the same wording everywhere.
5. Menus and keyboard (6). Tools on Cmd-1 to Cmd-6 in dock order; Sync and Sync all in a menu with shortcuts; every button that does something also in a menu; right-click on rows where an action applies.
6. Flatten (1, 9). One level of container per section; no cards in cards; sections fill the window and reflow from three columns to two to one.
7. Charts (2). Remove gridlines, borders and legends that direct labels can replace; one accent for the series that matters.
8. Empty and offline states (3, 9). Left-aligned headline, one plain line, the action as a button.

DONE MEANS

- Part 1 landed in its own commit with before and after shots of every view.
- docs/polish/pitwall-audit.md has the measurements.
- Every view has been through keep / cut / change, with shots.
- No glass on content, no background pattern, no overshoot, no hero number, no uppercase labels.
- Every action is in a menu; data age is visible and worded the same everywhere.
- Tests pass and the build runs. One commit per view.
