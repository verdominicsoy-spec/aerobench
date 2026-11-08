import XCTest
import simd
@testable import AeroBenchKit

/// The live flow (panel method, wakes from the live estimate's drag) against three
/// RANS runs cut down in docs/validation/live-field/ (make_fixtures.py there).
/// What each number means, and where the bands come from:
/// docs/superpowers/specs/2026-11-07-live-field-vs-rans-design.md.
final class LiveFieldValidationTests: XCTestCase {
    func testTheHarnessReproducesTheMeasurements() throws {
        let c = try ValidationCase.load("20261106-171046-1b32")
        let s = preview(c, matched: false)
        let live = try XCTUnwrap(s.field(nx: 400, wakeCd: c.estimateCdOwn))
        let f = fieldCp(live, c)
        print("harness 1b32 Kutta:", f, streamlineError(s, c))
        XCTAssertEqual(f.nearRMS, 0.146, accuracy: 0.04)
        XCTAssertEqual(f.nearBias, -0.055, accuracy: 0.03)
        XCTAssertEqual(streamlineError(s, c).p50, 0.021, accuracy: 0.008)
        let g = try ValidationCase.load("20261106-120151-c003")
        XCTAssertEqual(fieldCp(try XCTUnwrap(preview(g, matched: false).field(nx: 400, wakeCd: g.estimateCdOwn)), g).nearRMS, 0.77, accuracy: 0.15)
    }

    /// With each element's lift the estimate's, the flow round the wing comes to
    /// RANS's: bands from the spec's prototype, about half again its worst case.
    func testMatchedLiftBringsTheFlowToRans() throws {
        for (id, near, outer, p50, p95) in [("20261106-171046-1b32", 0.08, 0.04, 0.015, 0.03),
                                            ("20261104-173556-baec", 0.08, 0.04, 0.015, 0.03),
                                            ("20261106-120151-c003", 0.15, 0.07, 0.03, 0.06)] {
            let (c, s, live) = try matchedFlow(id)
            XCTAssertTrue(s.liftMatched, id)
            let f = fieldCp(live, c), e = streamlineError(s, c), mid = surfaceCpMidRMS(s, c)
            print("matched \(id):", f, e, "surface mid", mid)
            XCTAssertLessThan(f.nearRMS, near, id)
            XCTAssertLessThan(f.outerRMS, outer, id)
            XCTAssertLessThan(e.p50, p50, id)
            XCTAssertLessThan(e.p95, p95, id)
            XCTAssertLessThan(mid, id.hasSuffix("c003") ? 0.6 : 0.25, id)
        }
    }

    /// At a quarter and a half reference chord behind the last trailing edge the
    /// wake's centre sits where RANS's does (it ran 0.025–0.12 high on Kutta lift).
    func testMatchedWakesSitWhereRansPutsThem() throws {
        for id in allCases {
            let (c, _, live) = try matchedFlow(id)
            for x in stations(c) {
                let l = try XCTUnwrap(wakeMoments(live, x: x)), r = try XCTUnwrap(wakeMoments(c.rans, x: x))
                print("wake \(id) at x \(x): live", l, "RANS", r)
                XCTAssertLessThan(abs(l.yc - r.yc) / c.refChord, 0.02, "\(id) at x = \(x)")
            }
        }
    }
}

let allCases = ["20261106-171046-1b32", "20261104-173556-baec", "20261106-120151-c003"]

/// Each case's lift-matched preview and its live field at the app's size, made
/// once per test run (a debug build takes about ten seconds a field).
func matchedFlow(_ id: String) throws -> (ValidationCase, PanelSolution, WingField) {
    if let done = matchedFlows[id] { return done }
    let c = try ValidationCase.load(id)
    let s = preview(c, matched: true)
    let done = (c, s, try XCTUnwrap(s.field(nx: 400, wakeCd: c.estimateCdOwn)))
    matchedFlows[id] = done
    return done
}
nonisolated(unsafe) private var matchedFlows: [String: (ValidationCase, PanelSolution, WingField)] = [:]

