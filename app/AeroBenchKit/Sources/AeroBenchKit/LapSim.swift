import Foundation

/// Car parameters for the lap sim. SI units, matching the engine's Car.
public struct CarParameters: Codable, Equatable, Sendable {
    public var mass: Double  // kg, with driver
    public var cla: Double  // m^2
    public var cda: Double  // m^2
    public var muLat: Double
    public var muLong: Double
    public var power: Double  // W
    public var drivenAxleFraction: Double  // 0...1
    public var aeroBalanceDriven: Double  // 0...1
    public var crr: Double
    public var rho: Double  // kg/m^3
    public var vMax: Double  // m/s
    /// Load transfer and tyre load sensitivity; all zero is the plain point mass.
    public var cogHeight: Double  // m
    public var wheelbase: Double  // m
    public var trackWidth: Double  // m
    public var tyreLoadSensitivity: Double  // fall in mu per unit rise in load over the static wheel load

    /// Estimates for a typical Formula Student car, not team data. Replace
    /// them in the app; anything still equal to these is marked as a
    /// placeholder.
    public static let placeholder = CarParameters(
        mass: 280, cla: 3.5, cda: 1.3, muLat: 1.5, muLong: 1.4, power: 80_000,
        drivenAxleFraction: 0.55, aeroBalanceDriven: 0.55, crr: 0.015, rho: 1.225, vMax: 33,
        cogHeight: 0.28, wheelbase: 1.53, trackWidth: 1.2, tyreLoadSensitivity: 0.15
    )

    public init(mass: Double, cla: Double, cda: Double, muLat: Double, muLong: Double, power: Double,
                drivenAxleFraction: Double, aeroBalanceDriven: Double, crr: Double, rho: Double, vMax: Double,
                cogHeight: Double = 0, wheelbase: Double = 0, trackWidth: Double = 0, tyreLoadSensitivity: Double = 0) {
        self.mass = mass
        self.cla = cla
        self.cda = cda
        self.muLat = muLat
        self.muLong = muLong
        self.power = power
        self.drivenAxleFraction = drivenAxleFraction
        self.aeroBalanceDriven = aeroBalanceDriven
        self.crr = crr
        self.rho = rho
        self.vMax = vMax
        self.cogHeight = cogHeight
        self.wheelbase = wheelbase
        self.trackWidth = trackWidth
        self.tyreLoadSensitivity = tyreLoadSensitivity
    }

    enum CodingKeys: String, CodingKey {
        case mass, cla, cda, power, crr, rho, wheelbase
        case cogHeight = "cog_height"
        case trackWidth = "track_width"
        case tyreLoadSensitivity = "tyre_load_sensitivity"
        case muLat = "mu_lat"
        case muLong = "mu_long"
        case drivenAxleFraction = "driven_axle_fraction"
        case aeroBalanceDriven = "aero_balance_driven"
        case vMax = "v_max"
    }

    /// Missing fields (an older project file) fall back to the placeholders.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let p = Self.placeholder
        mass = try c.decodeIfPresent(Double.self, forKey: .mass) ?? p.mass
        cla = try c.decodeIfPresent(Double.self, forKey: .cla) ?? p.cla
        cda = try c.decodeIfPresent(Double.self, forKey: .cda) ?? p.cda
        muLat = try c.decodeIfPresent(Double.self, forKey: .muLat) ?? p.muLat
        muLong = try c.decodeIfPresent(Double.self, forKey: .muLong) ?? p.muLong
        power = try c.decodeIfPresent(Double.self, forKey: .power) ?? p.power
        drivenAxleFraction = try c.decodeIfPresent(Double.self, forKey: .drivenAxleFraction) ?? p.drivenAxleFraction
        aeroBalanceDriven = try c.decodeIfPresent(Double.self, forKey: .aeroBalanceDriven) ?? p.aeroBalanceDriven
        crr = try c.decodeIfPresent(Double.self, forKey: .crr) ?? p.crr
        rho = try c.decodeIfPresent(Double.self, forKey: .rho) ?? p.rho
        vMax = try c.decodeIfPresent(Double.self, forKey: .vMax) ?? p.vMax
        // Projects from before load transfer keep the point mass they were run with.
        cogHeight = try c.decodeIfPresent(Double.self, forKey: .cogHeight) ?? 0
        wheelbase = try c.decodeIfPresent(Double.self, forKey: .wheelbase) ?? 0
        trackWidth = try c.decodeIfPresent(Double.self, forKey: .trackWidth) ?? 0
        tyreLoadSensitivity = try c.decodeIfPresent(Double.self, forKey: .tyreLoadSensitivity) ?? 0
    }
}

