import Foundation
import simd

/// The base car: its STEP, wheels and ground (car frame, mm: +x forward,
/// +y left, z up), as the engine's car-setup finds them and the user confirms.
public struct CarSetup: Codable, Equatable, Sendable {
    public struct Wheel: Codable, Equatable, Sendable {
        public var name: String  // FL, FR, RL, RR
        public var centre: [Double]
        public var radius: Double
        public var width: Double

        public init(name: String, centre: [Double], radius: Double, width: Double) {
            self.name = name
            self.centre = centre
            self.radius = radius
            self.width = width
        }
    }

    public var step: String
    public var forward = "+x"
    public var up = "+z"
    public var wheels: [Wheel]
    public var groundZ: Double
    public var headRestraint: [Double]?  // x, z mm, marked by the user
    public var speed = 15.0

    public init(step: String, wheels: [Wheel], groundZ: Double, headRestraint: [Double]? = nil, speed: Double = 15) {
        self.step = step
        self.wheels = wheels
        self.groundZ = groundZ
        self.headRestraint = headRestraint
        self.speed = speed
    }

    enum CodingKeys: String, CodingKey {
        case step, forward, up, wheels, speed
        case groundZ = "ground_z"
        case headRestraint = "head_restraint"
    }

    public func axleX(_ axle: Character) -> Double {
        let xs = wheels.filter { $0.name.first == axle }.map { $0.centre[0] }
        return xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }

    public func radius(_ axle: Character) -> Double {
        wheels.first { $0.name.first == axle }?.radius ?? 0
    }

    public var wheelbase: Double { axleX("F") - axleX("R") }

    /// Half the width to the outermost point of the axle's wheels (mm, from the centreline)
    public func outerHalfWidth(_ axle: Character) -> Double {
        wheels.filter { $0.name.first == axle && $0.centre.count > 1 }.map { abs($0.centre[1]) + $0.width / 2 }.max() ?? 0
    }

    /// Half the width to the most inboard point of the axle's tyres (mm, from the centreline)
    public func innerHalfWidth(_ axle: Character) -> Double {
        wheels.filter { $0.name.first == axle && $0.centre.count > 1 }.map { abs($0.centre[1]) - $0.width / 2 }.min() ?? 0
    }

    /// Height of the axle's tyre tops (car z, mm)
    public func tyreTop(_ axle: Character) -> Double {
        let tops = wheels.filter { $0.name.first == axle && $0.centre.count > 2 }.map { $0.centre[2] + $0.radius }
        return tops.isEmpty ? groundZ : tops.reduce(0, +) / Double(tops.count)
    }

    public static func decode(resultFile data: Data) throws -> CarSetup {
        struct Envelope: Decodable { var data: CarSetup }
        return try JSONDecoder().decode(Envelope.self, from: data).data
    }
}

/// The engine's car result (command car-strips): the centreline section's 2D numbers,
/// held in strips as one section. Older runs (strips across the car, 3D ClA and CdA)
/// decode with no Cl: they are run again.
public struct CarResult: Codable, Equatable, Sendable {
    public struct Strip: Codable, Equatable, Sendable {
        public var y: Double
        public var width: Double?  // older strips runs only
        public var lift: Double  // N/m, up +
        public var drag: Double
        public var xCp: Double?  // mm, car x; nil when the section carries no lift
        public var converged: Bool
        public var reason: String?
        public var wingLift: [String: Double]
        public var wingDrag: [String: Double]
        public var folder: String?  // its run in the job folder: section (strip_3 in older runs)
        public var fieldView: String?  // field.json in that folder, when the flow was sampled

        enum CodingKeys: String, CodingKey {
            case y, width, lift, drag, converged, reason, folder
            case fieldView = "field_view"
            case xCp = "x_cp"
            case wingLift = "wing_lift"
            case wingDrag = "wing_drag"
        }
    }

    public struct WingShare: Codable, Equatable, Sendable {
        public var position: String
        public var chord: Double?  // m
        public var cl: Double?  // 2D, on its own chord, lift up +; nil in older runs
        public var cd: Double?
    }

    public var mesh: String
    public var speed: Double
    public var cl: Double?  // 2D, on refLength, lift up +: a car pressed down has a negative Cl
    public var cd: Double?
    public var refLength: Double?  // m, the section's extent along x
    public var rearShare: Double?
    public var strips: [Strip]
    public var converged: Bool
    public var wings: [WingShare]
    public struct Failure: Codable, Equatable, Sendable {
        public var y: Double
        public var width: Double
        public var reason: String
    }