// MARK: The harness

struct ValidationCase {
    let id: String
    let elements: [[SIMD2<Double>]]
    let alpha: Double
    let rideHeight: Double?
    let refChord: Double
    let rans: WingField
    let ransSurface: [(x: [Double], y: [Double], cp: [Double])]
    let estimateCl: [Double]
    let estimateCdOwn: [Double]

    private struct File: Decodable {
        struct Surface: Decodable { let x: [Double]; let y: [Double]; let cp: [Double] }
        struct Rans: Decodable { let surface: [Surface] }
        struct Estimate: Decodable { let el_cl: [Double]; let cd_own: [Double] }
        let elements: [[[Double]]]
        let alpha: Double
        let ride_height: Double?
        let ref_chord: Double
        let rans: Rans
        let estimate: Estimate
    }

    static func load(_ id: String) throws -> ValidationCase {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // AeroBenchKit
            .deletingLastPathComponent().deletingLastPathComponent()  // the repository
            .appendingPathComponent("docs/validation/live-field/\(id)")
        let f = try JSONDecoder().decode(File.self, from: Data(contentsOf: folder.appendingPathComponent("case.json")))
        return ValidationCase(id: id, elements: f.elements.map { $0.map { SIMD2($0[0], $0[1]) } }, alpha: f.alpha,
                              rideHeight: f.ride_height, refChord: f.ref_chord, rans: try WingField.load(from: folder),
                              ransSurface: f.rans.surface.map { ($0.x, $0.y, $0.cp) },
                              estimateCl: f.estimate.el_cl, estimateCdOwn: f.estimate.cd_own)
    }

    /// Each element's trailing edge: the middle of its first and last points.
    func trailingEdge(_ i: Int) -> SIMD2<Double> { 0.5 * (elements[i][0] + elements[i][elements[i].count - 1]) }
}

/// The preview as `WingLabModel.recompute()` makes it; `matched`: with the
/// estimate's lift, as when the estimate is of the wing as drawn. Every case has alpha 0,
/// so the turned ground frame is the wing's.
func preview(_ c: ValidationCase, matched: Bool) -> PanelSolution {
    precondition(c.alpha == 0, "the harness assumes the wing frame is the flow's")
    let targets = matched ? c.estimateCl : nil
    if let h = c.rideHeight {
        let ground = c.elements.flatMap { $0 }.map(\.y).min()! - h
        let solver = PanelSolver(elements: c.elements, refChord: c.refChord, ground: ground)!
        if let targets { return solver.solve(alphaDeg: 0, targetCl: targets) }
        let image = solver.solve(alphaDeg: 0)
        let free = PanelSolver(elements: c.elements, refChord: c.refChord)?.solve(alphaDeg: c.alpha)
        return free.map { image.groundCorrected(free: $0) } ?? image
    }
    let solver = PanelSolver(elements: c.elements, refChord: c.refChord)!
    return targets.map { solver.solve(alphaDeg: c.alpha, targetCl: $0) } ?? solver.solve(alphaDeg: c.alpha)
}

/// Field Cp minus RANS's on the RANS grid, where both have flow. "Near": within
/// 0.25 reference chords of an element and outside RANS's losses (Cp0 ≥ −0.02);
/// "outer": the rest outside the losses.
func fieldCp(_ live: WingField, _ c: ValidationCase) -> (nearRMS: Double, nearBias: Double, outerRMS: Double) {
    let r = c.rans
    let dx = (r.window.x1 - r.window.x0) / Double(r.nx), dy = (r.window.y1 - r.window.y0) / Double(r.ny)
    let nodes = c.elements.flatMap { $0 }, reach = 0.25 * c.refChord
    var near: [Double] = [], outer: [Double] = []
    for j in 0..<r.ny {
        for i in 0..<r.nx {
            let p = SIMD2(r.window.x0 + (Double(i) + 0.5) * dx, r.window.y0 + (Double(j) + 0.5) * dy)
            guard let rc = r.value("cp", at: p), let lc = live.value("cp", at: p), let r0 = r.value("cp0", at: p), r0 >= -0.02 else { continue }
            if nodes.contains(where: { simd_distance($0, p) < reach }) { near.append(lc - rc) } else { outer.append(lc - rc) }
        }
    }
    let rms = { (v: [Double]) in (v.reduce(0) { $0 + $1 * $1 } / Double(max(v.count, 1))).squareRoot() }
    return (rms(near), near.reduce(0, +) / Double(max(near.count, 1)), rms(outer))
}

