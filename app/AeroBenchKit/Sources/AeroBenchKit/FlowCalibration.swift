import Foundation

/// Capture calibration for the Flow Field Viewer, mirroring the engine's
/// JSON (snake_case on disk). Pixels are source-frame coordinates, origin top
/// left, continuous (pixel i covers [i, i+1)). World units are metres.
public struct FlowCalibration: Codable, Equatable, Sendable {
    public struct LegendLine: Codable, Equatable, Sendable {
        public var frame: Int
        public var p0: [Double]
        public var p1: [Double]
        public var halfWidth: Int?

        public init(frame: Int, p0: [Double], p1: [Double], halfWidth: Int? = nil) {
            self.frame = frame
            self.p0 = p0
            self.p1 = p1
            self.halfWidth = halfWidth
        }
    }

    public struct Colormap: Codable, Equatable, Sendable {
        public var preset: String?
        public var legend: LegendLine?

        public init(preset: String? = "star_blue_yellow_red", legend: LegendLine? = nil) {
            self.preset = preset
            self.legend = legend
        }
    }

    public struct CalPoint: Codable, Equatable, Sendable {
        public var px: [Double]
        public var world: [Double]

        public init(px: [Double], world: [Double]) {
            self.px = px
            self.world = world
        }
    }

    public struct CalFrame: Codable, Equatable, Sendable {
        public var frame: Int
        public var points: [CalPoint]

        public init(frame: Int, points: [CalPoint]) {
            self.frame = frame
            self.points = points
        }
    }

