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

/// The Car tool: the base car, its 2D strip results, the wing cards and the
/// combinations of base car, front card and rear card.
@MainActor @Observable
final class CarModel {
    var setup: CarSetup?
    var baseRevision = 0  // bumped when the base car or its results change: combinations go out of date
    var bases: [String: CarResult] = [:]  // bare-car results per mesh setting
    var cards: [WingCard] = []
    var combos: [Combination] = []
    var selected: String?
    var mesh = "medium"
    var strips = 7
    var groundMoving = true
    var groundSpeed = 15.0
    var wheelsRotating = true
    var wheelsSpeed = 15.0
    var sectionY = 0.0
    var section: CarSection?
    var centreline: CarSection?
    var setupJob: JobItem?
    var baseJob: JobItem?
    var fullJob: JobItem?
    var status: String?
    var combosUnreadable = false  // combinations.json would not read: never written over
    var markingHeadRestraint = false
    /// Where the wing being edited sits (mm ahead of its axle) while its end of the combination is empty.
    var draftX: Double?
    /// Quick estimates of cards placed off their own height, by "card@height mm".
    var estimates: [String: (cla: Double, cda: Double)] = [:]
    @ObservationIgnored var engine: WarmEngine?
    @ObservationIgnored var sectionRunner: LatestOnly<JSONValue, CarSection>?

    static let meshes = ["coarse", "medium", "maxed"]

    var selectedCombo: Combination? { combos.first { $0.id == selected } }

    /// The bare car at the current settings: same mesh, strips, speed and ground and wheel options.
    var base: CarResult? {
        guard let b = bases[mesh] else { return nil }
        return b.ranWith(flow, n: strips) ? b : nil
    }

    /// A bare-car result exists at this mesh but with other settings.
    var baseMismatch: Bool { bases[mesh] != nil && base == nil }

    var state: CarStore.State {
        get { CarStore.State(baseRevision: baseRevision, mesh: mesh, strips: strips, groundMoving: groundMoving, groundSpeed: groundSpeed,
                             wheelsRotating: wheelsRotating, wheelsSpeed: wheelsSpeed) }
        set { baseRevision = newValue.baseRevision; mesh = newValue.mesh; strips = newValue.strips; groundMoving = newValue.groundMoving
              groundSpeed = newValue.groundSpeed; wheelsRotating = newValue.wheelsRotating; wheelsSpeed = newValue.wheelsSpeed }
    }

    func card(_ id: String?) -> WingCard? { id.flatMap { id in cards.first { $0.id == id } } }

    var halfWidth: Double {
        setup?.wheels.map { abs($0.centre[1]) + $0.width / 2 }.max() ?? 750
    }

    var flow: JSONValue {
        .object(["speed": .double(setup?.speed ?? 15),
                 "ground": .object(["moving": .bool(groundMoving), "speed": .double(groundSpeed)]),
                 "wheels": .object(["rotating": .bool(wheelsRotating), "speed": .double(wheelsSpeed)])])
    }

    func load(project: URL) {
        setup = CarStore.setup(project)
        bases = Dictionary(uniqueKeysWithValues: Self.meshes.compactMap { m in CarStore.base(project, mesh: m).map { (m, $0) } })
        cards = CarStore.cards(project)
        state = CarStore.state(project)
        if let saved = CarStore.combinations(project) {
            combos = saved
            combosUnreadable = false
        } else {
            combos = []
            combosUnreadable = true
            status = "combinations.json would not read: it was copied to combinations.unreadable.json and will not be overwritten"
        }
    }

    /// The placed wings as the engine's car-strips takes them (car mm).
    func placedWings(_ combo: Combination) -> [JSONValue] {
        guard let setup else { return [] }
        return [combo.front, combo.rear].compactMap { p -> JSONValue? in
            guard let p, let c = card(p.card) else { return nil }
            let els = p.placedElements(card: c, setup: setup).map { el in JSONValue.array(el.map { .array([.double($0.x), .double($0.y)]) }) }
            var o: [String: JSONValue] = ["position": .string(c.position.rawValue), "elements": .array(els),
                                          "span": .double(c.wing.span), "factor3d": .double(c.wing.factor3D),
                                          "chord": .double(c.wing.refChord)]
            if let h = c.wing.endplateHeight { o["endplate"] = .double(h) }
            return .object(o)
        }
    }
}