public enum LapSimTrackKind: String, Codable, CaseIterable, Sendable {
    case testTrack = "test_track"
    case fsg = "fsg_2019"
    case fsi = "fsi_2019"
    case skidpad
    case acceleration
    case csv

    public var title: String {
        switch self {
        case .testTrack: "test track"
        case .fsg: "FSG Hockenheim"
        case .fsi: "FSI Varano"
        case .skidpad: "skidpad"
        case .acceleration: "acceleration"
        case .csv: "imported track"
        }
    }
}

public struct LapSimTrack: Codable, Equatable, Sendable {
    public static let defaultSkidpadRadius = 9.125
    public static let defaultAccelerationLength = 75.0

    public var kind: LapSimTrackKind = .testTrack
    public var skidpadRadius = LapSimTrack.defaultSkidpadRadius  // m
    public var accelerationLength = LapSimTrack.defaultAccelerationLength  // m
    /// Relative to the project's lapsim/ folder, or absolute when no project was open.
    public var csvPath: String?
    /// nil means detect from whether the ends meet.
    public var csvClosed: Bool?
    /// Multiplier from file units to metres (0.001 for mm).
    public var csvScale = 1.0
    /// Expected scatter of the centreline points, m.
    public var smoothing = 0.05

    public init() {}

    enum CodingKeys: String, CodingKey {
        case kind, skidpadRadius, accelerationLength, csvPath, csvClosed, csvScale, smoothing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(LapSimTrackKind.self, forKey: .kind) ?? .testTrack
        skidpadRadius = try c.decodeIfPresent(Double.self, forKey: .skidpadRadius) ?? Self.defaultSkidpadRadius
        accelerationLength = try c.decodeIfPresent(Double.self, forKey: .accelerationLength) ?? Self.defaultAccelerationLength
        csvPath = try c.decodeIfPresent(String.self, forKey: .csvPath)
        csvClosed = try c.decodeIfPresent(Bool.self, forKey: .csvClosed)
        csvScale = try c.decodeIfPresent(Double.self, forKey: .csvScale) ?? 1
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? 0.05
    }

    public func csvURL(lapsimFolder: URL?) -> URL? {
        guard let path = csvPath, !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return lapsimFolder?.appendingPathComponent(path)
    }

    public func jobValue(lapsimFolder: URL?) -> JSONValue {
        switch kind {
        case .skidpad:
            return .object(["builtin": .string("skidpad"), "radius": .double(skidpadRadius)])
        case .acceleration:
            return .object(["builtin": .string("acceleration"), "length": .double(accelerationLength)])
        case .testTrack:
            return .object(["builtin": .string("test_track")])
        case .fsg, .fsi:
            return .object(["builtin": .string(kind.rawValue)])
        case .csv:
            var obj: [String: JSONValue] = [
                "csv": .string(csvURL(lapsimFolder: lapsimFolder)?.path ?? ""),
                "scale": .double(csvScale),
                "smoothing": .double(smoothing),
            ]
            if let csvClosed { obj["closed"] = .bool(csvClosed) }
            return .object(obj)
        }
    }
}

/// Everything the Lap Sim screen edits. Saved as lapsim/setup.json.
public struct LapSimSetup: Codable, Equatable, Sendable {
    public static let fileName = "setup.json"