    public var n: Int?  // sections across half the car: 1 now, more in older strips runs
    public var failed: [Failure]?  // older strips runs: strips that would not solve, left out of the totals
    public var openGaps: Int?  // places the CAD's cut did not close, over all sections
    public var flow: JSONValue?  // the speed, ground and wheel options it was run with
    public var folder: String?  // the job's folder in the project's jobs, where the section's flow is

    /// Run with these settings: same section count, and the same speeds and options, numbers
    /// compared as numbers (the engine's 15.0 can come back as the integer 15).
    public func ranWith(_ other: JSONValue, n: Int) -> Bool {
        func same(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
            switch (a, b) {
            case (.object(let x)?, .object(let y)?):
                return Set(x.keys) == Set(y.keys) && x.keys.allSatisfy { same(x[$0], y[$0]) }
            case (.int(let x)?, .double(let y)?), (.double(let y)?, .int(let x)?): return abs(Double(x) - y) < 1e-9
            case (.double(let x)?, .double(let y)?): return abs(x - y) < 1e-9
            default: return a == b
            }
        }
        return self.n == n && same(flow, other)
    }

    /// Whether it ran over a moving ground (unverified on the real car), when recorded.
    public var groundMoving: Bool? {
        guard case .object(let f)? = flow, case .object(let g)? = f["ground"], case .bool(let m)? = g["moving"] else { return nil }
        return m
    }

    public init(mesh: String, speed: Double, cl: Double?, cd: Double?, refLength: Double?, rearShare: Double?,
                strips: [Strip], converged: Bool, wings: [WingShare], n: Int? = nil, flow: JSONValue? = nil) {
        self.n = n
        self.flow = flow
        self.mesh = mesh
        self.speed = speed
        self.cl = cl
        self.cd = cd
        self.refLength = refLength
        self.rearShare = rearShare
        self.strips = strips
        self.converged = converged
        self.wings = wings
    }

    enum CodingKeys: String, CodingKey {
        case mesh, speed, cl, cd, strips, converged, wings, n, flow, failed, folder
        case refLength = "ref_length"
        case rearShare = "rear_share"
        case openGaps = "open_gaps"
    }

    public static func decode(resultFile data: Data) throws -> CarResult {
        struct Envelope: Decodable { var data: CarResult }
        return try JSONDecoder().decode(Envelope.self, from: data).data
    }
}

/// A Wing Lab wing saved for the car: its section and its own numbers.
public struct WingCard: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var position: WingPosition
    public var wing: Wing
    public var cla: Double  // m², downforce +
    public var cda: Double
    public var xcp: Double  // m from the wing's leading edge, downstream: where its downforce acts
    public var solver: String
    public var rideHeight: Double?  // m, the height its numbers were made at (nil: free air)
    public var speed: Double
    public var revision: Int

    /// The 2D Cl and Cd on the wing's reference chord its ClA and CdA were made from.
    public var section: (cl: Double, cd: Double) { wing.sectionCoefficients(cla: cla, cda: cda) }

    public init(id: String, name: String, position: WingPosition, wing: Wing, cla: Double, cda: Double, xcp: Double,
                solver: String, rideHeight: Double?, speed: Double, revision: Int) {
        self.id = id
        self.name = name
        self.position = position
        self.wing = wing
        self.cla = cla
        self.cda = cda
        self.xcp = xcp
        self.solver = solver
        self.rideHeight = rideHeight
        self.speed = speed
        self.revision = revision
    }

    /// A card from a wing and its section numbers, as Wing Lab's Save as Card makes it.
    public static func make(wing: Wing, cl: Double, cd: Double, solver: String, id: String, name: String, revision: Int) -> WingCard {
        let add = wing.carContribution(cl: cl, cd: cd)
        return WingCard(id: id, name: name, position: wing.rulesFor, wing: wing, cla: add.cla, cda: add.cda,
                        xcp: wing.refChord / 4,  // the quarter chord: where a section's lift acts, near enough
                        solver: solver, rideHeight: wing.rideHeight, speed: wing.speed, revision: revision)
    }

    /// The elements turned by the wing's angle as Wing Lab does over a
    /// ground, in the wing's frame (m, x downstream, y up).
    func outline() -> [[SIMD2<Double>]] {
        let a = wing.alpha * .pi / 180, c = cos(a), s = sin(a)
        return wing.elements.map { $0.placed().map { SIMD2(c * $0.x + s * $0.y, -s * $0.x + c * $0.y) } }
    }
}

