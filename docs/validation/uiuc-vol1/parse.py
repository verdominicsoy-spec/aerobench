import json, re, sys
text = open(sys.argv[1]).read()
# The book's columns flow page to page, left to right: one stream.
stream = " ".join(re.sub(r"=====PAGE \d+=====|-----COL \d+-----", " ", text).split())
fix = stream
fix = re.sub(r"(?<=[\d\-\s])O(?=[\.\dQ])", "0", fix)          # O read for 0
fix = re.sub(r"(?<=[\d\.])[OQ]", "0", fix)
fix = re.sub(r"(\d)\. (\d)", r"\1.\2", fix)                   # "1. 752"
fix = re.sub(r"(-?\d\.\d) (\d{2}\b)", r"\1\2", fix)            # "-0.4 75"
fix = re.sub(r"Fig\.\s*4\.l", "Fig. 4.1", fix)
tok = re.compile(r"(Fig\.\s*4\.(\d+))|(Run:\s*(\d+))|(Re\s*=\s*(\d+))|"
                 r"(-?\d{1,2}\.\d{2})\s*(-?\d\.\d{3})\s*(\d\.\d{4})")
fig = run = re = None
runs = {}
for m in tok.finditer(fix):
    if m.group(1):
        fig = int(m.group(2))
    elif m.group(3):
        run = int(m.group(4)); re_ = None
        runs[run] = {"fig": fig, "re": None, "rows": []}
    elif m.group(5):
        if run is not None and runs[run]["re"] is None:
            runs[run]["re"] = int(m.group(6))
    elif run is not None:
        runs[run]["rows"].append([float(m.group(7)), float(m.group(8)), float(m.group(9))])
want = {19: "E387", 23: "FX 63-137", 67: "NACA 6409", 92: "S1210", 96: "S1223"}
out = {}
for r, v in runs.items():
    if v["fig"] in want and v["re"] and 150000 <= v["re"] <= 320000 and len(v["rows"]) >= 6:
        out.setdefault(want[v["fig"]], []).append({"run": r, **v})
for k, vs in out.items():
    for v in vs:
        a = [x[0] for x in v["rows"]]
        print(k, "run", v["run"], "Re", v["re"], "rows", len(v["rows"]), "alpha", a[0], "..", a[-1], "increasing" if a == sorted(a) else "NOT increasing")
json.dump(out, open(sys.argv[2], "w"), indent=1)
