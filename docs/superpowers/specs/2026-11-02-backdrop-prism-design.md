# Quieter per-tab backdrops, and a Prism Layer re-layout

Date: 2026-11-02. Size: a small change (two areas, no engine work).

## Intent

The backdrop competes with the content: a green dot grid covers the whole
window and the airfoil bloom sits right behind the right-hand panes, which
the refraction then magnifies. Every tab shows the same picture. The user
wants a less invasive background, one motif per tab. Separately, the Prism
Layer tab's hierarchy is out of order: the inputs lead, the answer is cramped,
and the console is clipped by the dock.

## Goals

- Each tool gets its own quiet line-art motif that says what the tool is for.
- Motifs stay out from under the panes: header band and gutters only, fading
  out before content.
- Prism Layer reads in sage37 order: title, takeaway with the live answer,
  spotlight plus stat strip, then inputs and console.

## Non-goals

- No new tool layouts other than Prism Layer.
- No change to the sage37 tokens, the refraction shader or the dock.

## Anti-goals

- Anything that animates on its own, follows scroll, or redraws per frame.
- A backdrop that makes any label drop below sage37's contrast rules.

## Approaches

1. **Per-tab motifs** (picked by the user). One Canvas drawing per tool,
   cross-faded on tool switch.
2. One shared quiet backdrop for every tab. Less code, but every tab still
   looks the same, which was part of the complaint.
3. Plain `bg` everywhere. Quietest, but loses what makes the glass panes read
   as glass (the refraction has nothing to bend).

## Backdrop design

- `S37Backdrop` takes the current `Tool` and draws that tool's motif. It is
  still `Equatable` on the tool, so it redraws only on a tool switch or a
  window resize. The switch cross-fades over 0.36 s (sage37 bloom crossfade);
  Reduce Motion swaps it instantly. Increase Contrast stays plain `bg`.
- The dot grid is removed from every tab.
- Line alpha roughly half of today's bloom (sage around 0.18, bone around 0.08).
  Motifs sit in the header band and the right or bottom gutters, with a fade
  to `bg` toward the centre.
- Motifs:
  - Project: plain `bg` with the faint ochre glow only.
  - Wing Lab: potential-flow streamlines round an inverted wing (Joukowski
    section, 9° pitch), header corner only, fading to the left.
  - Lap Sim: skidpad rings and a contour-style racing line, bottom right.
  - CAD: a perspective floor grid in the bottom third, fading to the horizon.
  - Flow Field: a von Kármán vortex street trailing off to the right.
  - Prism Layer: a stack of thin horizontal lines along the bottom edge, each
    gap 1.2 times the one below, like prism layers growing off a wall.
  - Jobs: plain `bg`.
- The airfoil bloom code stays in the file unused only if another view still
  references it; otherwise it is deleted.

## Prism Layer design

1. Header takeaway becomes the live result, such as "5 layers: 2.933 mm first
   cell, 22.12 mm in all." With bad inputs it says which input is wrong.
2. Lead row across the full width: the spotlight (near-wall thickness) and a
   stat strip of three cells: layers, total thickness, Reynolds number. The
   under-10-layers warning becomes a clay capsule in the layers cell.
3. Below, two columns: inputs on the left as sage37 panes (Flow, Element,
   Also needed), each field one line with its unit, notes cut to one line with
   the full text in a tooltip; the STAR console on the right, at least 460 pt
   wide, so every STAR name stays on one line. STAR names are not shortened.
4. "Where the numbers come from" becomes a collapsed disclosure under the
   inputs.
5. The scroll content gets a bottom inset that clears the dock.

## Calls made by Claude (check these)

- Motifs are drawn procedurally in Canvas, not from SVG assets: the design
  system's streamline SVGs are not on this machine.
- The Prism Layer motif uses a fixed 1.2 ratio, not the live stretching input,
  so the backdrop never redraws while typing.
- Console sits in the wider right column despite sage37's "console takes the
  narrower column" rule, because STAR's names need the width.

## Left to the builder

Exact alphas, line counts and placement, judged by running the app at
900 pt and full-screen widths.
