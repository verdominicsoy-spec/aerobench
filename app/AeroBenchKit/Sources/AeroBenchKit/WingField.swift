import Foundation

/// The flow around the wing from a RANS run, resampled by the engine onto a
/// regular grid (field.json and field.bin in the run's folder): a few
/// scalars and streamlines, for the field view.
public struct WingField: Sendable {
    public struct Scalar: Codable, Equatable, Sendable, Identifiable {
        public var key: String
        public var name: String
        public var min: Double
        public var max: Double
        /// What the colormap spans by default (1st to 99th percentile; Cp
        /// symmetric about zero, Cp0 topped at the free stream's zero).
        public var range: [Double]
        public var colormap: [[Double]]

        public var id: String { key }
    }

    struct Header: Codable {
        var nx: Int
        var ny: Int
        var window: [Double]
        var vInf: Double?
        var scalars: [Scalar]
        var streamlines: [[[Double]]]

        enum CodingKeys: String, CodingKey {
            case nx, ny, window, scalars, streamlines
            case vInf = "v_inf"
        }
    }

    public let nx: Int
    public let ny: Int
    /// Window in the wing frame, metres: min x, min y, max x, max y.
    public let window: (x0: Double, y0: Double, x1: Double, y1: Double)
    public let scalars: [Scalar]
    public let streamlines: [[SIMD2<Double>]]
    /// One nx * ny block per scalar, rows from the bottom; NaN where there is no flow.
    let values: [[Float]]

    public init(json: Data, binary: Data) throws {
        let h = try JSONDecoder().decode(Header.self, from: json)
        guard h.window.count == 4, h.nx > 1, h.ny > 1 else { throw WingFieldError.bad("bad window or size") }
        let n = h.nx * h.ny
        guard binary.count == n * h.scalars.count * 4 else {
            throw WingFieldError.bad("field.bin holds \(binary.count) bytes, expected \(n * h.scalars.count * 4)")
        }
        var blocks: [[Float]] = []
        binary.withUnsafeBytes { raw in
            for k in 0..<h.scalars.count {
                var block = [Float](repeating: 0, count: n)
                for i in 0..<n {
                    block[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: (k * n + i) * 4, as: UInt32.self)))
                }
                blocks.append(block)
            }
        }
        nx = h.nx
        ny = h.ny
        window = (h.window[0], h.window[1], h.window[2], h.window[3])
        scalars = h.scalars
        streamlines = h.streamlines.map { $0.compactMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil } }
        values = blocks
    }

    /// Reads field.json and field.bin from a run folder.
    public static func load(from folder: URL) throws -> WingField {
        try WingField(json: Data(contentsOf: folder.appendingPathComponent("field.json")),
                      binary: Data(contentsOf: folder.appendingPathComponent("field.bin")))
    }

    /// The scalar's value at a point in the wing frame, or nil where there is no flow.
    public func value(_ key: String, at p: SIMD2<Double>) -> Double? {
        guard let k = scalars.firstIndex(where: { $0.key == key }) else { return nil }
        let i = Int(((p.x - window.x0) / (window.x1 - window.x0) * Double(nx)).rounded(.down))
        let j = Int(((p.y - window.y0) / (window.y1 - window.y0) * Double(ny)).rounded(.down))
        guard (0..<nx).contains(i), (0..<ny).contains(j) else { return nil }
        let v = values[k][j * nx + i]
        return v.isFinite ? Double(v) : nil
    }

    /// RGBA pixels (8 bits each, top row first, as CGImage wants) of one
    /// scalar through its colormap over `range`; no flow is transparent.
    public func pixels(_ key: String, range: ClosedRange<Double>? = nil) -> [UInt8] {
        guard let k = scalars.firstIndex(where: { $0.key == key }) else { return [] }
        let s = scalars[k]
        let lo = range?.lowerBound ?? s.range.first ?? s.min
        let hi = range?.upperBound ?? s.range.last ?? s.max
        let span = Swift.max(hi - lo, 1e-12)
        let cmap = s.colormap.isEmpty ? [[0, 0, 0], [1, 1, 1]] : s.colormap
        var out = [UInt8](repeating: 0, count: nx * ny * 4)
        let block = values[k]
        for j in 0..<ny {
            let row = (ny - 1 - j) * nx  // flip: the image's first row is the top
            for i in 0..<nx {
                let v = block[j * nx + i]
                guard v.isFinite else { continue }
                let t = Swift.min(Swift.max((Double(v) - lo) / span, 0), 1)
                let c = cmap[Swift.min(Int(t * Double(cmap.count - 1) + 0.5), cmap.count - 1)]
                let o = (row + i) * 4
                out[o] = UInt8(Swift.min(Swift.max(c[0], 0), 1) * 255)
                out[o + 1] = UInt8(Swift.min(Swift.max(c[1], 0), 1) * 255)
                out[o + 2] = UInt8(Swift.min(Swift.max(c[2], 0), 1) * 255)
                out[o + 3] = 255
            }
        }
        return out
    }
}

public enum WingFieldError: LocalizedError {
    case bad(String)

    public var errorDescription: String? {
        switch self {
        case .bad(let why): "The flow field could not be read: \(why)."
        }
    }
}
