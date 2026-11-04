import AeroBenchKit
import Foundation

/// The car's files in the project's car/ folder: the base car's setup,
/// its strip results per mesh setting, the wing cards and the combinations.
enum CarStore {
    static func folder(_ project: URL) -> URL { ProjectStore.toolURL(for: project, tool: "car") }
    static func cardsFolder(_ project: URL) -> URL { folder(project).appendingPathComponent("cards") }

    private static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AeroJSON.encoder().encode(value).write(to: url, options: .atomic)
    }

    static func setup(_ project: URL) -> CarSetup? { read(CarSetup.self, folder(project).appendingPathComponent("setup.json")) }
    static func save(_ setup: CarSetup, _ project: URL) throws { try write(setup, folder(project).appendingPathComponent("setup.json")) }

    static func base(_ project: URL, mesh: String) -> CarResult? {
        read(CarResult.self, folder(project).appendingPathComponent("base_\(mesh).json"))
    }

    static func save(base: CarResult, _ project: URL) throws {
        try write(base, folder(project).appendingPathComponent("base_\(base.mesh).json"))
    }

    static func cards(_ project: URL) -> [WingCard] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: cardsFolder(project), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { read(WingCard.self, $0) }.sorted { $0.name < $1.name }
    }

    static func save(_ card: WingCard, _ project: URL) throws {
        try write(card, cardsFolder(project).appendingPathComponent("\(card.id).json"))
    }

    /// The saved combinations; nil when the file is there but unreadable (it is
    /// copied aside and must not be written over with an empty list).
    static func combinations(_ project: URL) -> [Combination]? {
        let url = folder(project).appendingPathComponent("combinations.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        if let combos = read([Combination].self, url) { return combos }
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.copyItem(at: url, to: aside)
        return nil
    }

    /// The car's own settings and the bare car's revision, kept between launches.
    struct State: Codable {
        var baseRevision = 0
        var mesh = "medium"
        var strips = 7
        var groundMoving = true  // as CarModel: the moving ground is verified since bfca043
        var groundSpeed = 15.0
        var wheelsRotating = true
        var wheelsSpeed = 15.0
    }

    static func state(_ project: URL) -> State { read(State.self, folder(project).appendingPathComponent("state.json")) ?? State() }
    static func save(_ state: State, _ project: URL) throws { try write(state, folder(project).appendingPathComponent("state.json")) }

    static func save(_ combos: [Combination], _ project: URL) throws {
        try write(combos, folder(project).appendingPathComponent("combinations.json"))
    }
}
