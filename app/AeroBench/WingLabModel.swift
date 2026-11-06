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
    /// What one undo step brings back: the wing, the card it is saved as, and where it sits on the car.
    struct Step: Equatable {
        var wing: Wing
        var cardID: String?
        var carX: Double?
        var carHeight: Double? = nil
    }
    private(set) var undoStack: [Step] = []
    private(set) var redoStack: [Step] = []
    /// Where the wing sits on the car (mm ahead of its axle) once moved there; nil, its end's place.
    var carX: Double?
    /// Its height on the car (mm, lowest point above ground) once moved there with the ground off
    var carHeight: Double?
    private var step: Step {
        get { Step(wing: wing, cardID: cardID, carX: carX, carHeight: carHeight) }
        set { wing = newValue.wing; cardID = newValue.cardID; carX = newValue.carX; carHeight = newValue.carHeight }
    }
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
        case live = "Live estimate"
        case quickViscous = "Quick viscous"
        case rans = "RANS CFD"

        var id: String { rawValue }

        /// How close it gets, in a word: from the UIUC Vol 1 check (docs/validation) and RANS.
        var accuracy: String {
            switch self {
            case .quickViscous: "Rough"  // one element alone, no slot effects
            case .live: "Fair"           // NeuralFoil per element, calibrated against RANS
            case .rans: "Good"           // Cd within 1-9% of the tunnel, Cl a little high
            }
        }

        /// Where this solver's results show.
        var resultsTab: ResultsTab {
            switch self {
            case .live: .estimate
            case .quickViscous: .polar
            case .rans: .cfd
            }
        }

        var purpose: String {
            switch self {
            case .quickViscous: "NeuralFoil (trained on XFOIL): one element in isolation, a whole polar in seconds, with drag and where the boundary layer turns turbulent. Picks sections; knows nothing of slot effects."
            case .live: "Every element together, live as you edit: the panel method at once (how the elements load each other, Cp, Cm), then NeuralFoil's viscous lift and drag for each element a moment later, over a range of wing angles. Lift within about 2% of RANS on a main-and-flap wing until the flap nears separation; drag about 10% high. Not for slats."
            case .rans: "SU2 on a mesh around every element: slot flow, separation, the real gap effects. Minutes per run."
            }
        }
    }
    var solver: Solver = .live {
        didSet { if solver != oldValue { resultsTab = solver.resultsTab } }
    }
    enum ResultsTab: String, CaseIterable, Identifiable {
        case pressure = "Pressure"
        case polar = "Polar"
        case estimate = "Estimate"
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
    /// The car card this wing was last saved as: Save as Card updates it.
    var cardID: String?
    var replacedCda = 0.0

    // RANS
    enum TurbulenceModel: String, CaseIterable, Identifiable {
        case sst, sa
        case sstLM = "sst-lm"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .sa: "Spalart–Allmaras"
            case .sst: "SST"
            case .sstLM: "SST + transition"
            }
        }
        /// How close it gets, in a word (UIUC Vol 1 check, 2026-11-05).
        var accuracy: String {
            switch self {
            case .sa: "Fair"
            case .sst: "Good"
            case .sstLM: "Best"  // closest drag, when it converges
            }
        }
        var purpose: String {
            switch self {
            case .sa: "Fully turbulent, the lightest model; fine for attached flow and modest flap angles."
            case .sst: "Fully turbulent, the default: converges reliably and holds up near stall. Drag reads a little high at FS Reynolds numbers."
            case .sstLM: "Langtry–Menter transition: laminar runs, laminar separation bubbles and where they close. Closer drag against a clean wind tunnel, but slower and often won't settle at low angles or near stall."
            }
        }
    }
    var turbulenceModel: TurbulenceModel = .sst
    var meshLevel = "medium"
    var predictTransition = true
    var turbulenceIntensity = 1.0  // percent
    var ransJob: JobItem?
    var ransResult: WingRansResult?
    /// The CFD tab's polar from earlier RANS runs, kept until the wing, its model or the runs change.
    @ObservationIgnored var ransPolarCache: (key: String, wing: [WingElement], points: [PolarCharts.Point])?
    @ObservationIgnored var meshAdviceCache: (key: String, advice: MeshAdvice)?
    var ransFolder: URL?

    // The RANS mesh to look at (wing-mesh), and the wing it was made for
    var meshJob: JobItem?
    var mesh: SU2Mesh?
    var meshPath: CGPath?
    var meshOf: Wing?
    var meshInfo: String?

    /// The wing's anchor when its car box was last placed, to tell a canvas move from a placement change
    @ObservationIgnored var rulesAnchor: SIMD2<Double>?
    var su2Job: JobItem?

    // Live estimate: panel method and NeuralFoil, through the warm engine
    var estimateFrom = -4.0
    var estimateTo = 10.0
    var estimateStep = 1.0
    var estimate: WingEstimate?
    /// Re-run the estimate through the warm engine on every change to the wing: always on.
    let liveEstimate = true
    var liveStatus: String?  // loading, or why the last live estimate failed
    @ObservationIgnored var warmEngine: WarmEngine?
    @ObservationIgnored var liveBusy = false
    @ObservationIgnored var liveDirty = false
    var estimateAngles: [Double] { WingSweep.angles(from: estimateFrom, to: estimateTo, step: estimateStep, limit: 61) }

    // RANS sweep of the wing angle: on the quick mesh within 5 minutes, or
    // through stall (each angle from the one below, the chosen mesh, no limit)
    var sweepOn = false
    var sweepRising = false
    var sweepFrom = -2.0  // three angles fit in 5 minutes on 4 cores for a two-element wing
    var sweepTo = 2.0
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

    // The flow field of the last RANS run, drawn on the canvas
    var ransField: WingField? {
        didSet { fieldImages = [:]; changeImages = [:] }
    }
    var fieldScalar = "cp"
    var showStreamlines = true
    /// The last RANS run's field on the canvas, behind the wing.
    var fieldOnCanvas = true
    /// Whether the last RANS run's field is of the wing as it is now (each
    /// element within a millimetre): once the wing is edited it is not shown.
    var fieldIsCurrent: Bool {
        guard let r = ransResult, ransField != nil else { return false }
        return r.matches(wing.elements.map { $0.placed() })
    }
    @ObservationIgnored private var fieldImages: [String: CGImage] = [:]

    /// The scalar as an image, made once per scalar and kept.
    func fieldImage(_ key: String) -> CGImage? {
        if let image = fieldImages[key] { return image }
        guard let f = ransField else { return nil }
        let px = f.pixels(key)
        guard px.count == f.nx * f.ny * 4, let image = Self.image(px, f.nx, f.ny) else { return nil }
        fieldImages[key] = image
        return image
    }

    static func image(_ px: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // Optimisation
    struct DesignVariable: Codable, Equatable, Identifiable {
        enum Kind: String, Codable, CaseIterable {
            case airfoil, chord, angle, gap, overlap, camber, thickness, height
            /// The grid's columns, in order: what the element is, how big, where, its shape.
            static let grid: [Kind] = [.airfoil, .chord, .angle, .gap, .overlap, .camber, .thickness]

            var title: String {
                switch self {
                case .airfoil: "Section"
                case .chord: "Chord"
                case .angle: "Angle"
                case .gap: "Gap"
                case .overlap: "Overlap"
                case .camber: "Camber"
                case .thickness: "Thickness"
                case .height: "Ride height"
                }
            }
            /// Gap and overlap belong to an element with one in front.
            func applies(to element: Int) -> Bool { !((self == .gap || self == .overlap) && element == 0) }
        }
        var element: Int
        var kind: Kind
        var low: Double  // degrees, mm for gap, overlap and chord, % for camber added and thickness
        var high: Double
        /// A section variable: the library keys to choose between, the element's own first.
        var choices: [String]? = nil

        var id: String { "\(kind.rawValue)_\(element)" }
        var unit: String {
            switch kind {
            case .angle: "°"
            case .gap, .overlap, .height, .chord: "mm"
            case .camber: "% chord"
            case .thickness: "% as drawn"
            case .airfoil: ""
            }
        }
        /// In the engine's units: degrees, metres, or fractions.
        var engineScale: Double {
            switch kind {
            case .angle, .airfoil: 1
            case .gap, .overlap, .height, .chord: 0.001
            case .camber, .thickness: 0.01
            }
        }
    }

    enum Objective: String, Codable, CaseIterable, Identifiable {
        case maxCl = "max_cl"
        case maxLD = "max_ld"
        case maxClCdCap = "max_cl_cd_cap"
        case minCdClTarget = "min_cd_cl_target"
        case minLapTime = "min_lap_time"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .maxCl: "Most downforce"
            case .maxLD: "Best L/D"
            case .maxClCdCap: "Most downforce, Cd capped"
            case .minCdClTarget: "Least drag for a downforce"
            case .minLapTime: "Fastest lap"
            }
        }
    }

    struct OptimiseSetup: Codable, Equatable {
        var variables: [DesignVariable] = []
        var objective: Objective = .maxCl
        var cdCap = 0.1
        var clTarget = 2.0  // downforce Cl (lift when upright)
        var sampler = "tpe"
        var trials = 200
        var studyName = "study-1"
        /// Each trial a quick estimate (seconds) or a RANS run (minutes).
        var solver = "estimate"
        /// After a quick-estimate study, run this many of the best designs with RANS (0: none).
        var checkBest = 0
        /// Stop the RANS checks at the first design RANS confirms (the rest are fallbacks).
        var untilPass = true
        /// When the study ends, put its best on the canvas (RANS's pick if it checked any).
        var loadBest = false

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = OptimiseSetup()
            variables = try c.decodeIfPresent([DesignVariable].self, forKey: .variables) ?? d.variables
            objective = try c.decodeIfPresent(Objective.self, forKey: .objective) ?? d.objective
            cdCap = try c.decodeIfPresent(Double.self, forKey: .cdCap) ?? d.cdCap
            clTarget = try c.decodeIfPresent(Double.self, forKey: .clTarget) ?? d.clTarget
            sampler = try c.decodeIfPresent(String.self, forKey: .sampler) ?? d.sampler
            trials = try c.decodeIfPresent(Int.self, forKey: .trials) ?? d.trials
            studyName = try c.decodeIfPresent(String.self, forKey: .studyName) ?? d.studyName
            // Set-ups saved before the choice ran RANS.
            solver = try c.decodeIfPresent(String.self, forKey: .solver) ?? "rans"
            checkBest = try c.decodeIfPresent(Int.self, forKey: .checkBest) ?? d.checkBest
            untilPass = try c.decodeIfPresent(Bool.self, forKey: .untilPass) ?? d.untilPass
            loadBest = try c.decodeIfPresent(Bool.self, forKey: .loadBest) ?? d.loadBest
        }

        /// Trials worth running for this many variables: the estimate study
        /// levels off by about 25 a variable (it was within 0.01% of its best by
        /// 50 with four), RANS ones cost minutes each.
        var suggestedTrials: Int {
            let n = max(variables.count, 1)
            return solver == "estimate" ? min(max(25 * n, 100), 600) : min(max(6 * n, 20), 80)
        }

        /// Whether this set-up needs SU2 to run.
        var needsSU2: Bool { solver == "rans" || checkBest > 0 }
    }

    var optimise = OptimiseSetup() {
        didSet { if optimise != oldValue { onChange?() } }
    }
    var study: WingStudy?
    var optimiseJob: JobItem?

    // Where a study starts: the wing on the canvas, or one the engine lays out
    // from the library (sections ranked by maximum lift, a standard arrangement).
    enum StartFrom: String, Codable, CaseIterable, Identifiable {
        case existing = "Existing"
        case scratch = "From scratch"
        var id: String { rawValue }
    }
    /// The Design card's goals, by the engine's keys.
    enum DesignGoal: String, Codable, CaseIterable, Identifiable {
        case maxCla = "max_cla", maxEfficiency = "max_efficiency", minLapTime = "min_lap_time"
        case maxClaCdaCap = "max_cla_cda_cap", balance = "balance"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .maxCla: "Most downforce"
            case .maxEfficiency: "Best efficiency"
            case .minLapTime: "Fastest lap"
            case .maxClaCdaCap: "Downforce under a drag limit"
            case .balance: "Hit a balance"
            }
        }
    }
    struct DesignSetup: Codable, Equatable {
        var startFrom: StartFrom = .scratch
        var elements = 2
        var minThickness = 8.0  // % of chord, the thinnest section allowed
        var goal = DesignGoal.maxCla
        var checks = 3  // RANS on the best this many
        var cdaCap = 1.5  // m², the drag limit (the car's with a base car, else the wing's)
        var rearTarget = 55.0  // %, the balance goal's rear share
    }
    var design = DesignSetup()
    var designRun: JobItem?  // the Design card's wing-design job
    var designResult: WingDesignResult?
    var designShown: Int?  // the finalist on the canvas
    var designName: String?  // the study a Design run resumes while its settings stay the same
    var designKey: String?
    var designStage: String?  // what setting up or a running study is doing, shown over the canvas
    var designJob: JobItem?
    /// Each element's sections to choose between, from the engine (the element's own first).
    var shortlists: [Int: [String]] = [:]
    var shortlistJob: JobItem?
    var selectedTrial: Int?

    // Panels (kept per Mac)
    enum LibraryTab: String, CaseIterable, Identifiable {
        case airfoils = "Airfoils", cards = "Cards"
        var id: String { rawValue }
    }
    var libraryTab = LibraryTab.airfoils

    enum CanvasMode: String, CaseIterable, Identifiable {
        case wing = "Wing", car = "Car", mesh = "Mesh"
        var id: String { rawValue }
    }
    var canvasMode = CanvasMode(rawValue: UserDefaults.standard.string(forKey: "wingCanvasMode") ?? "") ?? .wing {
        didSet { UserDefaults.standard.set(canvasMode.rawValue, forKey: "wingCanvasMode") }
    }
    var showLibrary = UserDefaults.standard.object(forKey: "wingShowLibrary") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showLibrary, forKey: "wingShowLibrary") }
    }
    var showInspector = UserDefaults.standard.object(forKey: "wingShowInspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "wingShowInspector") }
    }

    // Time-lapse of a study: its trials in the order they ran, on the canvas.
    var replayIndex: Int?
    var replayPlaying = false
    var replaySpeed = 8.0  // trials a second
    @ObservationIgnored private var replayTask: Task<Void, Never>?

    /// Trials that ran (or tried to), in order, with the wing each one had.
    var replayOrder: [WingStudy.Trial] {
        (study?.trials ?? []).filter { ($0.state == "complete" || $0.state == "fail") && $0.placement != nil }
    }
    var replayTrial: WingStudy.Trial? {
        guard let i = replayIndex else { return nil }
        let order = replayOrder
        return order.indices.contains(i) ? order[i] : nil
    }
    /// The canvas wing during a time-lapse.
    var replayWing: Wing? { replayTrial.flatMap { wing.applying($0, sections: studySections, library: { self.airfoil($0) }) } }

    /// The best value among the trials up to the one on show.
    var replayBestSoFar: Double? {
        guard let s = study, let t = replayTrial else { return nil }
        let upTo = s.bestSoFar.filter { $0.trial <= t.number }
        return upTo.last?.value
    }

    func playReplay() {
        if replayIndex == nil || replayIndex == replayOrder.count - 1 { replayIndex = 0 }
        replayPlaying = true
        resultsTab = .study
        replayTask?.cancel()
        replayTask = Task { @MainActor [weak self] in
            while let self, self.replayPlaying, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1 / max(self.replaySpeed, 0.5)))
                guard self.replayPlaying, let i = self.replayIndex else { return }
                if i + 1 >= self.replayOrder.count {
                    self.replayPlaying = false
                    return
                }
                self.replayIndex = i + 1
            }
        }
    }

    func pauseReplay() {
        replayPlaying = false
        replayTask?.cancel()
    }

    func stopReplay() {
        pauseReplay()
        replayIndex = nil
    }

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
        var v: DesignVariable
        switch kind {
        case .airfoil:
            let own = wing.elements[element].airfoil.key
            let keys = shortlists[element].map { [own] + $0.filter { $0 != own } } ?? [own]
            v = DesignVariable(element: element, kind: .airfoil, low: 0, high: Double(max(keys.count - 1, 0)))
            v.choices = keys
        case .chord:
            let c = wing.elements[element].chord * 1000
            v = DesignVariable(element: element, kind: .chord, low: (c * 0.75).rounded(), high: (c * 1.25).rounded())
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
        case .camber:
            v = DesignVariable(element: element, kind: .camber, low: 0, high: 3)
        case .thickness:
            v = DesignVariable(element: element, kind: .thickness, low: 80, high: 120)
        case .height:
            let h = (wing.rideHeight ?? 0.05) * 1000
            v = DesignVariable(element: 0, kind: .height, low: max((h * 0.5).rounded(), 30), high: (h * 2).rounded())
        }
        optimise.variables.append(v)
        optimise.variables.sort { ($0.element, $0.kind.rawValue) < ($1.element, $1.kind.rawValue) }
    }

    /// A preset of variables for every element: replaces what is ticked.
    enum Preset: String, CaseIterable, Identifiable {
        case placement = "Angles, gaps and overlaps"
        case sizes = "Plus chords"
        case everything = "Plus sections"
        var id: String { rawValue }
        var kinds: [DesignVariable.Kind] {
            switch self {
            case .placement: [.angle, .gap, .overlap]
            case .sizes: [.chord, .angle, .gap, .overlap]
            case .everything: [.airfoil, .chord, .angle, .gap, .overlap]
            }
        }
    }

    func apply(_ preset: Preset) {
        let keepHeight = optimise.variables.first { $0.kind == .height }
        optimise.variables = []
        for i in wing.elements.indices {
            for kind in preset.kinds where kind.applies(to: i) { toggleVariable(kind, of: i) }
        }
        if let keepHeight { optimise.variables.append(keepHeight) }
    }

    /// New shortlists from the engine: section variables already ticked take them.
    func setShortlists(_ lists: [Int: [String]]) {
        shortlists = lists
        for (k, v) in optimise.variables.enumerated() where v.kind == .airfoil {
            let own = wing.elements.indices.contains(v.element) ? wing.elements[v.element].airfoil.key : v.choices?.first ?? ""
            let keys = [own] + (lists[v.element] ?? []).filter { $0 != own }
            optimise.variables[k].choices = keys
            optimise.variables[k].high = Double(max(keys.count - 1, 0))
        }
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
        if let v = vars.first(where: { $0.element >= wing.elements.count || (($0.kind == .gap || $0.kind == .overlap) && $0.element == 0) }) {
            return "\(v.id) refers to an element that is not there any more."
        }
        if let v = vars.first(where: { $0.kind == .airfoil && ($0.choices?.count ?? 0) < 2 }) {
            return shortlistJob.map { !$0.status.isFinished } ?? false
                ? "Finding sections for \(WingIssue.label(v.element).lowercased()) to choose between…"
                : "\(WingIssue.label(v.element)) section: no other sections to choose between yet (Find Sections)."
        }
        if let v = vars.first(where: { $0.kind != .airfoil && !($0.high > $0.low) }) { return "\(v.id): the upper bound must be above the lower." }
        if let v = vars.first(where: { $0.kind == .chord && $0.low <= 0 }) { return "\(v.id): a chord must stay above zero." }
        if let v = vars.first(where: { $0.kind == .gap && $0.low < 0 }) { return "\(v.id): a gap cannot be negative." }
        if vars.contains(where: { $0.kind == .height }) && wing.rideHeight == nil {
            return "The ride height is a variable only over a ground: turn on Ground in Flow."
        }
        if let v = vars.first(where: { $0.kind == .thickness && $0.low <= 0 }) {
            return "\(v.id): the thickness must stay above 0% (its lower bound is the structural limit)."
        }
        if optimise.objective == .maxClCdCap && !(optimise.cdCap > 0) { return "Set a Cd cap above zero." }
        if optimise.objective == .minCdClTarget && !(optimise.clTarget > 0) { return "Set a downforce target above zero." }
        if optimise.studyName.trimmingCharacters(in: .whitespaces).isEmpty { return "Name the study." }
        return nil
    }

    /// The sections the study's shapes are relative to: as the study recorded
    /// them, or for studies from before that, each element's section as it is
    /// in the library (the canvas may hold a trial's shape already).
    var studySections: [Airfoil]? {
        guard let study, study.spec.variables.contains(where: { $0.kind == "camber" || $0.kind == "thickness" }) else { return nil }
        let originals = wing.elements.map { e -> Airfoil in
            guard e.airfoil.key.hasPrefix("shaped/") else { return e.airfoil }
            return airfoil(String(e.airfoil.key.dropFirst("shaped/".count))) ?? e.airfoil
        }
        guard let recorded = study.baseSections, recorded.count == originals.count else { return originals }
        return zip(originals, recorded).map { original, unit in
            var a = original
            a.coords = unit.compactMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil }
            return a
        }
    }

    /// Puts a trial's wing on the canvas (undoable).
    func load(trial: WingStudy.Trial) {
        guard let w = wing.applying(trial, sections: studySections, library: { self.airfoil($0) }) else { return }
        edit { $0 = w }
        cardID = nil  // another wing now: Save as Card must not overwrite the last one's card
        selectedTrial = trial.number
        let best = study.map { s in (s.bestCheck?.number ?? s.bestTrial?.number) == trial.number } ?? false
        markOrigin("\(study?.study ?? optimise.studyName) · trial \(trial.number)" + (best ? " (best)" : ""))
    }

    /// Puts a card's wing on the canvas to edit (undoable); Save then updates that card.
    func open(card: WingCard) {
        editStep("Open \(card.name)") { $0 = Step(wing: card.wing, cardID: card.id, carX: nil) }
        markOrigin("card \(card.name)")
    }

    // MARK: Where the canvas wing came from

    /// What put the wing on the canvas: a study trial, the from-scratch
    /// starter. `depth` is the undo depth just after, so undoing past it
    /// drops the label.
    struct Origin {
        var label: String
        var wing: Wing
        var depth: Int
    }
    var origin: Origin?

    func markOrigin(_ label: String) { origin = Origin(label: label, wing: wing, depth: undoStack.count) }

    /// The wing on the canvas in a few words, for the SHOWING line.
    var shownVersion: String {
        if let t = replayTrial { return "\(study?.study ?? optimise.studyName) · trial \(t.number) (time-lapse)" }
        return originVersion ?? "Your design"
    }

    /// The origin's label while it still applies, "edited" once the wing has changed since.
    private var originVersion: String? {
        guard let o = origin, undoStack.count >= o.depth else { return nil }
        return o.wing == wing || o.label.hasSuffix(", edited") ? o.label : o.label + ", edited"
    }

    // The preview
    private(set) var preview: PanelSolution?
    private(set) var previewMilliseconds: Double = 0
    private(set) var previewError: String?

    var families: [String] { Array(Set(library.map(\.family))).sorted() }

    /// Built-in sections the user has hidden (they cannot be deleted: rebuilding the index brings them back).
    var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "wingHidden") ?? []) {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "wingHidden") }
    }
    var showHidden = false
    var libraryPolars: AirfoilLibrary.Polars?
    var librarySort = AirfoilLibrary.Sort.name
    var polarsJob: JobItem?
    /// The Reynolds number to compute the library's polars at: the main element's.
    var libraryRe: Double {
        let chord = wing.elements.first?.chord ?? 0.3
        return (wing.reynolds(chord: chord) / 1e4).rounded() * 1e4
    }

    var shown: [Airfoil] {
        AirfoilLibrary.sorted(library.filter { filter.matches($0, favourites: favourites) && (showHidden || !hidden.contains($0.key)) },
                              by: librarySort, polars: libraryPolars)
    }

    // MARK: Editing with undo

    /// Records the current wing for undo as `name` ("Undo Change Chord"), then applies a change.
    func edit(_ name: String = "Edit Wing", _ change: (inout Wing) -> Void) {
        editStep(name) { change(&$0.wing) }
    }

    /// The same, for a change to where the wing sits on the car too.
    func editStep(_ name: String = "Edit Wing", _ change: (inout Step) -> Void) {
        var next = step
        change(&next)
        guard next != step else { return }
        push(name)
        step = next
    }

    /// For a drag: one undo step for the whole gesture.
    func beginGesture(_ name: String = "Move") {
        push(name)
    }

    /// The window's, so Edit ▸ Undo and Redo walk this history by name
    @ObservationIgnored weak var undoManager: UndoManager?
    private var undoNames: [String] = []
    private var redoNames: [String] = []

    private func push(_ name: String) {
        undoStack.append(step)
        undoNames.append(name)
        if undoStack.count > 200 { undoStack.removeFirst(); undoNames.removeFirst() }
        redoStack = []
        redoNames = []
        register(name) { $0.undo() }
    }

    /// One entry in the undo manager per entry on these stacks
    private func register(_ name: String, _ action: @escaping (WingLabModel) -> Void) {
        undoManager?.registerUndo(withTarget: self) { model in MainActor.assumeIsolated { action(model) } }
        undoManager?.setActionName(name)
    }

    /// Changes during a drag, without new undo steps.
    func live(_ change: (inout Wing) -> Void) {
        var next = wing
        change(&next)
        wing = next
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        let name = undoNames.popLast() ?? "Edit Wing"
        redoStack.append(step)
        redoNames.append(name)
        step = last
        clampSelection()
        register(name) { $0.redo() }
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        let name = redoNames.popLast() ?? "Edit Wing"
        undoStack.append(step)
        undoNames.append(name)
        step = next
        clampSelection()
        register(name) { $0.undo() }
    }

    private func clampSelection() {
        if let s = selection, s >= wing.elements.count { selection = wing.elements.isEmpty ? nil : wing.elements.count - 1 }
    }

    /// Replaces the wing without undo (opening a project).
    func reset(to wing: Wing) {
        undoStack = []
        redoStack = []
        undoNames = []
        redoNames = []
        undoManager?.removeAllActions(withTarget: self)
        rulesAnchor = nil
        self.wing = wing
        cardID = nil
        carX = nil
        carHeight = nil
        origin = nil
        selection = wing.elements.isEmpty ? nil : 0
        recompute()
    }

    // MARK: Compare

    /// A design pinned as A, shown beside the wing on the canvas (B), with
    /// the results it had when pinned.
    struct Pinned {
        var wing: Wing
        var preview: PanelSolution?
        var estimate: WingEstimate?
        var rans: WingRansResult?
        var version = "Your design"
        var field: WingField?
    }

    var pinnedRansJob: JobItem?
    var pinned: Pinned? {
        didSet { changeImages = [:] }
    }

    // How the flow changed from A: B's field minus A's, scalar by scalar.
    var showChange = false
    @ObservationIgnored private var changeImages: [String: (image: CGImage, limit: Double)] = [:]

    /// Both have a field from runs in the same frame (same wing angle), so they can be subtracted.
    var canShowChange: Bool {
        guard let a = pinned, a.field != nil, let ar = a.rans, let br = ransResult, fieldIsCurrent else { return false }
        return abs((ar.frameTurn ?? 0) - (br.frameTurn ?? 0)) < 1e-9
    }

    /// B − A of one scalar as an image, with the ± limit its colours span.
    func changeImage(_ key: String) -> (image: CGImage, limit: Double)? {
        if let c = changeImages[key] { return c }
        guard canShowChange, let b = ransField, let a = pinned?.field else { return nil }
        let (px, limit) = b.difference(key, from: a)
        guard px.count == b.nx * b.ny * 4, let image = Self.image(px, b.nx, b.ny) else { return nil }
        changeImages[key] = (image, limit)
        return (image, limit)
    }

    private var current: Pinned {
        Pinned(wing: wing, preview: preview, estimate: estimate, rans: ransResult, version: shownVersion,
               field: fieldIsCurrent ? ransField : nil)
    }

    func pinCurrent() { pinned = current }

    /// A onto the canvas and the canvas wing into A; undo restores the wing.
    func swapWithPinned() {
        guard let a = pinned else { return }
        pinned = current
        edit("Swap with A") { $0 = a.wing }
        markOrigin(a.version)
        estimate = a.estimate
        ransResult = a.rans
        ransField = nil
        sweep = nil
    }

    // MARK: Elements

    /// Adds a section as the next element, behind the last one (or as the
    /// main element at the origin).
    func add(_ airfoil: Airfoil, at point: SIMD2<Double>? = nil) {
        edit("Add \(WingIssue.label(wing.elements.count))") { w in
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
        edit("Change \(WingIssue.label(index)) to \(airfoil.name)") { $0.elements[index].airfoil = airfoil }
        selection = index
    }

    func remove(_ index: Int) {
        guard wing.elements.indices.contains(index) else { return }
        edit("Remove \(WingIssue.label(index))") { $0.elements.remove(at: index) }
        clampSelection()
    }

    /// A copy of an element just behind it, 10 mm downstream
    func duplicate(_ index: Int) {
        guard wing.elements.indices.contains(index) else { return }
        edit("Duplicate \(WingIssue.label(index))") { w in
            var copy = w.elements[index]
            copy.id = UUID()
            copy.leadingEdge.x += 0.01
            w.elements.insert(copy, at: index + 1)
        }
        selection = index + 1
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
            libraryPolars = AirfoilLibrary.Polars.load(AirfoilLibrary.Polars.url(engineDirectory: dir))
        } catch {
            library = []
            libraryError = error.localizedDescription
        }
    }

    /// A section by key from the library, or a NACA 4-digit made on the spot.
    func airfoil(_ key: String) -> Airfoil? {
        library.first { $0.key == key } ?? (key.hasPrefix("naca/") ? Airfoil.naca4(String(key.dropFirst(5))) : nil)
    }

    /// The best section numbers there are for the wing: converged CFD, then the
    /// live estimate, then the inviscid preview with the typed-in Cd.
    var bestNumbers: (cl: Double, cd: Double, name: String)? {
        // CFD only of this wing: a run on an earlier shape is not its numbers.
        if let r = ransResult, r.converged, r.matches(wing.elements.map { $0.placed() }) { return (r.cl, r.cd, "CFD") }
        if let e = estimate?.row(nearest: wing.alpha) { return (e.cl, e.cd, "live estimate") }
        if let p = preview { return (p.clTotal, cdEstimate, "inviscid preview") }
        return nil
    }

    // MARK: Preview

    private func recompute() {
        guard !wing.elements.isEmpty else {
            preview = nil
            previewError = nil
            return
        }
        let start = Date()
        if let g = wing.inGroundEffect,
           let solver = PanelSolver(elements: g.elements, refChord: wing.refChord, ground: g.ground) {
            let image = solver.solve(alphaDeg: 0)  // turned: the flow and the ground run along x
            // The image's lift gain alone grows without limit near the ground: keep what RANS holds.
            let free = PanelSolver(elements: wing.elements.map { $0.placed() }, refChord: wing.refChord)?.solve(alphaDeg: wing.alpha)
            preview = free.map { image.groundCorrected(free: $0) } ?? image
            previewError = nil
        } else if wing.rideHeight == nil, let solver = PanelSolver(elements: wing.elements.map { $0.placed() }, refChord: wing.refChord) {
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
        try encoder.encode(SavedDesign(setup: design, name: designName, key: designKey))
            .write(to: folder.appendingPathComponent("design.json"), options: .atomic)
        markSaved()
        let version = folder.appendingPathComponent("version.txt")
        if let label = originVersion {
            try label.write(to: version, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: version)
        }
    }

    /// The SHOWING label saved beside wing.json, so a reopened project still
    /// says where its wing came from.
    func restoreVersion(fromProject project: URL) {
        let url = ProjectStore.toolURL(for: project, tool: "wing").appendingPathComponent("version.txt")
        if let label = try? String(contentsOf: url, encoding: .utf8), !label.isEmpty { markOrigin(label) }
    }

    // What the project files hold, so undoing back to it is not an unsaved change.
    private var savedWing: Wing?
    private var savedOptimise: OptimiseSetup?
    func markSaved() {
        savedWing = wing
        savedOptimise = optimise
    }
    var hasUnsavedChanges: Bool { wing != savedWing || optimise != savedOptimise }

    /// The Design card's chips and the study a Design run resumes, kept with the project.
    struct SavedDesign: Codable {
        var setup: DesignSetup
        var name: String?
        var key: String?
    }

    /// The Design card as the project left it, and its last finalists (beside the study).
    /// What runs made for the open project, cleared when another opens (as a relaunch would):
    /// another project's CFD, estimate or study must never be shown, pinned or saved on a card here.
    func clearResults() {
        pauseReplay()
        replayIndex = nil
        polar = nil
        polarElement = nil
        polarJob = nil
        ransJob = nil
        ransResult = nil
        ransPolarCache = nil
        ransFolder = nil
        ransField = nil
        meshJob = nil
        mesh = nil
        meshPath = nil
        meshOf = nil
        meshInfo = nil
        estimate = nil
        sweep = nil
        sweepFolder = nil
        sweepJob = nil
        sweepRow = nil
        study = nil
        optimiseJob = nil
        designRun = nil
        designResult = nil
        designShown = nil
        designStage = nil
        designJob = nil
        shortlists = [:]
        shortlistJob = nil
        selectedTrial = nil
        pinned = nil
        pinnedRansJob = nil
        showChange = false
    }

    func restoreDesign(fromProject project: URL) {
        let url = ProjectStore.toolURL(for: project, tool: "wing").appendingPathComponent("design.json")
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SavedDesign.self, from: $0) }
        design = saved?.setup ?? DesignSetup()
        designName = saved?.name
        designKey = saved?.key
        designShown = nil
        designResult = designName.flatMap { name in
            (try? Data(contentsOf: Self.designResultFile(project: project, name: name)))
                .flatMap { try? WingDesignResult.decode(resultFile: $0) }
        }
    }

    /// A design run's result, kept beside its study.
    static func designResultFile(project: URL, name: String) -> URL {
        studyFile(project: project, name: name).deletingPathExtension().appendingPathExtension("result.json")
    }

    static func loadOptimise(fromProject project: URL) -> OptimiseSetup? {
        let url = ProjectStore.toolURL(for: project, tool: "wing").appendingPathComponent("optimise.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OptimiseSetup.self, from: data)
    }

    /// Studies live in the project (or the scratch folder): <project>/wing/studies/<name>.db (Optuna)
    /// and <name>.json (the engine's export after every trial).
    static func studyFile(project: URL, name: String) -> URL {
        let safe = name.trimmingCharacters(in: .whitespaces).map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return ProjectStore.toolURL(for: project, tool: "wing").appendingPathComponent("studies")
            .appendingPathComponent(String(safe)).appendingPathExtension("db")
    }

    /// The wing a study started from, kept beside it when it starts.
    static func startFile(project: URL, name: String) -> URL {
        studyFile(project: project, name: name).deletingPathExtension().appendingPathExtension("start.json")
    }

    /// Reads the study's export, if there is one.
    func reloadStudy(project: URL) {
        let url = Self.studyFile(project: project, name: optimise.studyName).deletingPathExtension().appendingPathExtension("json")
        study = (try? Data(contentsOf: url)).flatMap { try? WingStudy.decode(exportFile: $0) }
    }
}

extension Wing {
    /// Cl as shown: positive for the load the wing is built for, so downforce
    /// reads positive on an inverted wing. The stored numbers keep their sign.
    func shownCl(_ cl: Double) -> Double { (elements.first?.inverted ?? false) ? -cl : cl }
}