/// From each RANS streamline's first point, the panel flow traced (RK2, steps of
/// 0.002 reference chords) for that streamline's length: how far its end lands
/// from RANS's, over the reference chord. Traces that stall or enter a body are left out.
func streamlineError(_ s: PanelSolution, _ c: ValidationCase) -> (p50: Double, p95: Double) {
    let panels = VortexPanels(s), h = 0.002 * c.refChord
    var errors: [Double] = []
    for line in c.rans.streamlines where line.count > 2 {
        let length = zip(line, line.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
        var p = line[0], gone = 0.0, ok = true
        while gone < length {
            guard let d1 = panels.direction(p), let d2 = panels.direction(p + 0.5 * h * d1) else { ok = false; break }
            p += h * d2
            gone += h
            if panels.inside(p) { ok = false; break }
        }
        if ok { errors.append(simd_distance(p, line[line.count - 1]) / c.refChord) }
    }
    let e = errors.sorted()
    guard !e.isEmpty else { return (.nan, .nan) }
    return (e[e.count / 2], e[Int(Double(e.count - 1) * 0.95)])
}

/// Across the flow at x (steps of 0.5 mm), weighted by the loss −Cp0 where
/// Cp0 < −0.005: the loss's centroid and second-moment half-width.
func wakeMoments(_ f: WingField, x: Double) -> (yc: Double, sd: Double)? {
    var w = 0.0, wy = 0.0, wyy = 0.0
    for y in stride(from: f.window.y0, through: f.window.y1, by: 0.0005) {
        guard let c = f.value("cp0", at: SIMD2(x, y)), c < -0.005 else { continue }
        w -= c; wy -= c * y; wyy -= c * y * y
    }
    guard w > 0 else { return nil }
    let yc = wy / w
    return (yc, max(wyy / w - yc * yc, 0).squareRoot())
}

/// Surface Cp RMS against RANS over the panel nodes between 5% and 95% of each
/// element's chord from its trailing edge, each against the nearest RANS surface
/// point of the same element.
func surfaceCpMidRMS(_ s: PanelSolution, _ c: ValidationCase) -> Double {
    var d: [Double] = []
    for (i, e) in c.elements.enumerated() where i < s.cp.count && i < c.ransSurface.count {
        let r = c.ransSurface[i], pts = zip(r.x, r.y).map { SIMD2($0, $1) }
        let te = c.trailingEdge(i), chord = e.map { simd_distance($0, te) }.max()!
        for (k, p) in e.enumerated() where k < s.cp[i].count {
            let t = simd_distance(p, te)
            guard t > 0.05 * chord, t < 0.95 * chord,
                  let j = pts.indices.min(by: { simd_distance(pts[$0], p) < simd_distance(pts[$1], p) }) else { continue }
            d.append(s.cp[i][k] - r.cp[j])
        }
    }
    return (d.reduce(0) { $0 + $1 * $1 } / Double(max(d.count, 1))).squareRoot()
}

/// Wake stations: a quarter and a half reference chord behind the last trailing edge.
func stations(_ c: ValidationCase) -> [Double] {
    let last = c.elements.indices.map(c.trailingEdge).map(\.x).max()!
    return [0.25, 0.5].map { last + $0 * c.refChord }
}
