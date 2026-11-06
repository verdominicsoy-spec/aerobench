import AeroBenchKit
import Foundation
import Observation

/// The car cut at one y: outlines in (x, z) mm, as the engine's car-section returns them.
struct CarSection: Decodable, Sendable {
    struct Loop: Decodable, Sendable {
        var kind: String
        var wheel: String?
        var points: [[Double]]
    }

    var y: Double
    var loops: [Loop]
    var open: [[Double]]

    static func decode(_ data: Data) throws -> CarSection {
        struct Envelope: Decodable { var data: CarSection }
        return try JSONDecoder().decode(Envelope.self, from: data).data
    }
}

/// Wing Lab's car: the base car (its wheels, ground and rules boxes), the wing
/// cards and the combinations of base car, front card and rear card, for
/// placing wings. The car itself is not solved: one 2D section cannot say how
/// a wing does across the car, so the wings' numbers are Wing Lab's own.
@MainActor @Observable
final class CarModel {
    var setup: CarSetup?
    var cards: [WingCard] = []
    var combos: [Combination] = []
    var selected: String?
    var sectionY = 0.0
    var section: CarSection?
    var centreline: CarSection?
    var setupJob: JobItem?
    var status: String?
    var combosUnreadable = false  // combinations.json would not read: never written over
    var markingHeadRestraint = false
    @ObservationIgnored var engine: WarmEngine?
    @ObservationIgnored var sectionRunner: LatestOnly<JSONValue, CarSection>?

    var selectedCombo: Combination? { combos.first { $0.id == selected } }

    func card(_ id: String?) -> WingCard? { id.flatMap { id in cards.first { $0.id == id } } }

    var halfWidth: Double {
        setup?.wheels.map { abs($0.centre[1]) + $0.width / 2 }.max() ?? 750
    }

    func load(project: URL) {
        // Nothing of another project's car survives: what is not loaded here is made again.
        section = nil
        centreline = nil
        status = nil
        selected = nil
        setup = CarStore.setup(project)
        cards = CarStore.cards(project)
        if let saved = CarStore.combinations(project) {
            combos = saved
            combosUnreadable = false
            selected = saved.first?.id
        } else {
            combos = []
            combosUnreadable = true
            status = "combinations.json would not read: it was copied to combinations.unreadable.json and will not be overwritten"
        }
    }
}