    public var carA = CarParameters.placeholder
    public var carB = CarParameters.placeholder
    public var compare = false
    public var track = LapSimTrack()
    public var ds = 0.5  // m
    public var enduranceLaps = 22
    public var startSpeed = 0.0  // m/s, open tracks only
    public var sensitivities = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case carA, carB, compare, track, ds, enduranceLaps, startSpeed, sensitivities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LapSimSetup()
        carA = try c.decodeIfPresent(CarParameters.self, forKey: .carA) ?? d.carA
        carB = try c.decodeIfPresent(CarParameters.self, forKey: .carB) ?? d.carB
        compare = try c.decodeIfPresent(Bool.self, forKey: .compare) ?? d.compare
        track = try c.decodeIfPresent(LapSimTrack.self, forKey: .track) ?? d.track
        ds = try c.decodeIfPresent(Double.self, forKey: .ds) ?? d.ds
        enduranceLaps = try c.decodeIfPresent(Int.self, forKey: .enduranceLaps) ?? d.enduranceLaps
        startSpeed = try c.decodeIfPresent(Double.self, forKey: .startSpeed) ?? d.startSpeed
        sensitivities = try c.decodeIfPresent(Bool.self, forKey: .sensitivities) ?? d.sensitivities
    }

    public func jobParams(lapsimFolder: URL?) throws -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "car": try JSONValue(encoding: carA),
            "track": track.jobValue(lapsimFolder: lapsimFolder),
            "ds": .double(ds),
            "laps": .int(enduranceLaps),
            "start_speed": .double(startSpeed),
            "sensitivities": .bool(sensitivities),
        ]
        if compare { params["car_b"] = try JSONValue(encoding: carB) }
        return params
    }

    public static func load(fromProject project: URL) -> LapSimSetup? {
        let url = ProjectStore.toolURL(for: project, tool: "lapsim").appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? AeroJSON.decoder().decode(LapSimSetup.self, from: data)
    }

    public func save(toProject project: URL) throws {
        let folder = ProjectStore.toolURL(for: project, tool: "lapsim")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try AeroJSON.encoder().encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// The "data" object of a lapsim result.json.
public struct LapSimResult: Decodable, Sendable {
    public struct TrackData: Decodable, Sendable {
        public var name: String
        public var length: Double
        public var closed: Bool
        public var ds: Double
        public var s: [Double]
        public var x: [Double]
        public var y: [Double]
        public var kappa: [Double]
    }

    public struct Sensitivity: Decodable, Sendable {
        public var dtDcla: Double
        public var dtDcda: Double
        /// m^2 of ClA worth one m^2 of CdA at equal lap time; nil when ClA does not help.
        public var claPerCda: Double?
        public var stepCla: Double
        public var stepCda: Double

        enum CodingKeys: String, CodingKey {
            case dtDcla = "dt_dcla", dtDcda = "dt_dcda", claPerCda = "cla_per_cda"
            case stepCla = "step_cla", stepCda = "step_cda"
        }
    }

    public struct Endurance: Decodable, Sendable {
        public var laps: Int
        public var time: Double
        public var energy: Double
    }

    public struct Config: Decodable, Sendable {
        public var car: CarParameters
        public var lapTime: Double
        public var energy: Double
        public var vMin: Double
        public var vMax: Double
        public var vAvg: Double
        public var endurance: Endurance
        public var v: [Double]
        public var t: [Double]
        public var vCorner: [Double]
        public var sensitivity: Sensitivity?

        enum CodingKeys: String, CodingKey {
            case car, energy, endurance, v, t, sensitivity
            case lapTime = "lap_time", vMin = "v_min", vMax = "v_max", vAvg = "v_avg", vCorner = "v_corner"
        }
    }

    public var track: TrackData
    public var startSpeed: Double
    public var a: Config
    public var b: Config?
    public var deltaT: [Double]?

    enum CodingKeys: String, CodingKey {
        case track, a, b
        case startSpeed = "start_speed", deltaT = "delta_t"
    }

    /// Decodes the whole result.json written by the engine.
    public static func decode(resultFile data: Data) throws -> LapSimResult {
        struct Envelope: Decodable { var data: LapSimResult }
        return try JSONDecoder().decode(Envelope.self, from: data).data
    }
}
