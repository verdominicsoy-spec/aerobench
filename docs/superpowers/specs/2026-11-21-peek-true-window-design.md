# Peek: a true window, not a controller

Replaces the exaggerated parts of the head-tracked peek (`2026-11-20-head-tracked-peek-design.md`) and undoes
`2026-11-21-peek-head-tilt-design.md` and `2026-11-21-peek-distance-gain-design.md`.

## Intent

The peek should feel like a window into the computer with the model inside it, not like steering the model with
your head. Your head moves your eye; the model never moves. In the user's words, the exaggeration is what made it
a gimmick: "it feels like a controller instead of a window".

## What it does

- **1:1.** Your eye moves through the angle your head really moves, seen from the glass. Nothing turns, rolls or
  speeds up on top of that.
- **Lean in like a real window.** Coming closer brings the eye closer in proportion (half the distance, half the
  eye distance), so the edges reveal more and nearby parts shift more. Sitting back does the opposite.
- **Behind the glass (tried, reverted).** Moving the window plane to the model's front made the depth less
  believable: a screen-sized room can't hold a model that fills the view from there, and a room wider than the
  screen hides its edges, which are what sell the box behind the screen. The plane stays through the orbit
  target, with the room's front edges on the screen's edges.
- **Unchanged:** Shift to peek, recentred at the press (pressing changes nothing until you move), the 0.15 s ease
  in and out, the grid room behind the glass, the key light and shadows, built-in display only.
- **Removed:** the sensitivity slider and its turn, the head-tilt roll, the distance gain.

## Approaches

1. **Keep the app's 35° lens and make the head movement real (chosen).** The eye moves through the real angle
   and real proportion of distance; the room behind the glass is scaled so the 35° view fills the pane. Pressing
   Shift changes nothing; parallax, edge reveal and depth all come from the geometry.
2. Exact physical scale: the window is the pane in cm and the eye your eye in cm. Rejected: the pane covers only
   about 15° of your vision, so the lens would have to narrow from 35° to 15°, flattening the model at every
   Shift press (or all the time) and cutting the parallax by more than half.

## How (the builder's calls, marked)

- **The eye.** With the head and its distance d in cm (measured live), and d₀ and the head at the Shift press:
  eye = rest + blend · (head − head at press) · rest.z / d₀, including z, so eye.z = rest.z · d / d₀ at full blend.
- **The distance.** From the eye gap, as now (median of three frames, then a slow One Euro filter), and it also
  feeds the head's sideways position (a 1 cm move at 30 cm is a bigger angle in the image than at 60 cm).
  *My call:* turning the head shortens the eye gap and reads as leaning back a little; the smoothing keeps it mild.
- **No calibration.** The distance is measured automatically from the eye gap. The spacing between your eyes
  is never needed: one webcam can't tell it apart from distance, and the eye only uses your distance relative
  to the Shift press, where the assumed 6.3 cm cancels exactly.
- **Orthographic views** keep the far-back eye; the same mapping gives a sheared look-around, as now.

## Non-goals

- Physical scale (approach 2). Head yaw and pitch. Stereo.

## Tests

- Press: the eye is the rest eye. A 10 cm sideways move at d₀ = 55 cm: atan(eye.x / eye.z) = atan(10 / 55).
- Leaning in to half the distance halves eye.z; blend 0 gives the rest eye exactly.
- The window plane: at the front of the bounds for a normal view; clamped to a quarter of the way when zoomed in.
- The removed pieces leave no settings key or slider behind.
