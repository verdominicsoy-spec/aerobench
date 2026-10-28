"""Airfoil sections: NACA generators, .dat parsing, normalisation and the
library index.

Every section is stored the same way: Selig order (trailing edge, upper
surface, leading edge, lower surface, trailing edge), unit chord, leading
edge at the origin, chord along +x, re-panelled with cosine spacing to a
fixed point count. The trailing edge is left as it is and its thickness
recorded, never closed silently.
"""

from __future__ import annotations

import json
import re
import sqlite3
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from scipy.interpolate import splev, splprep
from scipy.optimize import minimize_scalar

from ..job import EngineError

POINTS = 161  # per section after re-panelling: 80 per surface plus the leading edge


def data_dir() -> Path:
    """<repo>/data, next to the engine."""
    return Path(__file__).resolve().parents[4] / "data"


# NACA sections ---------------------------------------------------------------

def _thickness(x: np.ndarray, t: float, closed: bool) -> np.ndarray:
    a4 = -0.1036 if closed else -0.1015
    return 5 * t * (0.2969 * np.sqrt(x) - 0.1260 * x - 0.3516 * x**2 + 0.2843 * x**3 + a4 * x**4)


def _cosine(n: int) -> np.ndarray:
    return 0.5 * (1 - np.cos(np.linspace(0, np.pi, n)))


def _assemble(x: np.ndarray, yc: np.ndarray, dyc: np.ndarray, yt: np.ndarray) -> np.ndarray:
    theta = np.arctan(dyc)
    xu, yu = x - yt * np.sin(theta), yc + yt * np.cos(theta)
    xl, yl = x + yt * np.sin(theta), yc - yt * np.cos(theta)
    upper = np.column_stack([xu, yu])[::-1]  # TE to LE
    lower = np.column_stack([xl, yl])[1:]  # LE (shared) to TE
    return np.vstack([upper, lower])


