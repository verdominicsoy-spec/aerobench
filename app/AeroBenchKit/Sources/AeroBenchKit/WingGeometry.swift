import Foundation
import simd

/// A normalised section from the library: Selig order, unit chord, leading
/// edge at the origin, chord along +x.
public struct Airfoil: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var key: String  // "naca/2412", "uiuc/e423", "mine/my_flap"
    public var name: String
    public var family: String
    public var source: String
    public var thickness: Double
    public var thicknessX: Double
    public var camber: Double
    public var camberX: Double
    public var teThickness: Double
    public var coords: [SIMD2<Double>]

    public var id: String { key }

    public init(key: String, name: String, family: String, source: String, thickness: Double, thicknessX: Double,
                camber: Double, camberX: Double, teThickness: Double, coords: [SIMD2<Double>]) {
        self.key = key
        self.name = name
        self.family = family
        self.source = source
        self.thickness = thickness
        self.thicknessX = thicknessX
        self.camber = camber
        self.camberX = camberX
        self.teThickness = teThickness
        self.coords = coords
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// One element of a multi-element wing, in the wing's frame (metres, x
/// downstream, y up). The angle works the same way upright or inverted:
/// a bigger angle means more lift, or more downforce when inverted.
public struct WingElement: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var airfoil: Airfoil
    public var chord: Double
    public var angle: Double  // degrees, angle of attack of this element's chord
    public var leadingEdge: SIMD2<Double>
    public var inverted: Bool

    public init(id: UUID = UUID(), airfoil: Airfoil, chord: Double, angle: Double = 0,
                leadingEdge: SIMD2<Double> = .zero, inverted: Bool = true) {
        self.id = id
        self.airfoil = airfoil
        self.chord = chord
        self.angle = angle
        self.leadingEdge = leadingEdge
        self.inverted = inverted
    }

    /// The rotation applied to the unit section: angle of attack is trailing
    /// edge down for an upright section, trailing edge up for an inverted one.
    var rotation: Double { (inverted ? 1 : -1) * angle * .pi / 180 }

    /// Points in the wing frame, Selig order (counter-clockwise) either way up.
    public func placed() -> [SIMD2<Double>] {
        var unit = airfoil.coords
        if inverted { unit = unit.reversed().map { SIMD2($0.x, -$0.y) } }
        let c = cos(rotation), s = sin(rotation)
        return unit.map { p in leadingEdge + chord * SIMD2(c * p.x - s * p.y, s * p.x + c * p.y) }
    }

    /// The trailing edge: the middle of the gap between the surfaces' ends.
    public var trailingEdge: SIMD2<Double> {
        let c = cos(rotation), s = sin(rotation)
        let mid = 0.5 * ((airfoil.coords.first ?? .zero) + (airfoil.coords.last ?? .zero))
        let p = inverted ? SIMD2(mid.x, -mid.y) : mid
        return leadingEdge + chord * SIMD2(c * p.x - s * p.y, s * p.x + c * p.y)
    }

    /// Unit vector from leading to trailing edge.
    public var chordDirection: SIMD2<Double> { simd_normalize(trailingEdge - leadingEdge) }
}

/// A rectangle the wing must fit in, from the rules (entered by the user,
/// never built in).
public struct RulesBox: Codable, Equatable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public func contains(_ p: SIMD2<Double>) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
}

public struct WingIssue: Equatable, Sendable {
    public enum Kind: String, Sendable { case intersects, tooClose, outsideRules }
    public var kind: Kind
    public var elements: [Int]
    public var distance: Double?

    public var message: String {
        let names = elements.map { WingIssue.label($0) }.joined(separator: " and ")
        switch kind {
        case .intersects: return "\(names) intersect."
        case .tooClose: return "\(names) are \(String(format: "%.1f", (distance ?? 0) * 1000)) mm apart, closer than the minimum gap."
        case .outsideRules: return "\(names) reaches outside the rules box."
        }
    }

    public static func label(_ index: Int) -> String { index == 0 ? "Main" : "Flap \(index)" }
}

/// A multi-element wing in a free plane: not placed on the car.
public struct Wing: Codable, Equatable, Sendable {
    public var elements: [WingElement]
    public var alpha: Double  // degrees, the whole wing to the freestream
    public var rulesBox: RulesBox?
    public var minGap: Double  // m, closer than this is flagged
    public var span: Double  // m, for turning 2D coefficients into ClA and CdA
    public var factor3D: Double  // 2D to 3D: below 1 for a finite wing, user's estimate
    /// Endplate height (m). Set, the 3D factor and induced drag are estimated
    /// from span, chord and endplates (finite3D); nil, factor3D is used as typed.
    public var endplateHeight: Double?
    /// From the wing's lowest point to the ground (m), for a front wing in
    /// ground effect; nil is free air.
    public var rideHeight: Double?
    public var speed: Double  // m/s, for the viscous solvers' Reynolds number
    public var rho: Double  // kg/m^3
    public var mu: Double  // Pa s

