"""Downloads the UIUC Airfoil Coordinates Database into data/airfoils/uiuc/
and builds data/airfoils/index.sqlite (with the NACA set and My Airfoils).

    cd engine && uv run python scripts/fetch_airfoils.py

The files are not committed: UIUC states no licence for redistributing
them. The app's Wing Lab library runs the same thing from its Download
button (the engine's airfoil-fetch command).
"""

from aeroengine.wing.airfoils import build_index, fetch_uiuc

if __name__ == "__main__":
    print(f"downloaded {fetch_uiuc()} files")
    out = build_index(progress=lambda pct, msg: print(f"{pct:5.1f}%  {msg}"))
    print(f"index: {out['index']}, {out['counts']}, {len(out['failed'])} could not be read")
    for f in out["failed"]:
        print(f"  {f['file']}: {f['error']}")
