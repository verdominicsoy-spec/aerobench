# Peek: the closer you are, the more it moves

A small change to the head-tracked peek (see `2026-11-20-head-tracked-peek-design.md` and
`2026-11-21-peek-head-tilt-design.md`).

## Intent

While peeking, the model should move more for the same head movement the closer you sit to the screen, and
less the further back you are, and it should feel natural: no jumps, no wobble, no stretching.

## What it does

- **Inversely proportional to distance.** The peek's rate is the sensitivity slider × (55 cm ÷ your distance).
  At 55 cm (the peek's assumed seat) nothing changes; at 27.5 cm it is twice as lively; at 110 cm half.
- **Live during a peek.** Lean in while Shift is held and the rate rises as you come closer.
- **Everything uses it.** The sideways look (turn) and the head tilt (roll) both scale with it.
- **Natural feel.**
  - The distance is smoothed heavily (its own One Euro filter, slower than the head's, with no lead),
    so blinks and the pupil/eye-contour switch don't twitch the view. Leaning in takes effect over about
    half a second.
  - The factor is held between 0.5× and 2× (110 cm to 27.5 cm), so a misread face can't fling the view.
  - It fades in and out with the rest of the peek (blend), so pressing and releasing Shift stay smooth.
  - Before the first face it is 1×; when the face is lost it holds its last value while the head eases back.
  - The eye position used for the off-axis view keeps the locked 55 cm, so the view does not stretch.

## Approaches

1. **Scale the whole peek by the live factor (chosen).** The head's offset since Shift, times the factor.
   Bring your head back to where it was and the view comes back to where it was. Leaning in while looking
   off to the side turns the view a little further, as the gain rises.
2. Scale each new movement instead (add up head moves × the factor at that moment). Leaning in alone
   changes nothing, but the view drifts: returning your head no longer returns the view. Rejected: the
   window must always come back to straight on.

## How (the builder's calls, marked)

- **Measuring the distance:** from the gap between the two eye points the tracker already finds, assuming
  an average 6.3 cm between pupils and the webcam's 62° field of view:
  distance = 6.3 ÷ (2 · tan(31°) · gap as a fraction of the image width). *My call:* someone whose eyes are
  further apart or closer together just gets a slightly different overall rate, which the slider covers.
  Turning the head sideways shortens the gap a little and reads as slightly further; the smoothing and clamp
  keep that mild.
- **Where it lives:** the peek state filters the distance alongside the head and tilt; the viewer multiplies
  the slider by the factor.

## Non-goals

- Measuring distance for the eye position itself (tried on 20 Nov: it swung ±8 cm and stretched the view).
- A setting for the reference distance or the clamp.

## Tests

- Distance from the eye gap: a gap that puts you at 55 cm gives 55; half the gap gives 110.
- The factor: 1 at 55 cm, 2 at 27.5 cm, clamped at 2 closer than that and at 0.5 beyond 110 cm; 1 before a face.
- Smoothing: a sudden 20% jump in the gap moves the factor less than half way within 0.1 s, and settles in 2 s.
- Held when the face is lost.
