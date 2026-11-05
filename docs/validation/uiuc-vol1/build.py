"""The workbook: tunnel (UIUC Vol 1) against AeroBench's quick estimate (NeuralFoil) and RANS."""
import json, sys
from pathlib import Path
from openpyxl import Workbook
from openpyxl.chart import ScatterChart, Reference, Series
from openpyxl.chart.marker import Marker
from openpyxl.comments import Comment
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter as L

S = Path(sys.argv[1]); dest = Path(sys.argv[2])
R = json.loads((S / "results.json").read_text())
T = json.loads((S / "tunnel.json").read_text())
order = [n for n in ["S1223", "S1210", "FX 63-137", "NACA 6409", "E387"] if n in R]
runs = {"E387": "213", "FX 63-137": "154", "NACA 6409": "191", "S1210": "131", "S1223": "136 and 588"}
figs = {"E387": "4.19", "FX 63-137": "4.23", "NACA 6409": "4.67", "S1210": "4.92", "S1223": "4.96"}

F = "Arial"
H = Font(name=F, bold=True, size=10, color="FFFFFF"); B = Font(name=F, size=10); BB = Font(name=F, size=10, bold=True)
BLUE = Font(name=F, size=10, color="0000FF"); GREY = Font(name=F, size=9, color="666666", italic=True)
TITLE = Font(name=F, size=14, bold=True)
HF = PatternFill("solid", fgColor="44546A"); IN = PatternFill("solid", fgColor="EEF3F8")
thin = Side(style="thin", color="BFBFBF"); BOX = Border(left=thin, right=thin, top=thin, bottom=thin)
C_T, C_NF, C_R = "000000", "E07B39", "2E75B6"  # tunnel black, NeuralFoil orange, RANS blue

def head(ws, row, col, names, widths=None):
    for k, n in enumerate(names):
        c = ws.cell(row, col + k, n); c.font = H; c.fill = HF; c.alignment = Alignment(wrap_text=True, horizontal="center", vertical="center"); c.border = BOX
    ws.row_dimensions[row].height = 42

def put(ws, r, c, v, font=B, fmt=None):
    cell = ws.cell(r, c, v); cell.font = font; cell.border = BOX
    if fmt: cell.number_format = fmt
    return cell

def series(ws, xcol, ycol, r0, r1, title, color, line=True, marker="none", dash=None):
    s = Series(Reference(ws, min_col=ycol, min_row=r0, max_row=r1), Reference(ws, min_col=xcol, min_row=r0, max_row=r1), title=title)
    s.marker = Marker(symbol=marker, size=6)
    if marker != "none":
        s.marker.graphicalProperties.solidFill = color; s.marker.graphicalProperties.line.solidFill = color
    if line:
        s.graphicalProperties.line.solidFill = color; s.graphicalProperties.line.width = 22000
        if dash: s.graphicalProperties.line.dashStyle = dash
    else:
        s.graphicalProperties.line.noFill = True
    s.smooth = False
    return s

def chart(title, xt, yt):
    ch = ScatterChart(); ch.title = title; ch.style = 13; ch.height = 8.5; ch.width = 15
    ch.x_axis.title = xt; ch.y_axis.title = yt; ch.legend.position = "b"
    ch.x_axis.delete = False; ch.y_axis.delete = False
    return ch

