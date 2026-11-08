"""Geometry for the published multi-element cases, as the app would hold it.

Each element is turned into the engine's own representation: a unit section
re-panelled by aeroengine.wing.airfoils.normalise (161 points, as an imported
.dat gets), a chord, an angle and a leading-edge position, placed again by
aeroengine.wing.geometry.Element. The script reports how far the placed
outline is from the published one, so the re-panelling error is on record.

Run: cd engine && uv run python ../docs/validation/published/build.py [path to UFR3-01_nlr7301grid.zip]
Writes data/<case>/elements.json. The NLR contours are extracted from the
ERCOFTAC/SAAB grid archive (download it from the URL in README.md); without
the zip the committed data/nlr7301/*.dat contours are used.
"""
import json
import sys
import zipfile
from collections import defaultdict
from pathlib import Path

import numpy as np
from aeroengine.wing.airfoils import normalise
from aeroengine.wing.geometry import Element, closest

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"


def selig(loop: np.ndarray) -> np.ndarray:
    """A closed outline (any start, either direction) turned counter-clockwise,
    the Selig sense: trailing edge, upper surface, leading edge, lower surface."""
    loop = np.asarray(loop, float)
    if np.linalg.norm(loop[0] - loop[-1]) < 1e-12:
        loop = loop[:-1]
    # Counter-clockwise (positive area): TE -> upper -> LE -> lower -> TE.
    x, y = loop[:, 0], loop[:, 1]
    if 0.5 * np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y) < 0:
        loop = loop[::-1]
    return loop


def surface(loop: np.ndarray, upper: np.ndarray, lower: np.ndarray) -> np.ndarray:
    """The counter-clockwise outline from its upper trailing-edge corner round
    the leading edge to the lower corner, without the base between them: the
    engine takes the gap between the two ends as the trailing-edge thickness."""
    ku = int(np.argmin(np.linalg.norm(loop - upper, axis=1)))
    kl = int(np.argmin(np.linalg.norm(loop - lower, axis=1)))
    assert np.linalg.norm(loop[ku] - upper) < 1e-6 and np.linalg.norm(loop[kl] - lower) < 1e-6, "corner not on the outline"
    return np.roll(loop, -ku, axis=0)[:(kl - ku) % len(loop) + 1]


def to_element(pts: np.ndarray, name: str) -> dict:
    """pts: Selig-order outline, upper trailing-edge corner to lower, no base.
    Returns the engine element and how far it lies from pts."""
    unit, te_thick = normalise(pts)
    te = 0.5 * (pts[0] + pts[-1])
    # Leading edge and chord exactly as normalise finds them: the point of
    # the outline furthest from the trailing-edge midpoint.
    d = np.linalg.norm(pts - te, axis=1)
    le = pts[int(np.argmax(d))]
    chord = float(np.linalg.norm(te - le))
    angle = float(np.degrees(np.arctan2(te[1] - le[1], te[0] - le[0])))
    std = abs(angle) < 2 and abs(le[1]) < 0.02 * chord and abs(te[1]) < 0.02 * chord
    if std:  # normalise keeps the file's own chord line (see airfoils.normalise)
        xmin = pts[:, 0].min()
        le, chord, angle = np.array([xmin, 0.0]), float(te[0] - xmin), 0.0
    # Element angles are nose-up positive for an upright element: TE below LE.
    el = Element(unit, chord, -angle, np.asarray(le, float), inverted=False)
    placed = el.placed()
    err = max(closest(p, pts)[1] for p in placed)
    err_back = max(closest(p, placed)[1] for p in pts)
    print(f"  {name}: chord {chord:.4f}, angle {-angle:+.2f} deg, LE ({le[0]:.4f}, {le[1]:.4f}), "
          f"TE thickness {te_thick * chord:.5f}, outline error {max(err, err_back):.5f} (chord units of the case)")
    return {"name": name, "coords": placed.tolist(), "unit": unit.tolist(), "chord": chord, "angle": -angle,
            "inverted": False, "leading_edge": [float(le[0]), float(le[1])],
            "outline_error": float(max(err, err_back)), "published": pts.tolist()}


def p30n30() -> dict:
    """HLPW-4 / BANC 30P30N curves (inches, 18 in stowed chord), scaled to c = 1."""
    lines = (DATA / "30p30n" / "2010_30p30n_thik_te_18inches.crv.dat").read_text().split("\n")
    curves, i = [], 0
    while i < len(lines) and lines[i].strip():
        n = int(lines[i])
        curves.append(np.array([[float(v) for v in l.split()[:2]] for l in lines[i + 1:i + 1 + n]]))
        i += n + 1
    # Curves end to end round each element; 8, 4 and 7 are the slat, main and
    # flap trailing-edge bases, left out (see surface()).
    groups = {"slat": [9, 10], "main": [0, 1, 2, 3], "flap": [5, 6]}
    out = []
    print("30P30N")
    for name in ("slat", "main", "flap"):
        chain = [curves[k] if j == 0 else curves[k][1:] for j, k in enumerate(groups[name])]
        base = curves[{"slat": 8, "main": 4, "flap": 7}[name]]
        loop = selig(np.vstack(chain + [base[1:-1]]) / 18.0)
        a, b = base[0] / 18.0, base[-1] / 18.0  # the base's two ends: the upper corner is the higher
        upper, lower = (a, b) if a[1] > b[1] else (b, a)
        out.append(to_element(surface(loop, upper, lower), name))
    return {"case": "30P30N", "ref_chord": 1.0, "elements": out}


