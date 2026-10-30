import AeroBenchKit
import CoreGraphics
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

    // Solvers
    enum Solver: String, CaseIterable, Identifiable {
        case preview = "Inviscid preview"
        case quickViscous = "Quick viscous"
        case quickEstimate = "Quick estimate"
        case rans = "RANS CFD"

        var id: String { rawValue }

        var purpose: String {
            switch self {
            case .preview: "Live while you drag, every element together. No viscosity: lift trends and how the load splits, no drag."
            case .quickViscous: "NeuralFoil (trained on XFOIL): one element in isolation, a whole polar in seconds, with drag and where the boundary layer turns turbulent. Picks sections; knows nothing of slot effects."
            case .quickEstimate: "Every element together, on the quick RANS mesh: about 1½ minutes for one angle, to three figures. Sweep the wing angle for Cl and Cd against angle, inside 5 minutes."
            case .rans: "SU2 on a mesh around every element: slot flow, separation, the real gap effects. Minutes per run."
            }
        }
    }
    var solver: Solver = .preview
    enum ResultsTab: String, CaseIterable, Identifiable {
        case pressure = "Pressure"
        case polar = "Polar"
        case cfd = "CFD"
        case study = "Study"

        var id: String { rawValue }
    }
    var resultsTab: ResultsTab = .pressure
    var polar: WingPolar?
    var polarElement: Int?
    var polarJob: JobItem?
    var alphaStart = -4.0
    var alphaEnd = 16.0
    var alphaStep = 1.0
    /// Amplification for free transition: 9 is a clean wind tunnel, lower
    /// is a dirtier, more turbulent stream (behind a car, say).
    var nCrit = 9.0
    var cdEstimate = 0.05
    var replacedCla = 0.0
    var replacedCda = 0.0

    // RANS
    enum TurbulenceModel: String, CaseIterable, Identifiable {
        case sa, sst
        case sstLM = "sst-lm"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .sa: "Spalart–Allmaras"
            case .sst: "SST"
            case .sstLM: "SST + transition"
            }
        }
        var purpose: String {
            switch self {
            case .sa: "Fully turbulent, robust, the usual first choice for attached flow and modest flap angles."
            case .sst: "Fully turbulent, better at the edge of separation: big flap angles, near stall."
            case .sstLM: "Langtry–Menter transition: laminar runs, laminar separation bubbles and where they close. The one for FS Reynolds numbers when the details matter; slower and touchier."
            }
        }
    }
    var turbulenceModel: TurbulenceModel = .sa
    var meshLevel = "medium"
    var predictTransition = true
    var turbulenceIntensity = 1.0  // percent
    var ransJob: JobItem?
    var ransResult: WingRansResult?
    var ransFolder: URL?
    var su2Job: JobItem?

    // Quick estimate: one angle, or a sweep of the wing angle within a time limit
    var sweepOn = false
    var sweepFrom = -4.0
    var sweepTo = 4.0
    var sweepStep = 2.0
    var sweep: WingSweep?
    var sweepFolder: URL?
    var sweepJob: JobItem?
    var sweepRow: Int?

    var sweepAngles: [Double] { WingSweep.angles(from: sweepFrom, to: sweepTo, step: sweepStep) }

    /// Shows one angle of the sweep in the CFD tab: its numbers, surface Cp and flow field.
    func showSweepRow(_ i: Int) {
        guard let s = sweep, s.rows.indices.contains(i), let base = sweepFolder else { return }
        let row = s.rows[i]
        let folder = row.folder.map { base.appendingPathComponent($0) } ?? base
        sweepRow = i
        ransResult = row
        ransFolder = folder
        ransField = row.fieldView == nil ? nil : try? WingField.load(from: folder)
    }

    // The flow field of the last RANS run
    enum CFDView: String, CaseIterable, Identifiable {
        case field = "Flow field"
        case surface = "Surface Cp"

        var id: String { rawValue }
    }
    var cfdView: CFDView = .field
    var ransField: WingField? {
        didSet { fieldImages = [:] }
    }
    var fieldScalar = "cp"
    var showStreamlines = true
    @ObservationIgnored private var fieldImages: [String: CGImage] = [:]

    /// The scalar as an image, made once per scalar and kept.
    func fieldImage(_ key: String) -> CGImage? {
        if let image = fieldImages[key] { return image }
        guard let f = ransField else { return nil }
        let px = f.pixels(key)
        guard px.count == f.nx * f.ny * 4,
              let provider = CGDataProvider(data: Data(px) as CFData),
              let image = CGImage(width: f.nx, height: f.ny, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.nx * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        fieldImages[key] = image
        return image
    }

    // Optimisation
    struct DesignVariable: Codable, Equatable, Identifiable {
        enum Kind: String, Codable, CaseIterable { case angle, gap, overlap }
        var element: Int
        var kind: Kind
        var low: Double  // degrees, or mm for gap and overlap
        var high: Double

        var id: String { "\(kind.rawValue)_\(element)" }
        var unit: String { kind == .angle ? "°" : "mm" }
        /// In the engine's units: degrees, or metres.
        var engineScale: Double { kind == .angle ? 1 : 0.001 }
    }

    enum Objective: String, Codable, CaseIterable, Identifiable {
        case maxCl = "max_cl"
        case maxLD = "max_ld"
        case maxClCdCap = "max_cl_cd_cap"
        case minCdClTarget = "min_cd_cl_target"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .maxCl: "Most downforce"
            case .maxLD: "Best L/D"
            case .maxClCdCap: "Most downforce, Cd capped"
            case .minCdClTarget: "Least drag for a downforce"
            }
        }
    }

    struct OptimiseSetup: Codable, Equatable {
        var variables: [DesignVariable] = []
        var objective: Objective = .maxCl
        var cdCap = 0.1
        var clTarget = 2.0  // downforce Cl (lift when upright)
        var sampler = "tpe"
        var trials = 40
        var studyName = "study-1"
    }

    var optimise = OptimiseSetup() {
        didSet { if optimise != oldValue { onChange?() } }
    }
    var study: WingStudy?
    var optimiseJob: JobItem?
    var selectedTrial: Int?

    func variable(_ kind: DesignVariable.Kind, of element: Int) -> DesignVariable? {
        optimise.variables.first { $0.kind == kind && $0.element == element }
    }

    /// Ticks or unticks a design variable; new ones get bounds around the
    /// current value.
    func toggleVariable(_ kind: DesignVariable.Kind, of element: Int) {
        if let i = optimise.variables.firstIndex(where: { $0.kind == kind && $0.element == element }) {
            optimise.variables.remove(at: i)
            return
        }
        let v: DesignVariable
        switch kind {
        case .angle:
            let a = wing.elements[element].angle
            v = DesignVariable(element: element, kind: .angle, low: (a - 5).rounded(), high: (a + 5).rounded())
        case .gap:
            let g = (wing.gap(of: element) ?? 0.01) * 1000
            v = DesignVariable(element: element, kind: .gap, low: max(wing.minGap * 1000, (g * 0.5).rounded()),
                               high: max((g * 1.5).rounded(), wing.minGap * 1000 + 5))
        case .overlap:
            let o = (wing.overlap(of: element) ?? 0) * 1000
            v = DesignVariable(element: element, kind: .overlap, low: (o - 10).rounded(), high: (o + 10).rounded())
        }
        optimise.variables.append(v)
        optimise.variables.sort { ($0.element, $0.kind.rawValue) < ($1.element, $1.kind.rawValue) }
    }

    func setBounds(of id: String, low: Double? = nil, high: Double? = nil) {
        guard let i = optimise.variables.firstIndex(where: { $0.id == id }) else { return }
        if let low { optimise.variables[i].low = low }
        if let high { optimise.variables[i].high = high }
    }

    /// Why the study cannot start, or nil.
    var optimiseProblem: String? {
        let vars = optimise.variables
        if vars.isEmpty { return "Tick at least one design variable." }
        if let v = vars.first(where: { $0.element >= wing.elements.count || ($0.kind != .angle && $0.element == 0) }) {
            return "\(v.id) refers to an element that is not there any more."
        }
        if let v = vars.first(where: { !($0.high > $0.low) }) { return "\(v.id): the upper bound must be above the lower." }
        if let v = vars.first(where: { $0.kind == .gap && $0.low < 0 }) { return "\(v.id): a gap cannot be negative." }
        if optimise.objective == .maxClCdCap && !(optimise.cdCap > 0) { return "Set a Cd cap above zero." }
        if optimise.objective == .minCdClTarget && !(optimise.clTarget > 0) { return "Set a downforce target above zero." }
        if optimise.studyName.trimmingCharacters(in: .whitespaces).isEmpty { return "Name the study." }
        return nil
    }

    /// Puts a trial's wing on the canvas (undoable).
    func load(trial: WingStudy.Trial) {
        guard let w = wing.applying(trial) else { return }
        edit { $0 = w }
        selectedTrial = trial.number
    }

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
        try encoder.encode(optimise).write(to: folder.appendingPathComponent("optimise.json"), options: .atomic)
    }

    static func loadOptimise(fromProject project: URL) -> OptimiseSetup? {
        let url = ProjectStore.toolURL(for: project, tool: "wing").appendingPathComponent("optimise.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OptimiseSetup.self, from: data)
    }

    /// Studies live in the project: <project>/wing/studies/<name>.db (Optuna)
    /// and <name>.json (the engine's export after every trial).
    static func studyFile(project: URL, name: String) -> URL {
        let safe = name.trimmingCharacters(in: .whitespaces).map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return ProjectStore.toolURL(for: project, tool: "wing").appendingPathComponent("studies")
            .appendingPathComponent(String(safe)).appendingPathExtension("db")
    }

    /// Reads the study's export, if there is one.
    func reloadStudy(project: URL?) {
        guard let project else {
            study = nil
            return
        }
        let url = Self.studyFile(project: project, name: optimise.studyName).deletingPathExtension().appendingPathExtension("json")
        study = (try? Data(contentsOf: url)).flatMap { try? WingStudy.decode(exportFile: $0) }
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
