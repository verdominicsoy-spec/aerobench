import Foundation

/// What `flow-detect` found in a video (its result data, snake_case on disk).
public struct FlowDetection: Codable, Equatable, Sendable {
    public struct Legend: Codable, Equatable, Sendable {
        public var p0: [Double]
        public var p1: [Double]
        public var halfWidth: Int?
        public var frame: Int?
        public var box: [Double]?
    }

    public var found: Bool
    public var crop: [Double]?
    public var exclude: [[Double]]?
    public var legend: Legend?
    public var groundVisible: Bool?
    public var axes: FlowCalibration.Axes?
    public var triadBox: [Double]?
    public var sourceSize: [Int]?
    public var message: String?

    /// From a job's result file ({"data": {...}}).
    public static func decode(resultFile data: Data) throws -> FlowDetection {
        struct Wrapper: Decodable { var data: FlowDetection }
        return try FlowCalibration.decoder().decode(Wrapper.self, from: data).data
    }
}

extension FlowCalibration {
    /// The quick setup's scale: a horizontal line dragged across something of
    /// known width on one frame, its middle at `centre` along the right axis.
    /// Pixels in the source frame, metres in the world.
    public struct Measure: Codable, Equatable, Sendable {
        public var frame: Int
        public var p0: [Double]
        public var p1: [Double]
        public var width: Double
        public var centre: Double

        public init(frame: Int, p0: [Double], p1: [Double], width: Double, centre: Double = 0) {
            self.frame = frame
            self.p0 = p0
            self.p1 = p1
            self.width = width
            self.centre = centre
        }

        public var pixelLength: Double {
            guard p0.count == 2, p1.count == 2 else { return 0 }
            return abs(p1[0] - p0[0])
        }
    }

    /// Fills in the crop, exclusions, legend, axes and ground tracking from a
    /// detection. Returns what it did, in plain words.
    @discardableResult
    public mutating func apply(_ d: FlowDetection) -> [String] {
        guard d.found, let found = d.crop, found.count == 4 else {
            return [d.message ?? "No plot found in the video. Use All Settings to draw the crop by hand."]
        }
        var notes: [String] = []
        crop = found
        exclude = (d.exclude ?? []).filter { $0.count == 4 }
        if let size = d.sourceSize { sourceSize = size }
        notes.append("Found the plot" + (exclude.isEmpty ? "." : " and \(exclude.count) thing\(exclude.count == 1 ? "" : "s") drawn over it to ignore."))
        if let l = d.legend, l.p0.count == 2, l.p1.count == 2 {
            colormap = .init(preset: nil, legend: .init(frame: l.frame ?? 0, p0: l.p0, p1: l.p1, halfWidth: l.halfWidth))
            notes.append("Read the colours off the legend.")
        } else {
            notes.append("No legend bar found, so the STAR blue-yellow-red colours are assumed.")
        }
        if let a = d.axes, a.isValid {
            axes = a
            notes.append("Read the axes off the triad: \(a.right) right, \(a.up) up.")
        } else {
            notes.append("Could not read the axis triad: check the axes below.")
        }
        if d.groundVisible == true {
            ground.track = true
            notes.append("The ground is in view: it will hold the planes in place.")
        } else {
            ground.track = false
            notes.append("No ground line found along the bottom of the plot.")
        }
        if detail == nil { detail = "medium" }
        extent = "auto"  // spend the cells around the car and its wake
        applyMeasure()
        return notes
    }

    /// Turns the measurement into the two calibration points the engine uses.
    public mutating func applyMeasure() {
        guard let m = measure, m.p0.count == 2, m.p1.count == 2, m.width > 0, m.pixelLength >= 2 else { return }
        let sign: Double = axes.right.hasPrefix("-") ? -1 : 1
        let (left, right) = m.p0[0] <= m.p1[0] ? (m.p0, m.p1) : (m.p1, m.p0)
        let v = (left[1] + right[1]) / 2
        spatial.mode = "points"
        spatial.frames = [CalFrame(frame: m.frame, points: [
            CalPoint(px: [left[0], v], world: [m.centre - sign * m.width / 2, 0]),
            CalPoint(px: [right[0], v], world: [m.centre + sign * m.width / 2, 0]),
        ])]
    }

    /// The direction the third axis points, for drawing the triad: "toward"
    /// (out of the screen, a dot) or "away" (into it). Right-handed axes.
    public var sweepTowardViewer: Bool? {
        guard axes.isValid else { return nil }
        func vec(_ s: String) -> SIMD3<Double> {
            let sign: Double = s.hasPrefix("-") ? -1 : 1
            switch s.suffix(1) {
            case "x": return SIMD3(sign, 0, 0)
            case "y": return SIMD3(0, sign, 0)
            default: return SIMD3(0, 0, sign)
            }
        }
        let r = vec(axes.right), u = vec(axes.up)
        let out = SIMD3(r.y * u.z - r.z * u.y, r.z * u.x - r.x * u.z, r.x * u.y - r.y * u.x)  // right x up: toward the viewer
        return (out * vec("+" + axes.sweepLetter)).sum() > 0
    }

    /// One line of the quick setup's checklist.
    public struct QuickStep: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var done: Bool
        public var hint: String
    }

    /// The quick setup's steps, each done or with what to do, in order.
    public var quickSteps: [QuickStep] {
        let spatialOK = scaleProblems.isEmpty
        let planesOK = planeProblems.isEmpty
        let rangeOK = valueRange.count == 2 && valueRange[1] > valueRange[0]
        return [
            QuickStep(id: "video", title: "Plot found", done: crop != nil,
                      hint: "Open the video; the plot, legend and axes are found automatically."),
            QuickStep(id: "values", title: "Legend values", done: rangeOK,
                      hint: "Type the numbers at the two ends of the legend, high above low."),
            QuickStep(id: "axes", title: "Axes", done: axes.isValid,
                      hint: "Pick the axis that points right and the one that points up, as on STAR's triad."),
            QuickStep(id: "ground", title: "Ground", done: ground.track || spatial.frames.count == 2,
                      hint: "The ground line holds the planes in place. It was not found: open All Settings and calibrate two frames instead."),
            QuickStep(id: "size", title: "Size", done: spatialOK,
                      hint: "Drag across something you know the width of, then type the width."),
            QuickStep(id: "planes", title: "Plane positions", done: planesOK,
                      hint: "Type where the first and last planes are along the car."),
        ]
    }
}