wb = Workbook()
summary = wb.active; summary.title = "Summary"
method = wb.create_sheet("Method and notes")
for name in order:
    d = R[name]; ws = wb.create_sheet(name)
    tun = d["tunnel"]; nf = d["neuralfoil"]; ra = d["rans"]
    ws["A1"] = f"{name}, Re {d['re']:,.0f}: UIUC tunnel against AeroBench"; ws["A1"].font = TITLE
    ws["A2"] = (f"Tunnel: Selig et al., Summary of Low-Speed Airfoil Data Vol. 1 (1995), Appendix B, run {runs[name]}, Fig. {figs[name]}. "
                f"AeroBench: quick estimate (NeuralFoil, Ncrit 9) at the tunnel's angles; RANS (SU2, SST transition, fine mesh, Ncrit 9, "
                f"turbulence 0.1%), a Full polar every 2 degrees, interpolated to the tunnel's angles from converged runs only.")
    ws["A2"].font = GREY; ws["A2"].alignment = Alignment(wrap_text=True, vertical="top"); ws.merge_cells("A2:N2"); ws.row_dimensions[2].height = 40
    # main table
    r0 = 5
    cols = ["α (°)", "Cl tunnel", "Cd tunnel", "L/D tunnel", "Cl estimate", "Cd estimate", "Cl RANS", "Cd RANS",
            "Cl error estimate", "Cd error estimate", "Cl error RANS", "Cd error RANS", "L/D estimate", "L/D RANS", "ΔCl RANS − tunnel"]
    head(ws, r0 - 1, 1, cols)
    # RANS raw table (columns Q..V) first, so the interpolation can point at it
    rq = 17  # column Q
    head(ws, r0 - 1, rq, ["RANS α (°)", "Cl", "Cd", "Converged", "Separated", "Note"])
    good = [r for r in ra if r[3] and r[0] is not None]
    allr = sorted([r for r in ra if r[0] is not None], key=lambda r: r[0])
    for k, r in enumerate(allr):
        row = r0 + k
        put(ws, row, rq, r[0], BLUE, "0.0"); put(ws, row, rq + 1, r[1], BLUE, "0.000"); put(ws, row, rq + 2, r[2], BLUE, "0.0000")
        put(ws, row, rq + 3, "yes" if r[3] else "no", BLUE); put(ws, row, rq + 4, "yes" if r[4] else "no", BLUE)
        put(ws, row, rq + 5, (r[5] or "")[:120], GREY)
    # converged-only copy for interpolation and the charts (columns X..Z)
    cx = 24
    head(ws, r0 - 1, cx, ["Converged α (°)", "Cl", "Cd"])
    for k, r in enumerate(sorted(good, key=lambda r: r[0])):
        put(ws, r0 + k, cx, r[0], BLUE, "0.0"); put(ws, r0 + k, cx + 1, r[1], BLUE, "0.000"); put(ws, r0 + k, cx + 2, r[2], BLUE, "0.0000")
    ng = max(len(good), 1); gx = f"${L(cx)}${r0}:${L(cx)}${r0 + ng - 1}"; gl = f"${L(cx + 1)}${r0}:${L(cx + 1)}${r0 + ng - 1}"
    gd = f"${L(cx + 2)}${r0}:${L(cx + 2)}${r0 + ng - 1}"
    for k, (a, cl, cd) in enumerate(tun):
        row = r0 + k; n = nf[k]
        put(ws, row, 1, a, BLUE, "0.00"); put(ws, row, 2, cl, BLUE, "0.000"); put(ws, row, 3, cd, BLUE, "0.0000")
        put(ws, row, 4, f"=B{row}/C{row}", B, "0.0")
        put(ws, row, 5, n[1], BLUE, "0.000"); put(ws, row, 6, n[2], BLUE, "0.0000")
        def interp(y):
            m = f"MATCH(A{row},{gx},1)"
            return (f'=IFERROR(INDEX({y},{m})+(INDEX({y},{m}+1)-INDEX({y},{m}))*(A{row}-INDEX({gx},{m}))'
                    f'/(INDEX({gx},{m}+1)-INDEX({gx},{m})),"")')
        put(ws, row, 7, interp(gl), B, "0.000"); put(ws, row, 8, interp(gd), B, "0.0000")
        put(ws, row, 9, f'=IF(ABS(B{row})<0.1,"",(E{row}-B{row})/ABS(B{row}))', B, "0.0%")
        put(ws, row, 10, f"=(F{row}-C{row})/C{row}", B, "0.0%")
        put(ws, row, 11, f'=IF(OR(G{row}="",ABS(B{row})<0.1),"",(G{row}-B{row})/ABS(B{row}))', B, "0.0%")
        put(ws, row, 12, f'=IF(H{row}="","",(H{row}-C{row})/C{row})', B, "0.0%")
        put(ws, row, 13, f"=E{row}/F{row}", B, "0.0")
        put(ws, row, 14, f'=IF(OR(G{row}="",H{row}=""),"",G{row}/H{row})', B, "0.0")
        put(ws, row, 15, f'=IF(G{row}="","",G{row}-B{row})', B, "+0.000;-0.000")
    r1 = r0 + len(tun) - 1
    # mean absolute errors under the table
    m = r1 + 2
    put(ws, m, 1, "Mean |error|", BB)
    for c in range(9, 13):
        col = L(c)
        rg = f"{col}{r0}:{col}{r1}"  # SUMIF skips the blank ("") cells
        put(ws, m, c, f'=IFERROR((SUMIF({rg},">0")-SUMIF({rg},"<0"))/COUNT({rg}),"")', BB, "0.0%")
    put(ws, m, 15, f'=IFERROR(AVERAGE(O{r0}:O{r1}),"")', BB, "+0.000;-0.000")
    put(ws, m + 1, 1, "Cl error is blank where the tunnel's |Cl| < 0.1: a percentage of nearly nothing means nothing. RANS columns are blank outside its converged range.", GREY)
    for c, w in zip(range(1, 27), [8, 9, 9, 8, 9, 9, 9, 9, 10, 10, 10, 10, 9, 9, 10, 3, 9, 8, 8, 9, 9, 40, 3, 10, 8, 8]):
        ws.column_dimensions[L(c)].width = w
    ws.freeze_panes = "B5"
    # linear range: lift slope, zero-lift angle, Cl at 0 deg (least squares over the chosen range)
    b = m + 3
    put(ws, b, 1, "Linear range", BB); put(ws, b, 2, "from α", B); put(ws, b, 3, -2, BLUE, "0.0"); put(ws, b, 4, "to α", B); put(ws, b, 5, 6, BLUE, "0.0")
    ws.cell(b, 3).fill = IN; ws.cell(b, 5).fill = IN
    put(ws, b, 6, "degrees (blue cells: change the range and everything below updates)", GREY)
    head(ws, b + 1, 1, ["Source", "Lift slope (per °)", "Lift slope (per rad)", "Zero-lift α (°)", "Cl at α 0°", "Mean Cl offset vs tunnel",
                        "Points", "Σα", "ΣCl", "ΣαCl", "Σα²"])
    lo, hi = f"$C${b}", f"$E${b}"
    srcs = [("Tunnel", f"$A${r0}:$A${r1}", f"$B${r0}:$B${r1}", None),
            ("Estimate", f"$A${r0}:$A${r1}", f"$E${r0}:$E${r1}", f"=SUMPRODUCT($E${r0}:$E${r1}-$B${r0}:$B${r1})/COUNT($B${r0}:$B${r1})"),
            ("RANS (converged)", gx, gl, f'=IFERROR(AVERAGE($O${r0}:$O${r1}),"")')]
    for k, (lab, X, Y, off) in enumerate(srcs):
        row = b + 2 + k; msk = f"({X}>={lo})*({X}<={hi})"
        put(ws, row, 1, lab, BB)
        put(ws, row, 7, f"=SUMPRODUCT({msk})", B, "0")
        put(ws, row, 8, f"=SUMPRODUCT({msk}*{X})", GREY, "0.00")
        put(ws, row, 9, f"=SUMPRODUCT({msk}*{Y})", GREY, "0.000")
        put(ws, row, 10, f"=SUMPRODUCT({msk}*{X}*{Y})", GREY, "0.000")
        put(ws, row, 11, f"=SUMPRODUCT({msk}*{X}*{X})", GREY, "0.00")
        put(ws, row, 2, f'=IFERROR((G{row}*J{row}-H{row}*I{row})/(G{row}*K{row}-H{row}^2),"")', B, "0.0000")
        put(ws, row, 3, f'=IFERROR(B{row}*180/PI(),"")', B, "0.000")
        put(ws, row, 5, f'=IFERROR((I{row}-B{row}*H{row})/G{row},"")', B, "0.000")
        put(ws, row, 4, f'=IFERROR(-E{row}/B{row},"")', B, "0.00")
        put(ws, row, 6, off if off else "", B, "+0.000;-0.000")
    put(ws, b + 5, 1, "A slope that matches with a constant Cl offset means the curve is shifted, not tilted: an angle offset (about offset ÷ slope degrees). Thin-aerofoil theory gives 0.110 per degree (2π per rad).", GREY)
    m = b + 5
    # charts: tunnel points, estimate line, RANS line (converged) and markers
    ra0, ra1 = r0, r0 + ng - 1
    specs = [("Cl against angle of attack", "α (°)", "Cl", (1, 2), (1, 5), (cx, cx + 1)),
             ("Cd against angle of attack", "α (°)", "Cd", (1, 3), (1, 6), (cx, cx + 2)),
             ("Cl against Cd (drag polar)", "Cd", "Cl", (3, 2), (6, 5), (cx + 2, cx + 1))]
    anchors = ["A{}".format(m + 3), "J{}".format(m + 3), "A{}".format(m + 21)]
    for (t, xt, yt, tun_xy, nf_xy, ra_xy), at in zip(specs, anchors):
        ch = chart(f"{name}: {t}", xt, yt)
        ch.series.append(series(ws, tun_xy[0], tun_xy[1], r0, r1, "Tunnel (UIUC)", C_T, line=False, marker="circle"))
        ch.series.append(series(ws, nf_xy[0], nf_xy[1], r0, r1, "AeroBench estimate (NeuralFoil)", C_NF, dash="dash"))
        if good:
            ch.series.append(series(ws, ra_xy[0], ra_xy[1], ra0, ra1, "AeroBench RANS (converged)", C_R, marker="diamond"))
        ws.add_chart(ch, at)
    ch = chart(f"{name}: L/D against angle of attack", "α (°)", "L/D")
    ch.series.append(series(ws, 1, 4, r0, r1, "Tunnel (UIUC)", C_T, line=False, marker="circle"))
    ch.series.append(series(ws, 1, 13, r0, r1, "AeroBench estimate (NeuralFoil)", C_NF, dash="dash"))
    ch.series.append(series(ws, 1, 14, r0, r1, "AeroBench RANS (interpolated)", C_R, marker="diamond"))
    ws.add_chart(ch, "J{}".format(m + 21))