def nlr_from_zip(zpath: Path, member: str) -> list[np.ndarray]:
    """The two solid walls of the SAAB nine-block grid: block-side segments
    that no other block side shares, chained into loops (the outer boundary
    is the longest loop and is dropped)."""
    nums = zipfile.ZipFile(zpath).read(member).split()
    nb, p, blocks = int(nums[0]), 1, []
    for _ in range(nb):
        im, jm = int(nums[p]), int(nums[p + 1]); p += 2
        keys = np.array(nums[p:p + 2 * im * jm]).reshape(jm, im, 2); p += 2 * im * jm
        blocks.append(keys)
    count = defaultdict(int)
    for keys in blocks:  # coordinates kept as the file's text: shared points match exactly
        for side_k in (keys[0], keys[-1], keys[:, 0], keys[:, -1]):
            for a in range(len(side_k) - 1):
                ka, kb = tuple(side_k[a]), tuple(side_k[a + 1])
                if ka == kb:
                    continue
                e = frozenset((ka, kb))
                count[e] += 1
    edges = [e for e, n in count.items() if n % 2 == 1]
    nbr = defaultdict(list)
    for e in edges:
        a, b = tuple(e)
        nbr[a].append(b); nbr[b].append(a)
    assert all(len(v) == 2 for v in nbr.values()), "open boundary chain"
    seen, loops = set(), []
    for s in nbr:
        if s in seen:
            continue
        loop, prev, cur = [s], None, s
        seen.add(s)
        while True:
            nxt = nbr[cur][0] if nbr[cur][0] != prev else nbr[cur][1]
            if nxt == s:
                break
            loop.append(nxt); seen.add(nxt); prev, cur = cur, nxt
        loops.append(np.array([[float(k[0]), float(k[1])] for k in loop]))
    loops.sort(key=len)
    assert len(loops) == 3, f"expected main, flap and outer boundary, found {len(loops)} loops"
    walls = sorted(loops[:2], key=lambda l: l[:, 0].min())  # main first
    return walls


def nlr(zpath: Path | None) -> list[dict]:
    cases = []
    flap26 = None
    for gap, member in (("2.6", "t/nlrgap26.dat"), ("1.3", "t/nlrgap13.dat")):
        f = DATA / "nlr7301" / f"nlr7301_gap{gap.replace('.', '')}.dat"
        if zpath is not None:
            walls = nlr_from_zip(zpath, member)
            with open(f, "w") as fh:
                fh.write(f"# NLR 7301 + 32% flap, delta_f 20 deg, gap {gap}% c, overlap 5.3% c; solid walls of the SAAB\n"
                         f"# FLOWNET grid {member} in ERCOFTAC UFR3-01_nlr7301grid.zip (x, y in cruise chords).\n")
                for name, w in zip(("main", "flap"), walls):
                    fh.write(f"# {name} {len(w)}\n")
                    np.savetxt(fh, w, fmt="%.7f")
        txt = f.read_text().split("\n")
        walls, cur = [], None
        for l in txt:
            if l.startswith("# main") or l.startswith("# flap"):
                cur = []; walls.append(cur)
            elif l.strip() and not l.startswith("#"):
                cur.append([float(v) for v in l.split()])
        print(f"NLR 7301 gap {gap}%")
        els = []
        # Trailing-edge base corners (upper, lower) of the 2.6% gap grid. The
        # 1.3% grid's flap sits about 0.013 c higher (point for point in the
        # file, within 0.009 c), so its corners are found by that median shift.
        corners = {"main": ((0.9436, 0.01499), (0.9436, 0.01410)),
                   "flap": ((1.201771, -0.1037033), (1.201377, -0.104784))}
        for name, w in zip(("main", "flap"), walls):
            loop = selig(np.array(w))
            up, lo = (np.array(c) for c in corners[name])
            if name == "flap" and flap26 is not None:
                shift = np.median(np.array(w) - np.array(flap26), axis=0)
                up, lo = (loop[int(np.argmin(np.linalg.norm(loop - (c + shift), axis=1)))] for c in (up, lo))
            else:
                up, lo = (loop[int(np.argmin(np.linalg.norm(loop - c, axis=1)))] for c in (up, lo))
            els.append(to_element(surface(loop, up, lo), name))
        if gap == "2.6":
            flap26 = walls[1]
        cases.append({"case": f"NLR 7301 gap {gap}", "ref_chord": 1.0, "elements": els})
    return cases


if __name__ == "__main__":
    z = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    c = p30n30()
    (DATA / "30p30n" / "elements.json").write_text(json.dumps(c))
    for k in nlr(z):
        (DATA / "nlr7301" / f"elements_gap{k['case'].split()[-1].replace('.', '')}.json").write_text(json.dumps(k))