def naca4(code: str, n: int = POINTS, closed: bool = False) -> np.ndarray:
    """NACA 4-digit MPXX: max camber M% at P/10 chord, thickness XX%."""
    if not re.fullmatch(r"\d{4}", code):
        raise EngineError(f"NACA 4-digit code must be four digits, not '{code}'")
    m, p, t = int(code[0]) / 100, int(code[1]) / 10, int(code[2:]) / 100
    if t <= 0:
        raise EngineError("NACA thickness must be above zero")
    x = _cosine((n + 1) // 2)
    if m == 0 or p == 0:
        yc, dyc = np.zeros_like(x), np.zeros_like(x)
    else:
        front = x < p
        yc = np.where(front, m / p**2 * (2 * p * x - x**2), m / (1 - p) ** 2 * (1 - 2 * p + 2 * p * x - x**2))
        dyc = np.where(front, 2 * m / p**2 * (p - x), 2 * m / (1 - p) ** 2 * (p - x))
    return _assemble(x, yc, dyc, _thickness(x, t, closed))


# Standard 5-digit camber lines, for a design lift coefficient of 0.3:
# position p -> (m, k1) and, reflexed, (m, k1, k2/k1).
_NACA5 = {0.05: (0.0580, 361.400), 0.10: (0.1260, 51.640), 0.15: (0.2025, 15.957), 0.20: (0.2900, 6.643),
          0.25: (0.3910, 3.230)}
_NACA5_REFLEX = {0.10: (0.1300, 51.990, 0.000764), 0.15: (0.2170, 15.793, 0.00677), 0.20: (0.3180, 6.520, 0.0303),
                 0.25: (0.4410, 3.191, 0.1355)}


def naca5(code: str, n: int = POINTS, closed: bool = False) -> np.ndarray:
    """NACA 5-digit LPSTT: design Cl 0.15 L, max camber at P/20 chord,
    S = 1 for a reflexed camber line, thickness TT%."""
    if not re.fullmatch(r"\d{5}", code):
        raise EngineError(f"NACA 5-digit code must be five digits, not '{code}'")
    cl, p, reflex, t = 0.15 * int(code[0]), int(code[1]) / 20, code[2] == "1", int(code[3:]) / 100
    if code[2] not in "01":
        raise EngineError("the third digit of a NACA 5-digit code is 0 or 1 (reflexed)")
    table = _NACA5_REFLEX if reflex else _NACA5
    key = min(table, key=lambda k: abs(k - p))
    if abs(key - p) > 1e-9:
        raise EngineError(f"NACA 5-digit camber position {p:.2f} is not tabulated",
                          f"use one of {', '.join(f'{k:.2f}' for k in table)}")
    x = _cosine((n + 1) // 2)
    scale = cl / 0.3
    if reflex:
        m, k1, r = table[key]
        k1 *= scale
        front = x < m
        yc = np.where(front, k1 / 6 * ((x - m) ** 3 - r * (1 - m) ** 3 * x - m**3 * x + m**3),
                      k1 / 6 * (r * (x - m) ** 3 - r * (1 - m) ** 3 * x - m**3 * x + m**3))
        dyc = np.where(front, k1 / 6 * (3 * (x - m) ** 2 - r * (1 - m) ** 3 - m**3),
                       k1 / 6 * (3 * r * (x - m) ** 2 - r * (1 - m) ** 3 - m**3))
    else:
        m, k1 = table[key]
        k1 *= scale
        front = x < m
        yc = np.where(front, k1 / 6 * (x**3 - 3 * m * x**2 + m**2 * (3 - m) * x), k1 * m**3 / 6 * (1 - x))
        dyc = np.where(front, k1 / 6 * (3 * x**2 - 6 * m * x + m**2 * (3 - m)), -k1 * m**3 / 6 + 0 * x)
    return _assemble(x, yc, dyc, _thickness(x, t, closed))


def naca(code: str, n: int = POINTS) -> np.ndarray:
    code = code.strip().upper().removeprefix("NACA").strip()
    if len(code) == 4:
        return naca4(code, n)
    if len(code) == 5:
        return naca5(code, n)
    raise EngineError(f"'{code}' is not a NACA 4 or 5-digit code")


# Parsing -----------------------------------------------------------------------

def parse_dat(text: str, fallback_name: str = "airfoil") -> tuple[str, np.ndarray, str]:
    """A .dat file's name, points in Selig order, and its format ("selig" or
    "lednicer", told apart by the point counts Lednicer files give first)."""
    name = None
    pairs = []
    blocks: list[list[tuple[float, float]]] = [[]]
    for line in text.splitlines():
        parts = line.replace(",", " ").split()
        nums = []
        for p in parts[:2]:
            try:
                nums.append(float(p))
            except ValueError:
                break
        if len(parts) >= 2 and len(nums) == 2:
            pairs.append((nums[0], nums[1]))
            blocks[-1].append((nums[0], nums[1]))
        elif not parts:
            if blocks[-1]:
                blocks.append([])
        elif name is None and not pairs:
            name = line.strip()
    blocks = [b for b in blocks if b]
    if len(pairs) < 6:
        raise EngineError(f"{fallback_name}: fewer than six coordinate pairs")
    if pairs[0][0] > 1.5 and pairs[0][1] > 1.5:  # Lednicer: counts, then upper and lower from the LE
        nu, nl = int(pairs[0][0]), int(pairs[0][1])
        rest = pairs[1:]
        if len(blocks) >= 3 and len(blocks[1]) == nu and len(blocks[2]) == nl:
            upper, lower = blocks[1], blocks[2]
        else:
            upper, lower = rest[:nu], rest[nu:nu + nl]
        if len(upper) < 3 or len(lower) < 3:
            raise EngineError(f"{fallback_name}: Lednicer counts do not match the points")
        pts = np.array(upper[::-1] + lower[1:] if np.allclose(upper[0], lower[0]) else upper[::-1] + lower)
        return (name or fallback_name), pts, "lednicer"
    return (name or fallback_name), np.array(pairs), "selig"


# Normalising -----------------------------------------------------------------------

@dataclass
class Section:
    name: str
    coords: np.ndarray  # (POINTS, 2), Selig order, unit chord, LE at the origin
    te_thickness: float
    thickness: float
    thickness_x: float
    camber: float
    camber_x: float

    def as_dict(self) -> dict:
        return {"name": self.name, "coords": np.round(self.coords, 6).tolist(), "te_thickness": self.te_thickness,
                "thickness": self.thickness, "thickness_x": self.thickness_x, "camber": self.camber,
                "camber_x": self.camber_x}


def _dedupe(xy: np.ndarray) -> np.ndarray:
    keep = np.ones(len(xy), bool)
    keep[1:] = np.linalg.norm(np.diff(xy, axis=0), axis=1) > 1e-9
    return xy[keep]


def normalise(xy: np.ndarray, n: int = POINTS) -> tuple[np.ndarray, float]:
    """Unit chord, LE at the origin, chord along +x, upper surface first,
    re-panelled with cosine spacing. Returns the points and the trailing edge
    thickness (as a fraction of chord)."""
    xy = _dedupe(np.asarray(xy, float))
    if len(xy) < 6:
        raise EngineError("too few distinct points")
    te = 0.5 * (xy[0] + xy[-1])
    # The leading edge is the point of the spline furthest from the TE midpoint.
    tck, u = splprep([xy[:, 0], xy[:, 1]], s=0, k=3 if len(xy) > 3 else 1)
    i = int(np.argmax(np.linalg.norm(xy - te, axis=1)))

    def neg_dist(s):
        p = np.array(splev(s, tck))
        return -np.linalg.norm(p - te)

    lo, hi = u[max(i - 1, 0)], u[min(i + 1, len(u) - 1)]
    u_le = minimize_scalar(neg_dist, bounds=(lo, hi), method="bounded").x if hi > lo else u[i]
    le = np.array(splev(u_le, tck))
    chord = np.linalg.norm(te - le)
    if chord <= 0:
        raise EngineError("the leading and trailing edges coincide")
    angle = np.arctan2(te[1] - le[1], te[0] - le[0])
    rot = np.array([[np.cos(-angle), -np.sin(-angle)], [np.sin(-angle), np.cos(-angle)]])

    def place(p):  # (n, 2) points to the section frame
        return ((np.asarray(p) - le) @ rot.T) / chord

    half = (n + 1) // 2
    s = 0.5 * (1 - np.cos(np.linspace(0, np.pi, half)))
    first = place(np.array(splev(u_le * s, tck)).T)  # TE (u=0) to LE
    second = place(np.array(splev(u_le + (1 - u_le) * s, tck)).T)  # LE to TE (u=1)
    out = np.vstack([first, second[1:]])
    out[half - 1] = [0.0, 0.0]
    # Upper surface first: in Selig order the first half lies above the second.
    xs = np.linspace(0.05, 0.95, 19)
    up = np.interp(xs, out[:half][::-1, 0], out[:half][::-1, 1])
    low = np.interp(xs, out[half - 1:, 0], out[half - 1:, 1])
    if np.mean(up - low) < 0:
        out = out[::-1].copy()
    return out, float(np.linalg.norm(out[0] - out[-1]))


def surfaces(coords: np.ndarray, x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Upper and lower y at x (0..1) from a normalised section."""
    half = (len(coords) + 1) // 2
    upper = coords[:half][::-1]  # LE to TE
    lower = coords[half - 1:]
    return np.interp(x, upper[:, 0], upper[:, 1]), np.interp(x, lower[:, 0], lower[:, 1])


def section(name: str, xy: np.ndarray, n: int = POINTS) -> Section:
    coords, te = normalise(xy, n)
    if te > 0.5:  # an engine cowl, or several elements in one file (the 30P30N)
        raise EngineError(f"{name}: not a single airfoil section (its ends are {te:.2f} chords apart)")
    x = 0.5 * (1 - np.cos(np.linspace(0, np.pi, 400)))
    yu, yl = surfaces(coords, x)
    t, c = yu - yl, 0.5 * (yu + yl)
    it, ic = int(np.argmax(t)), int(np.argmax(np.abs(c)))
    return Section(name, coords, te, float(t[it]), float(x[it]), float(c[ic]), float(x[ic]))


def family(name: str) -> str:
    """A family from the name's leading letters: NACA, Eppler (e), Selig (s),
    Wortmann (fx) and so on."""
    n = name.lower().replace(" ", "")
    if n.startswith("naca"):
        return "NACA"
    m = re.match(r"[a-z]+", n)
    known = {"e": "Eppler", "s": "Selig", "sd": "Selig-Donovan", "fx": "Wortmann", "goe": "Gottingen",
             "mh": "Hepperle", "ag": "Drela AG", "clark": "Clark", "naca": "NACA", "nlf": "NASA NLF",
             "nasa": "NASA", "ls": "NASA LS", "ms": "NASA MS", "sc": "NASA SC", "rae": "RAE", "ch": "CH",
             "dae": "DAE", "ht": "Drela HT", "hq": "HQ", "gm": "GM", "ah": "Althaus", "lwk": "LWK"}
    return known.get(m.group(0), m.group(0).upper()) if m else "Other"


# The library index ----------------------------------------------------------------

NACA_SET = ([f"00{t:02d}" for t in (6, 8, 9, 10, 12, 15, 18, 21)]
            + [f"{m}{p}{t:02d}" for m in range(1, 7) for p in range(2, 7) for t in (6, 8, 10, 12, 15, 18)]
            + [f"2{p}0{t:02d}" for p in range(1, 6) for t in (12, 15, 18, 21)]
            + [f"2{p}1{t:02d}" for p in range(2, 6) for t in (12, 15, 18)])

SCHEMA = """
CREATE TABLE IF NOT EXISTS airfoils (
    id INTEGER PRIMARY KEY,
    key TEXT UNIQUE NOT NULL,          -- source/name, stable across rebuilds
    name TEXT NOT NULL,
    family TEXT NOT NULL,
    source TEXT NOT NULL,              -- naca, uiuc or mine
    file TEXT,
    thickness REAL, thickness_x REAL, camber REAL, camber_x REAL, te_thickness REAL,
    coords TEXT NOT NULL               -- JSON [[x, y], ...], Selig order, unit chord
);
CREATE INDEX IF NOT EXISTS airfoils_name ON airfoils(name);
"""


def _row(sec: Section, source: str, file: str | None, key: str) -> tuple:
    return (key, sec.name, family(sec.name), source, file, sec.thickness, sec.thickness_x, sec.camber, sec.camber_x,
            sec.te_thickness, json.dumps(np.round(sec.coords, 6).tolist(), separators=(",", ":")))


def _insert(db: sqlite3.Connection, rows: list[tuple]) -> None:
    db.executemany("INSERT OR REPLACE INTO airfoils (key, name, family, source, file, thickness, thickness_x, camber, "
                   "camber_x, te_thickness, coords) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", rows)


def read_file(path: Path) -> Section:
    text = path.read_text(errors="replace")
    name, xy, _ = parse_dat(text, path.stem)
    return section(name or path.stem, xy)


def build_index(root: Path | None = None, progress=None) -> dict:
    """(Re)builds <root>/airfoils/index.sqlite from the NACA set, the UIUC
    files in uiuc/ (if fetched) and the user's own in mine/."""
    root = (root or data_dir()) / "airfoils"
    root.mkdir(parents=True, exist_ok=True)
    tmp = root / "index.sqlite.tmp"
    tmp.unlink(missing_ok=True)
    db = sqlite3.connect(tmp)
    db.executescript(SCHEMA)
    rows, failed = [], []
    for code in NACA_SET:
        rows.append(_row(section(f"NACA {code}", naca(code)), "naca", None, f"naca/{code}"))
    files = [("uiuc", p) for p in sorted((root / "uiuc").glob("*.dat"))] + \
            [("mine", p) for p in sorted((root / "mine").glob("*.dat"))]
    for k, (source, path) in enumerate(files):
        try:
            rows.append(_row(read_file(path), source, f"{source}/{path.name}", f"{source}/{path.stem}"))
        except Exception as exc:  # one bad file must not stop the library
            failed.append({"file": f"{source}/{path.name}", "error": str(exc)[:200]})
        if progress and k % 100 == 0:
            progress(100 * k / max(len(files), 1), f"{k} of {len(files)} files")
    _insert(db, rows)
    db.commit()
    db.close()
    tmp.replace(root / "index.sqlite")
    counts = {}
    for r in rows:
        counts[r[3]] = counts.get(r[3], 0) + 1
    return {"index": str(root / "index.sqlite"), "counts": counts, "failed": failed}


def import_files(paths: list[Path], root: Path | None = None) -> dict:
    """Copies .dat files into My Airfoils and adds them to the index."""
    root = (root or data_dir()) / "airfoils"
    mine = root / "mine"
    mine.mkdir(parents=True, exist_ok=True)
    index = root / "index.sqlite"
    db = sqlite3.connect(index)
    db.executescript(SCHEMA)
    added, failed = [], []
    for p in paths:
        try:
            sec = read_file(p)
            target = mine / (re.sub(r"[^A-Za-z0-9._-]+", "_", p.stem) + ".dat")
            target.write_text(p.read_text(errors="replace"))
            _insert(db, [_row(sec, "mine", f"mine/{target.name}", f"mine/{target.stem}")])
            added.append({"name": sec.name, "key": f"mine/{target.stem}", "te_thickness": sec.te_thickness})
        except Exception as exc:
            failed.append({"file": str(p), "error": str(exc)[:200]})
    db.commit()
    db.close()
    return {"added": added, "failed": failed, "index": str(index)}


UIUC_ZIP = "https://m-selig.ae.illinois.edu/ads/archives/coord_seligFmt.zip"


def fetch_uiuc(root: Path | None = None, url: str = UIUC_ZIP) -> int:
    """Downloads the UIUC Selig-format archive into <root>/airfoils/uiuc/.
    The files are not committed: UIUC states no licence for redistribution."""
    import io
    import urllib.request
    import zipfile

    target = (root or data_dir()) / "airfoils" / "uiuc"
    target.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    count = 0
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        for info in z.infolist():
            name = Path(info.filename).name
            if not name.lower().endswith(".dat") or info.is_dir():
                continue
            (target / name.lower()).write_bytes(z.read(info))
            count += 1
    return count
