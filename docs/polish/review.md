# Keep, cut, change

Per tool, every visible element, with the principle it answers to (numbers from the polish brief: 1 every word, 2 consistency, 3 undo, 4 Mac, 5 show the data, 6 feedback, 7 less, 8 glass, 9 machine-made tells). Before shots are `1-part1-<tool>.jpg` (after the design-system pass), after shots `2-after-<tool>.jpg`.

## Prism Layer

| Element | Verdict | Why |
| --- | --- | --- |
| Header takeaway "3 layers, 10.41 mm total…" | cut | Repeats the three figures under it (1). |
| Three STAR values with copy buttons | keep | The data the tool exists for, side by side at one size (5). |
| Note "Wall functions, 1.2 stretching" | cut | Repeats the mode line and the Stretching field (1). |
| Note "Sum of the layers" / "The full boundary layer" | cut | Explains, doesn't change what you do (1). |
| Note "Goes in the prism control, not a surface size" | keep | Says where to paste it (1). |
| Capped notes ("Capped at a third of the gap") | keep | Only when capped; explains a surprising figure (6). |
| Copy tooltip "Copy 10.41" | change | "Copy": the figure is beside it (1). |
| Achieved y+, Re, u*, δ row | keep | Data to check the result against (5). |
| Warning capsules | keep | Each says what to check (6). |
| "Preset" label and "Choose" menu | change | One "Preset" menu (1). |
| Disabled segmented control and "Set by Target y+" | change | One plain line naming the mode; a segmented control that can't be clicked breaks the control's meaning (2). |
| Gap hint "floor to ground, arm to floor, slot gap" | cut | The label says it (1). |
| "Every value must be a number above zero…" pane and takeaway | change | Critical outline on the bad field with the fix under it (7, principle 1 and 6). |
| Velocity, density, viscosity, reference length typed by hand | change | Start from Wing Lab's speed, air and main chord; a typed value stays typed per project; "Use project values" goes back (5, context over input). |
| Every input | change | Undoable, named in Edit ▸ Undo (3). |
| How it's calculated | keep | The tool's one background disclosure (1). |

## Jobs

| Element | Verdict | Why |
| --- | --- | --- |
| Header note "Every engine run, with its progress, log and result." | cut | Restates the screen (1). |
| Job rows: status icon, title, time, progress, one-line message | keep | Enough to pick a job without opening it (5). Times in monospaced digits (8). |
| Centred "No Job Selected" | cut | The newest job shows until you pick another, so there's always data (5). |
| Centred "No Jobs Yet" with a pointer to the Project screen | change | Left-aligned empty state with Ping engine as its button (9). |
| Detail title in `.title2` bold | change | Headline 20 semibold, the system's level (8). |
| Cancel and Show in Finder as system buttons | change | sage37 glass buttons; Reveal in Finder, the Mac's own words (2). |
| Run again | new | Listed action; also on the row's right-click and the Jobs menu (4). |
| Command and job id line | keep | Metadata in a caption, the one place it belongs (8). |
| Failure and result.json group boxes | change | Flattened: a line and an inset block inside the one pane, no box in a box (5, 9). |
| Log console | change | Plain monospaced lines on a solid tube, no glow or uppercase (Part 1). |
| Right-click on a row | new | Reveal in Finder, Copy Log, Run Again, Cancel Job (4). |
| Jobs menu | new | The same four, ⌘. cancels, ⇧⌘R reveals, enabled on the Jobs screen (4). |

## Project

| Element | Verdict | Why |
| --- | --- | --- |
| Header note "Open a project or start a new one." | cut | The buttons say it (1). |
| Two system grouped Forms inside the pane | change | One pane, titled groups of rows on the inset tint with hairlines (2, 5). |
| "AeroBench" section header over New/Open | change | Left-aligned "No project open" headline, one line on what a project is, New project as the one prominent button (9). |
| Footer about project.json | keep | Shortened; it says which folder to pick when opening (1). |
| Recent projects | keep | Name and parent folder; right-click adds Open and Reveal in Finder (4). |
| Name, Folder, Created, Saved, Notes | keep | Plain rows; Notes gets an example prompt in place of an empty box (1). |
| Engine checks rows | keep | sage37 buttons; the dummy job's duration and Keep mesh remembered (2, 5). |
| Toolbar Show in Finder | change | Reveal in Finder, also File ▸ Reveal Project in Finder (4). |
| Ping Engine, Run Dummy Job | change | Also in the Jobs menu (4). |

## Lap Sim

| Element | Verdict | Why |
| --- | --- | --- |
| Header note "Lap time against ClA and CdA on the event tracks." | cut | Restates the screen (1). |
| Clay banner "Values marked est. are placeholder estimates… Every value here is editable and saved…" | change | One line, "est. marks a placeholder, not team data", inside the Car group it describes (1). |
| System grouped Form inside the pane | change | Titled groups of rows on the inset tint, one container level (2, 5). |
| Track picker | keep | Same order and names. |
| Layout stepper and Another Layout | change | The stepper alone: two controls did the same thing (2). |
| Generated-track, test-track and FSG/FSI paragraphs | change | Into How it's calculated (1). |
| Edit a Copy… tooltip explaining Done and Cancel | cut | The sheet's buttons say it (1). |
| Cars stepper tooltip | cut | Repeats what the grid shows (1). |
| Car grid | keep | Recessed fields, monospaced digits, the est. tag; every value undoable (3, 8). |
| Copy A to the Others, Reset to placeholders | change | sage37 glass and plain buttons; both undoable (2, 3). |
| Load-transfer footer | change | Into How it's calculated (1). |
| Run Lap Sim at the bottom of the setup form, and again in the empty state | change | One prominent Run lap sim at the top of the results pane, always visible; Lap Sim ▸ Run Lap Sim ⌘R (2, 4). |
| Centred "No Lap Sim Results" | change | Left-aligned headline and one line (9). |
| Results title in `.title2` bold | change | Headline 20 semibold (8). |
| Summary grid | keep | The answer, monospaced digits (5). |
| Sensitivities group box inside the scroll inside the pane | change | Flat section; the exchange-rate definition moves to How it's calculated, the decision rule stays (1, 5). |
| Chart group boxes | change | Flat titled sections (9). |
| System segmented car pickers | change | `S37Segmented` (2). |
| Track editor Undo button and its private history | change | Edit ▸ Undo with named actions ("Undo Move Point 3"); Done is one undoable "Edit Track" in Lap Sim (3, 4). |
| Track editor Loop picker | change | `S37Segmented` (2). |
| Track editor "Drive it the other way round" and "Start again from a copy" tooltips | cut | Repeat their labels (1). |
| Track editor instructions | change | Two paragraphs to one (1). |