# Summary
s = summary
s["A1"] = "UIUC low-speed aerofoil data against AeroBench: summary"; s["A1"].font = TITLE
s["A2"] = "Every figure links to its aerofoil's sheet. Errors are (AeroBench − tunnel) / tunnel at the tunnel's angles; means are of the absolute error."; s["A2"].font = GREY
cols = ["Aerofoil", "Re", "Cl max tunnel", "α at Cl max tunnel", "Cl max estimate", "α at Cl max estimate", "Cl max RANS (converged)",
        "Cd min tunnel", "Cd min estimate", "Cd min RANS", "L/D max tunnel", "L/D max estimate", "L/D max RANS",
        "Mean |Cl error| estimate", "Mean |Cd error| estimate", "Mean |Cl error| RANS", "Mean |Cd error| RANS",
        "Lift slope tunnel (per °)", "Lift slope estimate (per °)", "Lift slope RANS (per °)", "Zero-lift α tunnel (°)", "Zero-lift α estimate (°)",
        "Zero-lift α RANS (°)", "Mean Cl offset estimate", "Mean Cl offset RANS", "RANS angles converged", "Notes"]
head(s, 4, 1, cols)
notes = {
    "S1223": "Best RANS match: zero-lift angle identical (-11.7°), lift slope 5% steep, Cd within about 1%; Cl reads about +0.09 high. The estimate's slope is 29% steep (0.117 against 0.091 per degree) and its Cl max comes about 3° early. Tunnel polar joins runs 136 and 588. RANS did not converge at -2° or at 12-14° (Cl still moving), so its stall is not settled.",
    "S1210": "RANS converged only at 4-8°, so its errors rest on three points. The low-angle runs (-4 to 2°) kept oscillating, likely an unsteady laminar bubble. The estimate's Cl is about +0.20 high, slope 18% steep. The tunnel stops at 11.6°, short of stall.",
    "FX 63-137": "RANS within about 6% on Cl and 3% on Cd from -4 to 4°. Above 4° the RANS runs kept moving (not converged), so its Cl max (about 1.66 near 10°) is indicative only. The estimate's slope is 9% steep and its Cl about +0.13 high.",
    "NACA 6409": "Shape from the NACA 4-digit formulas. RANS converged only at 4-8°; the low angles oscillated. The estimate's Cl is about +0.11 high, slope 8% steep, and its Cd the furthest off in the set (21%).",
    "E387": "The UIUC benchmark section. RANS Cd within about 4% from -2 to 6°; Cl about +0.06 high with the slope 4% steep. RANS at 8° (Cl 1.22) did not converge, where the tunnel's Cl flattens (1.13 at 8.8°). The estimate's L/D max is 83 against the tunnel's 64.",
}
for k, name in enumerate(order):
    row = 5 + k; d = R[name]; q = f"'{name}'!"
    n = len(d["tunnel"]); a = f"{q}$A$5:$A${4 + n}"; ct = f"{q}$B$5:$B${4 + n}"; cn = f"{q}$E$5:$E${4 + n}"
    dt = f"{q}$C$5:$C${4 + n}"; dn = f"{q}$F$5:$F${4 + n}"; dr = f"{q}$H$5:$H${4 + n}"
    ng = max(len([r for r in d["rans"] if r[3] and r[0] is not None]), 1); gl = f"{q}$Y$5:$Y${4 + ng}"; gd = f"{q}$Z$5:$Z${4 + ng}"
    ldt = f"{q}$D$5:$D${4 + n}"; ldn = f"{q}$M$5:$M${4 + n}"; ldr = f"{q}$N$5:$N${4 + n}"
    mrow = 4 + n + 2
    vals = [name, d["re"], f"=MAX({ct})", f"=INDEX({a},MATCH(MAX({ct}),{ct},0))", f"=MAX({cn})", f"=INDEX({a},MATCH(MAX({cn}),{cn},0))",
            f'=IFERROR(MAX({gl}),"")', f"=MIN({dt})", f"=MIN({dn})", f'=IFERROR(MIN({gd}),"")', f"=MAX({ldt})", f"=MAX({ldn})",
            f'=IFERROR(MAX({ldr}),"")', f"={q}I{mrow}", f"={q}J{mrow}", f"={q}K{mrow}", f"={q}L{mrow}",
            f"={q}B{mrow + 5}", f"={q}B{mrow + 6}", f"={q}B{mrow + 7}", f"={q}D{mrow + 5}", f"={q}D{mrow + 6}", f"={q}D{mrow + 7}",
            f"={q}F{mrow + 6}", f"={q}F{mrow + 7}",
            f"{len([r for r in d['rans'] if r[3]])} of {len(d['rans'])}", notes.get(name, "")]
    fmts = [None, "#,##0", "0.000", "0.0", "0.000", "0.0", "0.000", "0.0000", "0.0000", "0.0000", "0.0", "0.0", "0.0",
            "0.0%", "0.0%", "0.0%", "0.0%", "0.0000", "0.0000", "0.0000", "0.00", "0.00", "0.00",
            "+0.000;-0.000", "+0.000;-0.000", None, None]
    for c, (v, f) in enumerate(zip(vals, fmts), start=1):
        cell = put(s, row, c, v, Font(name=F, size=10, color="008000") if isinstance(v, str) and v.startswith("=") else B, f)
        if c == len(vals): cell.alignment = Alignment(wrap_text=True, vertical="top"); cell.font = GREY
    s.row_dimensions[row].height = 54
