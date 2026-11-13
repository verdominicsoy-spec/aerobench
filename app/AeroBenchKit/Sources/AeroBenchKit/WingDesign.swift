import Foundation

/// The engine's wing-design result: the starting wing (in the design frame:
/// m, x downstream from the box's front, y up from the ground), its study,
/// and the finalists, those that held in RANS first, best first.
public struct WingDesignResult: Decodable, Sendable {
    public struct Element: Decodable, Sendable {
        public var key: String?
        public var name: String?
        public var unit: [[Double]]
        public var chord: Double
        public var angle: Double
        public var leadingEdge: [Double]
        public var inverted: Bool
        enum CodingKeys: String, CodingKey { case key, name, unit, chord, angle, inverted, leadingEdge = "leading_edge" }
    }
    public struct Base: Decodable, Sendable {
        public var elements: [Element]
        public var rideHeight: Double?
        enum CodingKeys: String, CodingKey { case elements, rideHeight = "ride_height" }
    }
    public struct RansVerdict: Decodable, Sendable, Equatable {
        public var cl: Double?
        public var cd: Double?
        public var converged: Bool?
        public var separated: Bool?
        public var reason: String?
        public var value: Double?
        public var feasible: Bool?  // met the goal's drag limit or balance in RANS
    }
    public struct Finalist: Decodable, Sendable, Identifiable {
        public var number: Int
        public var params: [String: Double]
        public var estimateValue: Double?
        public var cla: Double?
        public var cda: Double?
        public var claCda: Double?
        public var carCla: Double?
        public var carCda: Double?
        public var rearShare: Double?
        public var from: String
        public var rideHeight: Double?
        public var x: Double
        public var rans: RansVerdict?
        public var id: Int { number }
        /// RANS ran it, it converged, stayed attached, gave a value for the goal and met its limit or target.
        public var held: Bool { rans?.value != nil && rans?.feasible != false }
        enum CodingKeys: String, CodingKey {
            case number, params, cla, cda, from, x, rans
            case estimateValue = "estimate_value", claCda = "cla_cda", carCla = "car_cla", carCda = "car_cda"
            case rearShare = "rear_share", rideHeight = "ride_height"
        }
    }
    public var goal: String
    public var box: [Double]
    public var base: Base
    public var study: WingStudy
    public var finalists: [Finalist]
    /// Span and endplate (m) when the study ran as on the car: its Cl and Cd are then already 3D.
    public var finite: [String: Double]?

    /// A finalist's Cl and Cd (on the study's reference chord `ref`) as section numbers for a card
    /// of `wing`: moved to the wing's own chord and, when the study ran as on the car, the 3D
    /// lift and induced drag undone so the card's carContribution does not apply them twice.
    public func cardNumbers(cl: Double, cd: Double, ref: Double, on wing: Wing) -> (cl: Double, cd: Double) {
        let cl = cl * ref / wing.refChord, cd = cd * ref / wing.refChord
        guard finite != nil else { return (cl, cd) }
        let area = wing.span * wing.refChord
        return wing.sectionCoefficients(cla: -cl * area, cda: cd * area)
    }

    public static func decode(resultFile data: Data) throws -> WingDesignResult {
        struct Wrapper: Decodable { var data: WingDesignResult }
        return try JSONDecoder().decode(Wrapper.self, from: data).data
    }
}

extension CarRules {
    /// The card's box in the design frame (m): x from the box's front (0) back
    /// to its length, y up from the ground.
    public static func designBox(_ position: WingPosition, setup: CarSetup, span: Double? = nil) -> RulesBox {
        let b = box(position, setup: setup, span: span)
        return RulesBox(minX: 0, minY: (b.minZ - setup.groundZ) / 1000,
                        maxX: (b.maxX - b.minX) / 1000, maxY: (b.maxZ - setup.groundZ) / 1000)
    }
}

extension Placement {
    /// Where a design sits on the car: its most upstream point `x` m behind the
    /// box's front, its lowest point at its ride height (the clearance without one).
    public static func fromDesign(card: WingCard, x: Double, setup: CarSetup) -> Placement {
        let b = CarRules.box(card.position, setup: setup, span: card.wing.span)
        let axle = setup.axleX(card.position == .front ? "F" : "R")
        return Placement(card: card.id, x: b.maxX - x * 1000 - axle,
                         height: card.wing.rideHeight.map { $0 * 1000 } ?? CarRules.groundClearance)
    }
}
