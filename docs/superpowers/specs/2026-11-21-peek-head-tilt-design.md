# Peek: head tilt turns the model the other way

A small change to the head-tracked peek (see `2026-11-20-head-tracked-peek-design.md`).

## Intent

While peeking (Shift held), tilting your ear toward your shoulder turns the model the other way in the
screen's plane, like turning a photo on a table. It adds to the sliding peek; it replaces nothing.

## What it does

- **Tilt is a roll about the line of sight.** Tilt your head clockwise (right ear down, as you see it) and the
  model turns anticlockwise on the screen by the same angle, times the peek sensitivity (default 2×: a 10° tilt
  gives 20°).
- **Recentred like the slide.** The tilt you hold when Shift goes down is level for that peek, so pressing Shift
  changes nothing until you tilt.
- **Eases with the peek.** It fades in and out with the rest of the peek (the same 0.15 s blend), so letting go
  of Shift settles it back to the normal view. When the face is lost the tilt eases back to level, as the head
  position does.
- **Smoothed like the head.** The tilt goes through its own One Euro filter, with the head position's settings.

## Approaches

1. **Roll the view in the screen's plane (chosen).** This is the direct reading of "the other way": it follows
   your head and settles when you stop, like the rest of the peek.
2. Tilt as a turntable knob (spin about the model's vertical axis, at a speed set by the tilt). Rejected: it's a
   control, not a window effect, and it keeps spinning until you straighten up.

## How (the builder's calls, marked)

- **Measuring the tilt:** the angle of the line between the two eye points the tracker already finds (pupils,
  else eye contours), in image pixels. No new Vision request. *My call:* the eye line rather than Vision's
  `roll`, which is quantised on older request revisions and would be a second source for the same face. The
  sign flips for mirrored frames, as the sideways head position does.
- **Applying it:** the peek's window frame (right, up) is rotated about forward by the roll. The camera's up,
  the eye's sideways offset, the window and the grid room all use the rotated frame, so the projection stays
  pinned to the view's edges. `OrbitCamera` gains no roll of its own: the normal view is untouched.
- **Lighting:** the key light stays on the un-peeked view, as now, so the shading stays put on the model.

## Non-goals

- Turning (yaw) and nodding (pitch) of the face. The sliding peek already covers looking around.
- Its own sensitivity slider. *My call:* the peek's sensitivity is used for both, so the settings stay one
  control.

## Tests

- The tilt sign from two eye points, plain and mirrored.
- The roll from the peek state: recentred at Shift, eased with the blend, back to level when the face is lost.
- The peek camera with a roll: the window corners stay at the view's corners, and the camera's up turns the
  stated way.