for c, w in enumerate([12, 10] + [10] * 24 + [70], start=1):
    s.column_dimensions[L(c)].width = w
s.freeze_panes = "B5"

# Method
mt = method
lines = [
    ("Method and notes", TITLE),
    ("Source", BB),
    ("Selig, Guglielmo, Broeren and Giguère, Summary of Low-Speed Airfoil Data, Vol. 1, SoarTech Publications (1995), Appendix B (polar tables). "
     "The tables were read from the PDF's OCR text layer, page by page and column by column; each row is three numbers (α to 2 decimals, Cl to 3, Cd to 4) "
     "and was checked for range and rising angle. Lift by force balance, drag by wake rake (the average of four spanwise stations).", B),
    ("Tunnel conditions", BB),
    ("UIUC low-turbulence tunnel, 2.8 x 4.0 ft test section, turbulence intensity below about 0.1%. Data corrected for tunnel walls by the authors. "
     "Each tunnel model is a built model, not the true shape: the book compares each with its true coordinates; small differences matter most at low Reynolds number.", B),
    ("AeroBench quick estimate", BB),
    ("NeuralFoil (large model), the section alone at the tunnel's Reynolds number, Ncrit 9 (a clean tunnel), at the tunnel's own angles. "
     "This is what Wing Lab's live estimate gives for a single element. Shapes: true coordinates from the UIUC library (E387, FX 63-137, S1210, S1223) and the NACA 4-digit formulas (NACA 6409).", B),
    ("AeroBench RANS", BB),
    ("SU2 incompressible RANS, Langtry-Menter SST transition model, fine mesh, Ncrit 9, turbulence intensity 0.1% (Wing Lab's default is 1%; a clean tunnel is nearer 0.1%). "
     "A Full polar: every 2 degrees over the tunnel's range, each angle started from the one below, no time limit. Chord 300 mm, speed set to match the tunnel's Reynolds number. "
     "Only converged runs are used for the interpolated columns and the curves; every run is listed with its note on each sheet.", B),
    ("Errors", BB),
    ("(AeroBench − tunnel) / tunnel at each tunnel angle. Cl errors are left blank where the tunnel's |Cl| < 0.1. Means are of the absolute error. "
     "RANS values at the tunnel's angles are linear interpolations between neighbouring converged RANS angles (formulas, so they update if the RANS table is edited).", B),
    ("Linear range", BB),
    ("Each sheet fits a straight line to Cl against α over a range you set (blue cells, default -2 to 6°): the lift slope, the zero-lift angle and Cl at 0°. "
     "A matching slope with a constant Cl offset means the curve is shifted, not tilted. Mean Cl offset is the average of (AeroBench Cl − tunnel Cl) at the tunnel's angles.", B),
    ("What the comparison shows", BB),
    ("The quick estimate's lift slope is 5-29% steeper than the tunnel's on every section (worst on the cambered S1223 and S1210), so its Cl error grows with angle. Its drag is 10-21% off and its L/D max 20-40% high. "
     "RANS gets the slope within about 5%, Cd within 1-9% where it converged, and reads Cl about 0.04-0.09 high (0.14 on the S1210, from three points). "
     "RANS failed to converge at low angles on the NACA 6409 and S1210 and near stall on every section: its Cl max is not trustworthy without longer or time-accurate runs.", B),
    ("Reading the charts", BB),
    ("Black circles: tunnel. Orange dashed: the quick estimate. Blue with diamonds: RANS (converged angles). All three overlaid on each chart.", B),
]
row = 1
for text, font in lines:
    c = mt.cell(row, 1, text); c.font = font; c.alignment = Alignment(wrap_text=True, vertical="top")
    if font is B: mt.row_dimensions[row].height = 64
    row += 1
mt.column_dimensions["A"].width = 130
wb.move_sheet("Method and notes", offset=len(order))
wb.save(dest)
print("saved", dest)
