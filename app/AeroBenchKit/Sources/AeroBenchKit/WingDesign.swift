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
        /// RANS ran it, it converged, stayed attached and gave a value for the goal.
        public var held: Bool { rans?.value != nil }
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

    public static func decode(resultFile data: Data) throws -> WingDesignResult {
        struct Wrapper: Decodable { var data: WingDesignResult }
        return try JSONDecoder().decode(Wrapper.self, from: data).data
    }
}

extension CarRules {
    /// The card's box in the design frame (m): x from the box's front (0) back
    /// to its length, y up from the ground.
    public static func designBox(_ position: WingPosition, setup: CarSetup) -> RulesBox {
        let b = box(position, setup: setup)
        return RulesBox(minX: 0, minY: (b.minZ - setup.groundZ) / 1000,
                        maxX: (b.maxX - b.minX) / 1000, maxY: (b.maxZ - setup.groundZ) / 1000)
    }
}

extension Placement {
    /// Where a design sits on the car: its most upstream point `x` m behind the
    /// box's front, its lowest point at its ride height (the clearance without one).
    public static func fromDesign(card: WingCard, x: Double, setup: CarSetup) -> Placement {
        let b = CarRules.box(card.position, setup: setup)
        let axle = setup.axleX(card.position == .front ? "F" : "R")
        return Placement(card: card.id, x: b.maxX - x * 1000 - axle,
                         height: card.wing.rideHeight.map { $0 * 1000 } ?? CarRules.groundClearance)
    }
}