/// Where a card sits on the car: its leading edge `x` mm ahead of its axle
/// (behind is negative) and its lowest point `height` mm above the ground.
public struct Placement: Codable, Equatable, Sendable {
    public var card: String
    public var x: Double
    public var height: Double

    public init(card: String, x: Double, height: Double) {
        self.card = card
        self.x = x
        self.height = height
    }

    /// The card's elements in car coordinates (x, z mm).
    public func placedElements(card: WingCard, setup: CarSetup) -> [[SIMD2<Double>]] {
        let out = card.outline()
        let all = out.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let minY = all.map(\.y).min() else { return [] }
        let axle = setup.axleX(card.position == .front ? "F" : "R")
        return out.map { el in el.map { p in
            SIMD2(axle + x - (p.x - minX) * 1000, setup.groundZ + height + (p.y - minY) * 1000)
        } }
    }

    /// Where a card first goes on the car: 10 mm inside the front of its box, at its own ride height or just above the clearance.
    public static func start(card: WingCard, setup: CarSetup) -> Placement {
        let box = CarRules.box(card.position, setup: setup, span: card.wing.span)
        let axle = setup.axleX(card.position == .front ? "F" : "R")
        let p = Placement(card: card.id, x: box.maxX - axle - 10,
                          height: max(card.rideHeight.map { $0 * 1000 } ?? 0, box.minZ - setup.groundZ) + 10)
        return p.clamped(card: card, setup: setup).0
    }

    /// Moved the least distance that keeps the whole wing inside its rules box.
    public func clamped(card: WingCard, setup: CarSetup) -> (Placement, clamped: Bool) {
        let box = CarRules.box(card.position, setup: setup, span: card.wing.span)
        let pts = placedElements(card: card, setup: setup).flatMap { $0 }
        guard let lo = pts.map(\.x).min(), let hi = pts.map(\.x).max(),
              let bottom = pts.map(\.y).min(), let top = pts.map(\.y).max() else { return (self, false) }
        var p = self
        if hi > box.maxX { p.x -= hi - box.maxX } else if lo < box.minX { p.x += box.minX - lo }
        if top > box.maxZ { p.height -= top - box.maxZ } else if bottom < box.minZ { p.height += box.minZ - bottom }
        return (p, p != self)
    }
}

/// FS Rules 2027 v1.0 T8.2 limits as boxes in car coordinates (mm), from the
/// wheels, the ground and the head restraint. FSUK 2027 v1.0 takes T8.2 and
/// T2.2 unchanged, so both events share them (data/rules/fs2027_aero.json).
public enum CarRules {
    /// T2.2.1: static, driver seated, any part but the tyres
    public static let groundClearance = 30.0
    /// T8.2.3: at most 700 forward of the front tyres; T8.2.1: below 350 forward of their leading edge
    public static let frontLength = 700.0, frontHeight = 350.0
    /// T8.2.3: at most 250 behind the rear tyres; T8.2.1: below 1100 rearward of the head restraint support's front face
    public static let rearLength = 250.0, rearHeight = 1100.0
    /// T8.2.2: from the rear tyre tops to 700 mm, 150 mm inboard of the rear tyres
    public static let midTop = 700.0, midInboard = 150.0

    /// Whether the card's wing can fit its box at all (no placement keeps a bigger one inside).
    public static func fits(_ card: WingCard, setup: CarSetup) -> Bool {
        let b = box(card.position, setup: setup, span: card.wing.span)
        let pts = card.outline().flatMap { $0 }
        guard let lo = pts.map(\.x).min(), let hi = pts.map(\.x).max(),
              let bottom = pts.map(\.y).min(), let top = pts.map(\.y).max() else { return true }
        return (hi - lo) * 1000 <= b.maxX - b.minX + 1e-6 && (top - bottom) * 1000 <= b.maxZ - b.minZ + 1e-6
    }

