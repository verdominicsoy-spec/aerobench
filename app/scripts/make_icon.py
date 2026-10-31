"""Builds app/AeroBench/AppIcon.icon: the A monogram whose crossbar is a wing
section, set apart from the legs by a gap. Two layers (legs, wing) so Liquid
Glass renders Clear and Tinted from shape alone.

    uv run --with shapely python app/scripts/make_icon.py

Then check every appearance with Icon Composer's ictool (see the end).
"""

import json
from pathlib import Path

from shapely.geometry import LineString, Polygon
from shapely.ops import unary_union

S = 1024 / 100  # drawn on a 100-unit grid, the icon canvas is 1024 points
LEG_HALF_WIDTH = 6.5  # half the leg stroke
GAP = 3.0  # clear space around the wing, cut out of the legs
ROUND = 1.2  # radius every corner is rounded to

CHARCOAL = "srgb:0.09804,0.09020,0.07843,1.00000"  # Sage37 surface #191714
SAGE = "srgb:0.69412,0.81176,0.61569,1.00000"  # Sage37 sage ink #b1cf9d


def cubic(p0, p1, p2, p3, n=24):
    return [tuple((1 - t) ** 3 * a + 3 * (1 - t) ** 2 * t * b + 3 * (1 - t) * t**2 * c + t**3 * d
                  for a, b, c, d in zip(p0, p1, p2, p3))
            for t in (i / n for i in range(n))]


def wing() -> Polygon:
    """An inverted cambered section: round leading edge left, trailing edge right."""
    segs = [((25, 62.5), (25, 57.5), (31, 55.5), (39, 55.5)),
            ((39, 55.5), (53, 55.5), (68, 58.5), (80.5, 65)),
            ((80.5, 65), (81.5, 65.6), (81, 66.4), (80, 66.4)),
            ((80, 66.4), (66, 66), (52, 67.5), (39, 68.3)),
            ((39, 68.3), (31, 68.8), (25, 67.8), (25, 62.5))]
    return Polygon([p for s in segs for p in cubic(*s)])


def rounded(g, r=ROUND):
    return g.buffer(-r, join_style="round").buffer(r, join_style="round")


def svg_path(g) -> str:
    def ring(coords):
        pts = [f"{x * S:.1f} {y * S:.1f}" for x, y in coords]
        return "M" + " L".join(pts) + " Z"
    polys = getattr(g, "geoms", [g])
    return " ".join(ring(p.exterior.coords) + "".join(" " + ring(i.coords) for i in p.interiors) for p in polys)


def write_svg(path: Path, g, color: str):
    path.write_text(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
                    f'<path fill="{color}" fill-rule="evenodd" d="{svg_path(g)}"/></svg>\n')


def main():
    root = Path(__file__).resolve().parents[1] / "AeroBench" / "AppIcon.icon"
    assets = root / "Assets"
    assets.mkdir(parents=True, exist_ok=True)

    w = rounded(wing(), 0.6)  # a gentler radius: the trailing edge is thin
    legs = LineString([(22, 88), (50, 20), (78, 88)]).buffer(LEG_HALF_WIDTH, cap_style="round", join_style="round")
    legs = rounded(legs.difference(w.buffer(GAP)))
    assert not legs.intersects(w), "the gap must keep the legs and the wing apart"

    write_svg(assets / "legs.svg", legs, "#191714")
    write_svg(assets / "wing.svg", w, "#191714")

    def layer(name):
        # A layer's light and dark colours both go in the list; a plain "fill" ignores dark.
        return {"image-name": f"{name}.svg", "name": name, "glass": True,
                "fill-specializations": [{"value": {"solid": CHARCOAL}},
                                         {"appearance": "dark", "value": {"solid": SAGE}}]}

    doc = {
        "fill": {"solid": SAGE},
        "fill-specializations": [{"appearance": "dark", "value": {"solid": CHARCOAL}}],
        "groups": [{"layers": [layer("wing"), layer("legs")],
                    "shadow": {"kind": "neutral", "opacity": 0.5},
                    "translucency": {"enabled": False, "value": 0.5}}],  # solid: translucent legs faded out at the foot
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    (root / "icon.json").write_text(json.dumps(doc, indent=2) + "\n")
    print(f"wrote {root}")


if __name__ == "__main__":
    main()
    # Check each look, e.g.:
    # ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
    # "$ICTOOL" app/AeroBench/AppIcon.icon --export-image --output-file /tmp/icon.png \
    #     --platform macOS --rendition ClearLight --width 512 --height 512 --scale 1