    public init(elements: [WingElement] = [], alpha: Double = 0, rulesBox: RulesBox? = nil, minGap: Double = 0.005,
                span: Double = 1.0, factor3D: Double = 1.0, endplateHeight: Double? = nil, speed: Double = 15,
                rho: Double = 1.225, mu: Double = 1.81e-5) {
        self.elements = elements
        self.alpha = alpha
        self.rulesBox = rulesBox
        self.minGap = minGap
        self.span = span
        self.factor3D = factor3D
        self.endplateHeight = endplateHeight
        self.speed = speed
        self.rho = rho
        self.mu = mu
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        elements = try c.decodeIfPresent([WingElement].self, forKey: .elements) ?? []
        alpha = try c.decodeIfPresent(Double.self, forKey: .alpha) ?? 0
        rulesBox = try c.decodeIfPresent(RulesBox.self, forKey: .rulesBox)
        minGap = try c.decodeIfPresent(Double.self, forKey: .minGap) ?? 0.005
        span = try c.decodeIfPresent(Double.self, forKey: .span) ?? 1.0
        factor3D = try c.decodeIfPresent(Double.self, forKey: .factor3D) ?? 1.0
        endplateHeight = try c.decodeIfPresent(Double.self, forKey: .endplateHeight)
        rideHeight = try c.decodeIfPresent(Double.self, forKey: .rideHeight)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 15
        rho = try c.decodeIfPresent(Double.self, forKey: .rho) ?? 1.225
        mu = try c.decodeIfPresent(Double.self, forKey: .mu) ?? 1.81e-5
    }

    /// Reynolds number on a chord at the wing's flow conditions.
    public func reynolds(chord: Double) -> Double { rho * speed * chord / max(mu, 1e-12) }

    /// Coefficients are on the sum of the element chords.
    public var refChord: Double { max(elements.reduce(0) { $0 + $1.chord }, 1e-9) }

    // MARK: Measures

    /// Minimum distance from the previous element's trailing edge to this
    /// element's surface. Nil for the main element.
    public func gap(of index: Int) -> Double? {
        guard index > 0, index < elements.count else { return nil }
        return Self.closest(elements[index - 1].trailingEdge, on: elements[index].placed()).distance
    }

    /// How far this element's leading edge sits ahead of the previous
    /// element's trailing edge, along the main element's chord line.
    public func overlap(of index: Int) -> Double? {
        guard index > 0, index < elements.count else { return nil }
        let u = elements[0].chordDirection
        return simd_dot(elements[index - 1].trailingEdge - elements[index].leadingEdge, u)
    }

    /// Moves the element (and the ones behind it) so its gap is `target`.
    public mutating func setGap(_ target: Double, of index: Int) {
        guard index > 0, index < elements.count, target >= 0 else { return }
        for _ in 0..<6 {
            let te = elements[index - 1].trailingEdge
            let near = Self.closest(te, on: elements[index].placed())
            guard near.distance > 1e-12 else { break }
            let dir = (near.point - te) / near.distance
            let shift = (target - near.distance) * dir
            guard simd_length(shift) > 1e-10 else { break }
            move(from: index, by: shift)
        }
    }

    /// Moves the element (and the ones behind it) so its overlap is `target`.
    public mutating func setOverlap(_ target: Double, of index: Int) {
        guard let current = overlap(of: index) else { return }
        move(from: index, by: (current - target) * elements[0].chordDirection)
    }

    /// Shifts element `index` and every element after it, keeping their
    /// gaps to each other.
    public mutating func move(from index: Int, by shift: SIMD2<Double>) {
        for i in index..<elements.count { elements[i].leadingEdge += shift }
    }

    // MARK: Checks

    public var issues: [WingIssue] {
        var out: [WingIssue] = []
        let shapes = elements.map { $0.placed() }
        for i in 0..<shapes.count {
            for j in (i + 1)..<max(shapes.count, i + 1) {
                if Self.intersect(shapes[i], shapes[j]) {
                    out.append(WingIssue(kind: .intersects, elements: [i, j]))
                } else {
                    let d = Self.distance(shapes[i], shapes[j])
                    if d < minGap { out.append(WingIssue(kind: .tooClose, elements: [i, j], distance: d)) }
                }
            }
            if let box = rulesBox, !shapes[i].allSatisfy(box.contains) {
                out.append(WingIssue(kind: .outsideRules, elements: [i]))
            }
        }
        return out
    }

    // MARK: Geometry helpers