    /// The card's box as a rules box in the frame Wing Lab checks it in (the
    /// elements unturned, m), with the wing at `placement`: its leading edge and
    /// lowest point are the anchor. Exact at a wing angle of 0.
    public static func wingBox(_ card: WingCard, placement: Placement, setup: CarSetup) -> RulesBox {
        let b = box(card.position, setup: setup, span: card.wing.span)
        let pts = card.wing.elements.flatMap { $0.placed() }
        let minX = pts.map(\.x).min() ?? 0, minY = pts.map(\.y).min() ?? 0
        let front = setup.axleX(card.position == .front ? "F" : "R") + placement.x  // car x of the leading edge
        let bottom = setup.groundZ + placement.height  // car z of the lowest point
        let y = { (z: Double) in minY + (z - bottom) / 1000 }
        var r = RulesBox(minX: minX + (front - b.maxX) / 1000, minY: y(b.minZ),
                         maxX: minX + (front - b.minX) / 1000, maxY: y(b.maxZ))
        if card.position == .rear {
            r.bands = widthBands(setup).map { RulesBox.Band(minY: y($0.minZ), maxY: y($0.maxZ), maxSpan: $0.maxSpan / 1000, rule: $0.rule) }
        }
        return r
    }

    /// The inverse of `wingBox`: where the wing sits on the car for it to sit
    /// where it does in `box`. Moving the wing on the canvas moves it on the car.
    public static func placement(for card: WingCard, in box: RulesBox, setup: CarSetup) -> Placement {
        let b = self.box(card.position, setup: setup, span: card.wing.span)
        let pts = card.wing.elements.flatMap { $0.placed() }
        let minX = pts.map(\.x).min() ?? 0, minY = pts.map(\.y).min() ?? 0
        let front = b.maxX + (box.minX - minX) * 1000  // car x of the leading edge
        let bottom = b.minZ - (box.minY - minY) * 1000  // car z of the lowest point
        return Placement(card: card.id, x: front - setup.axleX(card.position == .front ? "F" : "R"), height: bottom - setup.groundZ)
    }

    /// T8.2.2 widths for the rear wing's zone, bottom to top (car mm): below the
    /// tyre tops inside the wheels; from the rear tyre tops to 700 mm, 150 mm
    /// inboard of the rear tyres; from 700 to 1100 mm, out to the rear wheels.
    public static func widthBands(_ setup: CarSetup) -> [(minZ: Double, maxZ: Double, maxSpan: Double, rule: String)] {
        let g = setup.groundZ, top = setup.tyreTop("R")
        let envelope = 2 * max(setup.outerHalfWidth("F"), setup.outerHalfWidth("R"))
        return [(g + groundClearance, top, envelope, "T8.2.2: inside the wheels"),
                (top, g + midTop, 2 * max(setup.innerHalfWidth("R") - midInboard, 0), "T8.2.2: 150 mm inboard of the rear tyres"),
                (g + midTop, g + rearHeight, 2 * setup.outerHalfWidth("R"), "T8.2.2: out to the rear wheels")]
            .filter { $0.1 > $0.0 }
    }

    /// The side-view box for one end. With a span, the rear box starts at the
    /// lowest width band (T8.2.2) that span still fits in all the way up.
    public static func box(_ position: WingPosition, setup: CarSetup, span: Double? = nil) -> (minX: Double, maxX: Double, minZ: Double, maxZ: Double) {
        let g = setup.groundZ
        switch position {
        case .front:
            let tyre = setup.axleX("F") + setup.radius("F")
            return (tyre, tyre + frontLength, g + groundClearance, g + frontHeight)
        case .rear:
            let tyre = setup.axleX("R") - setup.radius("R")
            let forward = setup.headRestraint?.first ?? setup.axleX("R")
            var minZ = g + groundClearance
            if let span {
                // from the top down, while the bands still take this span
                for band in widthBands(setup).reversed() {
                    guard span * 1000 <= band.maxSpan + 1e-6 else { minZ = band.maxZ; break }
                    minZ = band.minZ
                }
            }
            return (tyre - rearLength, forward, minZ, g + rearHeight)
        }
    }
}

