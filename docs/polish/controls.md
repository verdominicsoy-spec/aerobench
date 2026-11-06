# One control language

The mapping every screen follows (principle 2: one control looks and behaves one way everywhere).

| Job | Control | Notes |
| --- | --- | --- |
| The one thing the screen is for (Run, Design, Open) | `S37ButtonStyle(kind: .prominent)` | One per tool view. Never two side by side. |
| Any other action | `S37ButtonStyle()` (glass) | Verb first, sentence case. |
| Quiet or inline action, Cancel, Later | `S37ButtonStyle(kind: .plain)` | Sage text, no fill. |
| Icon-only action in a toolbar row | `S37ButtonStyle()` with `.labelStyle(.iconOnly)` | Accessibility label required. |
| Switching views of the same thing | `S37Segmented` | Never for actions, never disabled as a status display. |
| A number with a unit | `S37FieldRow` | Label left, recessed field, unit. Errors outline the field in critical with the fix under it. |
| A setting that applies at once | `Toggle` (`.switch`) | Label names the thing switched on. |
| A count in a small range | `Stepper` | Native: sage37 has no equivalent. Value shown left of it. |
| A choice from many, or a list of actions | `Menu` / `Picker(.menu)` | Native, `.menuStyle(.borderlessButton)` where it sits in a row. |
| What's missing | `S37EmptyState` | Left-aligned headline, one line, the action as a button. Never `ContentUnavailableView`. |
| Program output | `GOScreen` | Jobs log only. |

Grouping: one container level per section (`s37Pane` or `s37Region`), groups inside it with spacing, hairlines and `inset` tints. No `Form(.grouped)`, `GroupBox` or cards inside panes.
