import AeroBenchKit
import Foundation
import Observation
import simd

/// Wing Lab state: the wing on the canvas, its undo history, the library and
/// the live inviscid preview.
@MainActor @Observable
final class WingLabModel {
    // The wing and its history
    var wing = Wing() {
        didSet {
            guard wing != oldValue else { return }
            onChange?()
            recompute()
        }
    }
    @ObservationIgnored var onChange: (() -> Void)?
    private(set) var undoStack: [Wing] = []
    private(set) var redoStack: [Wing] = []
    var selection: Int?
    var snap = true
    var lockAngle = false
    var lockChord = false

    // The library
    private(set) var library: [Airfoil] = []
    private(set) var libraryError: String?
    var filter = AirfoilLibrary.Filter()
    var favourites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "wingFavourites") ?? []) {
        didSet { UserDefaults.standard.set(Array(favourites), forKey: "wingFavourites") }
    }
    var libraryJob: JobItem?

    // The preview
    private(set) var preview: PanelSolution?
    private(set) var previewMilliseconds: Double = 0
    private(set) var previewError: String?

    var families: [String] { Array(Set(library.map(\.family))).sorted() }

    var shown: [Airfoil] { library.filter { filter.matches($0, favourites: favourites) } }

    // MARK: Editing with undo

    /// Records the current wing for undo, then applies a change.
    func edit(_ change: (inout Wing) -> Void) {
        var next = wing
        change(&next)
        guard next != wing else { return }
        undoStack.append(wing)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
        wing = next
    }

    /// For a drag: one undo step for the whole gesture.
    func beginGesture() {
        undoStack.append(wing)
        redoStack = []
    }

    /// Changes during a drag, without new undo steps.
    func live(_ change: (inout Wing) -> Void) {
        var next = wing
        change(&next)
        wing = next
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(wing)
        wing = last
        clampSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(wing)
        wing = next
        clampSelection()
    }

    private func clampSelection() {
        if let s = selection, s >= wing.elements.count { selection = wing.elements.isEmpty ? nil : wing.elements.count - 1 }
    }

    /// Replaces the wing without undo (opening a project).
    func reset(to wing: Wing) {
        undoStack = []
        redoStack = []
        self.wing = wing
        selection = wing.elements.isEmpty ? nil : 0
        recompute()
    }

    // MARK: Elements

    /// Adds a section as the next element, behind the last one (or as the
    /// main element at the origin).
    func add(_ airfoil: Airfoil, at point: SIMD2<Double>? = nil) {
        edit { w in
            let inverted = w.elements.first?.inverted ?? true
            if let last = w.elements.last {
                let chord = max(last.chord * 0.45, 0.02)
                let te = last.trailingEdge
                // Just behind and above (inverted: below) the previous trailing edge.
                let lift: Double = inverted ? 1 : -1
                let start = point ?? te + SIMD2(-0.05 * last.chord, lift * 0.03 * last.chord)
                w.elements.append(WingElement(airfoil: airfoil, chord: chord, angle: last.angle + 15, leadingEdge: start, inverted: inverted))
            } else {
                w.elements.append(WingElement(airfoil: airfoil, chord: 0.3, angle: 3, leadingEdge: point ?? .zero, inverted: inverted))
            }
        }
        selection = wing.elements.count - 1
    }

    /// Drops a section onto an element: same chord, angle and place, new shape.
    func swap(_ airfoil: Airfoil, into index: Int) {
        guard wing.elements.indices.contains(index) else { return }
        edit { $0.elements[index].airfoil = airfoil }
        selection = index
    }

    func remove(_ index: Int) {
        guard wing.elements.indices.contains(index) else { return }
        edit { $0.elements.remove(at: index) }
        clampSelection()
    }

    func element(at point: SIMD2<Double>) -> Int? {
        for (i, e) in wing.elements.enumerated().reversed() where Wing.inside(point, e.placed()) { return i }
        return nil
    }

    // MARK: Snapping

    func snapped(_ v: Double, step: Double) -> Double { snap ? (v / step).rounded() * step : v }

    // MARK: Library

    func loadLibrary(engineDirectory: URL?) {
        guard let dir = engineDirectory else {
            libraryError = "Set the engine folder in Settings first."
            return
        }
        let url = AirfoilLibrary.indexURL(engineDirectory: dir)
        do {
            library = try AirfoilLibrary.load(url)
            libraryError = nil
        } catch {
            library = []
            libraryError = error.localizedDescription
        }
    }

    /// A section by key from the library, or a NACA 4-digit made on the spot.
    func airfoil(_ key: String) -> Airfoil? {
        library.first { $0.key == key } ?? (key.hasPrefix("naca/") ? Airfoil.naca4(String(key.dropFirst(5))) : nil)
    }

    // MARK: Preview

    private func recompute() {
        guard !wing.elements.isEmpty else {
            preview = nil
            previewError = nil
            return
        }
        let start = Date()
        if let solver = PanelSolver(elements: wing.elements.map { $0.placed() }, refChord: wing.refChord) {
            preview = solver.solve(alphaDeg: wing.alpha)
            previewError = nil
        } else {
            preview = nil
            previewError = "Elements overlap, so there is no preview."
        }
        previewMilliseconds = Date().timeIntervalSince(start) * 1000
    }

    // MARK: Saving

    static func load(fromProject project: URL) -> Wing? {
        let url = ProjectStore.toolURL(for: project, tool: "wing").appendingPathComponent("wing.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Wing.self, from: data)
    }

    func save(toProject project: URL) throws {
        let folder = ProjectStore.toolURL(for: project, tool: "wing")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(wing).write(to: folder.appendingPathComponent("wing.json"), options: .atomic)
    }

    /// A starting point: an inverted two-element NACA wing, so the canvas is
    /// never empty on the first visit.
    static var starter: Wing {
        let s = Airfoil.naca4("4412")!
        var w = Wing(elements: [
            WingElement(airfoil: s, chord: 0.30, angle: 3, leadingEdge: .zero, inverted: true),
            WingElement(airfoil: s, chord: 0.14, angle: 25, leadingEdge: SIMD2(0.27, 0.025), inverted: true),
        ], span: 1.0)
        w.setGap(0.012, of: 1)
        return w
    }
}