/// One car to compare: the base car with a front and a rear card, either optional.
public struct Combination: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var front: Placement?
    public var rear: Placement?
    public var full: CarResult?
    // What the full result was run with: it is out of date once any of it changes.
    public var fullFront: Placement?
    public var fullRear: Placement?
    public var cardRevisions: [String: Int] = [:]
    public var baseRevision = 0

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public mutating func recordFull(_ result: CarResult, cards: [WingCard], baseRevision: Int) {
        recordFull(result, ran: self, cards: cards, baseRevision: baseRevision)
    }

    /// The result of a run of `ran` (as it was when the run was asked for, with `cards` then):
    /// anything changed since makes it out of date.
    public mutating func recordFull(_ result: CarResult, ran: Combination, cards: [WingCard], baseRevision: Int) {
        full = result
        fullFront = ran.front
        fullRear = ran.rear
        cardRevisions = Dictionary(uniqueKeysWithValues: [ran.front, ran.rear].compactMap { $0 }.compactMap { p in
            cards.first { $0.id == p.card }.map { ($0.id, $0.revision) }
        })
        self.baseRevision = baseRevision
    }

    /// Where the wing being edited goes: its end's slot, or the start spot when that end is empty,
    /// kept inside the box along x. With a ride height it sits at that height even outside the box:
    /// its numbers are made there, and Wing Lab's rules box flags it.
    public func draftPlacement(_ draft: WingCard, setup: CarSetup) -> Placement {
        let slot = draft.position == .front ? front : rear
        var p = slot ?? Placement.start(card: draft, setup: setup)
        p.card = draft.id
        p = p.clamped(card: draft, setup: setup).0
        if let h = draft.wing.rideHeight { p.height = h * 1000 }
        return p
    }

    /// This combination with the wing being edited at `at` on its end; the stored one is unchanged.
    public func overlaying(_ draft: WingCard, at: Placement) -> Combination {
        var c = self
        if draft.position == .front { c.front = at } else { c.rear = at }
        return c
    }

    public func without(_ position: WingPosition) -> Combination {
        var c = self
        if position == .front { c.front = nil } else { c.rear = nil }
        return c
    }

    /// The full result no longer describes this car: a wing moved or was swapped, a card was
    /// edited, or the bare car was run again. Quick numbers are always current.
    public func isStale(cards: [WingCard], baseRevision: Int) -> Bool {
        guard full != nil else { return false }
        if baseRevision != self.baseRevision || front != fullFront || rear != fullRear { return true }
        for p in [front, rear].compactMap({ $0 }) {
            guard let c = cards.first(where: { $0.id == p.card }) else { return true }
            if cardRevisions[c.id] != c.revision { return true }
        }
        return false
    }
}

public struct QuickResult: Equatable, Sendable {
    public var cl: Double  // 2D, on the bare car's refLength, lift up +
    public var cd: Double
    public var refLength: Double
    public var rearShare: Double?
    public var usedEstimate: [WingPosition]
    public var pendingEstimate: [WingPosition] = []  // re-estimate asked for, not back yet: the card's own numbers meanwhile
}

/// Whether a card placed at `height` (m) needs its numbers re-estimated there:
/// off the height they were made at, or a front wing made in free air now over the ground.
public func needsEstimate(_ card: WingCard, height: Double) -> Bool {
    if let h = card.rideHeight { return abs(height - h) > 0.001 }
    return card.position == .front
}

/// In 2D: the bare car's section plus each placed card's section, each
/// wing's lift acting at its own centre of pressure for the axle split, as
/// Cl and Cd on the bare car's length. A card placed more than 1 mm off the
/// height its numbers were made at is re-estimated there through `estimate`
/// (card, height in m: its 2D Cl and Cd). Nil for a bare car without 2D numbers.
public func quick(base: CarResult, combo: Combination, cards: [WingCard], setup: CarSetup,
                  estimate: (WingCard, Double) -> (cl: Double, cd: Double)?) -> QuickResult? {
    guard let bcl = base.cl, let bcd = base.cd, let length = base.refLength, length > 0 else { return nil }
    // Forces over the dynamic pressure, per metre of width (m).
    var lift = bcl * length, drag = bcd * length
    var rear = (base.rearShare ?? 0) * lift
    var used: [WingPosition] = [], pending: [WingPosition] = []
    let xf = setup.axleX("F"), xr = setup.axleX("R")
    for p in [combo.front, combo.rear].compactMap({ $0 }) {
        guard let c = cards.first(where: { $0.id == p.card }) else { continue }
        var n = c.section
        if needsEstimate(c, height: p.height / 1000) {
            if let e = estimate(c, p.height / 1000) {
                n = e
                used.append(c.position)
            } else {
                pending.append(c.position)
            }
        }
        let xcp = setup.axleX(c.position == .front ? "F" : "R") + p.x - c.xcp * 1000
        let l = n.cl * c.wing.refChord
        lift += l
        drag += n.cd * c.wing.refChord
        rear += l * (xf - xcp) / (xf - xr)
    }
    return QuickResult(cl: lift / length, cd: drag / length, refLength: length, rearShare: abs(lift) > 1e-9 ? rear / lift : nil,
                       usedEstimate: used, pendingEstimate: pending)
}