    static func closest(_ p: SIMD2<Double>, on poly: [SIMD2<Double>]) -> (point: SIMD2<Double>, distance: Double) {
        var best = (point: poly.first ?? p, distance: Double.infinity)
        for k in 0..<max(poly.count - 1, 0) {
            let a = poly[k], b = poly[k + 1]
            let ab = b - a
            let t = min(max(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-300), 0), 1)
            let q = a + t * ab
            let d = simd_length(p - q)
            if d < best.distance { best = (q, d) }
        }
        return best
    }

    static func distance(_ a: [SIMD2<Double>], _ b: [SIMD2<Double>]) -> Double {
        var d = Double.infinity
        for p in a { d = min(d, closest(p, on: b).distance) }
        for p in b { d = min(d, closest(p, on: a).distance) }
        return d
    }

    static func intersect(_ a: [SIMD2<Double>], _ b: [SIMD2<Double>]) -> Bool {
        func cross(_ u: SIMD2<Double>, _ v: SIMD2<Double>) -> Double { u.x * v.y - u.y * v.x }
        for i in 0..<max(a.count - 1, 0) {
            let p = a[i], r = a[i + 1] - a[i]
            for j in 0..<max(b.count - 1, 0) {
                let q = b[j], s = b[j + 1] - b[j]
                let den = cross(r, s)
                guard abs(den) > 1e-300 else { continue }
                let t = cross(q - p, s) / den, u = cross(q - p, r) / den
                if t >= 0 && t <= 1 && u >= 0 && u <= 1 { return true }
            }
        }
        // One inside the other (no crossing edges).
        return inside(a[0], b) || inside(b[0], a)
    }

    public static func inside(_ p: SIMD2<Double>, _ poly: [SIMD2<Double>]) -> Bool {
        var c = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }

    // MARK: Export

    /// A .dat file (Selig order, name line) of one element as placed, in mm.
    public func datFile(of index: Int) -> String {
        let e = elements[index]
        var lines = ["\(e.airfoil.name) (\(WingIssue.label(index)), mm, wing frame)"]
        lines += e.placed().map { String(format: "%.4f %.4f", $0.x * 1000, $0.y * 1000) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Every element's points in mm, one row per point: element, index, x, y.
    public func csvFile() -> String {
        var lines = ["element,index,x_mm,y_mm"]
        for (i, e) in elements.enumerated() {
            for (k, p) in e.placed().enumerated() {
                lines.append("\(WingIssue.label(i)),\(k),\(String(format: "%.4f", p.x * 1000)),\(String(format: "%.4f", p.y * 1000))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Lap Sim

    /// The finite wing from span, total chord and endplates (engine:
    /// wing/finite.py, the same formulas). Endplates raise the effective
    /// aspect ratio, AR (1 + 1.9 h / b) (Hoerner); lifting-line theory then
    /// scales the 2D lift by AR_eff / (AR_eff + 2) and adds induced drag
    /// CL^2 / (pi AR_eff). Nil without an endplate height.
    public var finite3D: (aspectRatio: Double, effectiveAspectRatio: Double, liftFactor: Double)? {
        guard let h = endplateHeight else { return nil }
        let ar = span / refChord
        let eff = ar * (1 + 1.9 * max(h, 0) / max(span, 1e-9))
        return (ar, eff, eff / (eff + 2))
    }

    /// With a ride height: the elements turned so the flow at the wing's angle
    /// runs along x, and the height of the ground under them (as the engine's
    /// estimate.in_ground_effect). The ground lies along the flow.
    public var inGroundEffect: (elements: [[SIMD2<Double>]], ground: Double)? {
        guard let h = rideHeight else { return nil }
        let a = alpha * Double.pi / 180
        let turned = elements.map { e in e.placed().map { SIMD2($0.x * cos(a) + $0.y * sin(a), -$0.x * sin(a) + $0.y * cos(a)) } }
        let lowest = turned.flatMap { $0 }.map(\.y).min() ?? 0
        return (turned, lowest - h)
    }

    /// The ground line in the wing's own frame, for drawing: a point on it and
    /// its direction (along the flow).
    public var groundLine: (point: SIMD2<Double>, direction: SIMD2<Double>)? {
        guard let g = inGroundEffect else { return nil }
        let a = alpha * Double.pi / 180
        let dir = SIMD2(cos(a), sin(a))
        // (0, g) in the turned frame, turned back into the wing's.
        return (SIMD2(-g.ground * sin(a), g.ground * cos(a)), dir)
    }

    /// The 2D-to-3D lift factor in use: estimated, or as typed.
    public var liftFactor3D: Double { finite3D?.liftFactor ?? factor3D }

    /// What this wing adds to a car, from 2D coefficients on the reference
    /// chord in the wing frame (y up): downforce ClA, which is -Cl either
    /// way up (positive for a downforce wing), and CdA, with induced drag
    /// when the 3D factor is estimated.
    public func carContribution(cl: Double, cd: Double) -> (cla: Double, cda: Double) {
        let area = span * refChord
        guard let f = finite3D else { return (-cl * area * factor3D, cd * area * factor3D) }
        let cl3 = cl * f.liftFactor
        let induced = cl3 * cl3 / (Double.pi * f.effectiveAspectRatio)
        return (-cl3 * area, (cd + induced) * area)
    }
}