    public struct Spatial: Codable, Equatable, Sendable {
        public var mode = "points"
        public var frames: [CalFrame] = []
        public var width: Double?
        public var height: Double?
        public var origin: [Double]?

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "points"
            frames = try c.decodeIfPresent([CalFrame].self, forKey: .frames) ?? []
            width = try c.decodeIfPresent(Double.self, forKey: .width)
            height = try c.decodeIfPresent(Double.self, forKey: .height)
            origin = try c.decodeIfPresent([Double].self, forKey: .origin)
        }
    }

    public struct Planes: Codable, Equatable, Sendable {
        public var mode = "linear"
        public var start = 0.0
        public var end = 1.0
        public var positions: [Double]?
        public var firstFrame = 0
        public var lastFrame: Int?
        public var stride = 1

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "linear"
            start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
            end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 1
            positions = try c.decodeIfPresent([Double].self, forKey: .positions)
            firstFrame = try c.decodeIfPresent(Int.self, forKey: .firstFrame) ?? 0
            lastFrame = try c.decodeIfPresent(Int.self, forKey: .lastFrame)
            stride = try c.decodeIfPresent(Int.self, forKey: .stride) ?? 1
        }
    }

    /// Which world axis points right and which up in the frames ("+y",
    /// "-x", ...). The third axis is the sweep.
    public struct Axes: Codable, Equatable, Sendable {
        public var right = "+y"
        public var up = "+z"

        public init(right: String = "+y", up: String = "+z") {
            self.right = right
            self.up = up
        }

        public static let choices = ["+x", "-x", "+y", "-y", "+z", "-z"]

        public var rightLetter: String { String(right.suffix(1)) }
        public var upLetter: String { String(up.suffix(1)) }
        /// The axis the planes step along.
        public var sweepLetter: String {
            ["x", "y", "z"].first { $0 != rightLetter && $0 != upLetter } ?? "x"
        }

        public var isValid: Bool {
            Self.choices.contains(right) && Self.choices.contains(up) && rightLetter != upLetter
        }
    }

    /// Find the ground line in every frame and pin world z = level to it, so
    /// a perspective sweep needs one calibrated frame and cannot drift.
    public struct Ground: Codable, Equatable, Sendable {
        public var track = false
        public var level = 0.0

        public init(track: Bool = false, level: Double = 0.0) {
            self.track = track
            self.level = level
        }
    }

    public static let detailLevels = ["low", "medium", "high"]

    public var version = 1
    public var sourceSize: [Int]?
    public var crop: [Double]?
    public var exclude: [[Double]] = []
    public var colormap = Colormap()
    public var valueRange: [Double] = [-1, 1]
    public var spatial = Spatial()
    public var planes = Planes()
    public var maskColors: [[Double]] = [[255, 255, 255]]
    public var maskTolerance = 10.0
    public var threshold = 12.0
    public var median = 3
    public var workingWidth = 256
    public var extent = "all"
    public var window: [Double]?
    public var axes = Axes()
    public var ground = Ground()
    /// Grid resolution follows the frames' pixels up to this voxel budget;
    /// nil uses the fixed working width.
    public var detail: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FlowCalibration()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        sourceSize = try c.decodeIfPresent([Int].self, forKey: .sourceSize)
        crop = try c.decodeIfPresent([Double].self, forKey: .crop)
        exclude = try c.decodeIfPresent([[Double]].self, forKey: .exclude) ?? []
        colormap = try c.decodeIfPresent(Colormap.self, forKey: .colormap) ?? d.colormap
        valueRange = try c.decodeIfPresent([Double].self, forKey: .valueRange) ?? d.valueRange
        spatial = try c.decodeIfPresent(Spatial.self, forKey: .spatial) ?? d.spatial
        planes = try c.decodeIfPresent(Planes.self, forKey: .planes) ?? d.planes
        maskColors = try c.decodeIfPresent([[Double]].self, forKey: .maskColors) ?? d.maskColors
        maskTolerance = try c.decodeIfPresent(Double.self, forKey: .maskTolerance) ?? d.maskTolerance
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? d.threshold
        median = try c.decodeIfPresent(Int.self, forKey: .median) ?? d.median
        workingWidth = try c.decodeIfPresent(Int.self, forKey: .workingWidth) ?? d.workingWidth
        extent = try c.decodeIfPresent(String.self, forKey: .extent) ?? d.extent
        window = try c.decodeIfPresent([Double].self, forKey: .window)
        axes = try c.decodeIfPresent(Axes.self, forKey: .axes) ?? d.axes
        ground = try c.decodeIfPresent(Ground.self, forKey: .ground) ?? d.ground
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }

    public static let presets = ["star_blue_yellow_red", "viridis", "jet", "rainbow"]

    // MARK: JSON

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public static func load(_ url: URL) throws -> FlowCalibration {
        try decoder().decode(FlowCalibration.self, from: Data(contentsOf: url))
    }

    public func save(_ url: URL) throws {
        try Self.encoder().encode(self).write(to: url, options: .atomic)
    }

    /// As job params for the engine.
    public func jsonValue() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Self.encoder().encode(self))
    }

    // MARK: Readiness

    /// What still has to be set before a reconstruction can run.
    public var problems: [String] {
        var out: [String] = []
        if crop == nil { out.append("Draw the crop rectangle around the plot region.") }
        if colormap.preset == nil && colormap.legend == nil { out.append("Pick a colour map or sample the legend.") }
        if valueRange.count != 2 || !(valueRange[1] > valueRange[0]) { out.append("Set the value range, max above min.") }
        if !axes.isValid { out.append("Right and up must be different axes.") }
        if ground.track && axes.up != "+z" { out.append("Ground tracking needs +z pointing up; calibrate two frames instead.") }
        switch spatial.mode {
        case "points":
            if spatial.frames.isEmpty { out.append("Click two points of known position for the scale.") }
            for (i, f) in spatial.frames.enumerated() {
                let label = spatial.frames.count == 2 ? "calibration frame \(i + 1)" : "the scale"
                if f.points.count != 2 {
                    out.append("Click both points for \(label).")
                } else if f.points[0].world == f.points[1].world {
                    out.append("The two points for \(label) need different world positions.")
                }
            }
            if spatial.frames.count == 2 && spatial.frames[0].frame == spatial.frames[1].frame {
                out.append("Use two different frames for the perspective calibration.")
            }
        default:
            if (spatial.width ?? 0) <= 0 || (spatial.height ?? 0) <= 0 { out.append("Enter the plane width and height.") }
        }
        if planes.mode == "linear" && planes.start == planes.end { out.append("Plane start and end positions must differ.") }
        if planes.mode == "csv" && (planes.positions?.count ?? 0) < 2 { out.append("Import a CSV of plane positions.") }
        return out
    }
}
