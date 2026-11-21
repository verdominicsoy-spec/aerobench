# Peek: the 3D view's lens matches the screen

Follows `2026-11-21-peek-true-window-design.md`, which kept the app's 35° lens.

## Intent

The 1:1 peek's depth still wasn't believable. The root cause: the 3D pane covers about 15–20° of your vision, but
the view is drawn with a 35° lens, so the peek moves the eye about 2.5 times less, against the screen frame, than
your real head moves. Your eyes check the depth against the real frame, and the depth inside shifts too little.
Drawing the view with the lens your screen really has makes the peek physically exact.

## What it does

- **The lens is the pane as you see it.** When the peek is on and the view is on the built-in display, the 3D
  view's vertical lens is the angle the pane covers from 55 cm: 2·atan(pane height ÷ 2 ÷ 55 cm), held to 10°–35°.
  A 16 cm tall pane gives about 17°.
- **Always, not just while peeking,** so pressing Shift changes nothing until you move.
- **No zoom when it changes.** When the lens changes (the peek turned on, the pane resized, the window moved to
  or from the built-in display), the camera moves in or out so the target plane shows the same area: only the
  perspective changes, never the framing.
- **Off, or on another display:** the 35° lens, as before.
- **Unchanged:** the 1:1 eye, leaning in, the room on the screen edges, orthographic views.

## Approaches

1. **The physical lens always (chosen).** Exact and with no jump at the press. The cost is a flatter, telephoto-like
   normal view, common in CAD, and the lens follows the pane's size.
2. The physical lens only while peeking. Rejected: the model visibly flattens each time Shift goes down.
3. The exaggerated 2× turn back. Rejected: it felt like a controller.

## How (the builder's calls, marked)

- *My call:* the lens assumes the 55 cm seat, the same as the peek's default. The camera only runs while peeking,
  so the lens can't follow your measured distance without changing at the press. The peek is exact at 55 cm and
  close nearby.
- *My call:* the lens is checked whenever the camera moves or the view is laid out, not on a timer, so moving the
  window between displays takes effect on the next move or resize.

## Tests

- The lens: a 16 cm pane at 55 cm gives 2·atan(8/55); a 2 cm pane holds at 10°; a 60 cm pane holds at 35°.
- Changing the lens keeps the target plane's half-height and the target, and moves the camera along forward.
