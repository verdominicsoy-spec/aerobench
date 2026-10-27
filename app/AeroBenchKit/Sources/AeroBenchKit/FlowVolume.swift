import CoreGraphics
import Foundation
import simd

/// A reconstructed volume as the engine writes it: volume.json + volume.bin
/// (float32, x then y then z, z fastest, NaN empty). Coordinates are world
/// metres; the planes step along `sweepAxis` and the frames showed `right`
/// to the right and `up` up.
public struct FlowVolume: Sendable {
    /// A signed world axis: "+y" is (sign 1, index 1).
    public struct Axis: Equatable, Sendable {
        public var sign: Int
        public var index: Int

        public init(_ text: String) {
            sign = text.hasPrefix("-") ? -1 : 1
            index = ["x", "y", "z"].firstIndex(of: String(text.suffix(1))) ?? 0
        }

        public var letter: String { ["x", "y", "z"][index] }
    }

    public let nx: Int
    public let ny: Int
    public let nz: Int
    public let x: [Double]
    public let y: [Double]
    public let z: [Double]
    public let sweepAxis: Int
    public let right: Axis
    public let up: Axis
    public let frames: [Int]
    public let vmin: Double
    public let vmax: Double
    public let colormap: [SIMD3<Float>]
    public let values: [Float]

    struct Meta: Decodable {
        var shape: [Int]
        var x: [Double]
        var y: [Double]?
        var z: [Double]?
        var y0: Double?
        var dy: Double?
        var z0: Double?
        var dz: Double?
        var sweep_axis: String?
        var right: String?
        var up: String?
        var frames: [Int]
        var value_range: [Double]
        var colormap: [[Double]]
    }

    public static func load(folder: URL) throws -> FlowVolume {
        let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: folder.appendingPathComponent("volume.json")))
        guard meta.shape.count == 3, meta.value_range.count == 2 else { throw ModelLoadError.malformed("bad volume.json") }
        let (nx, ny, nz) = (meta.shape[0], meta.shape[1], meta.shape[2])
        // The first format had only x in full, with even y and z.
        func even(_ start: Double?, _ step: Double?, _ n: Int) -> [Double] {
            (0..<n).map { (start ?? 0) + (step ?? 0) * Double($0) }
        }
        let y = meta.y ?? even(meta.y0, meta.dy, ny)
        let z = meta.z ?? even(meta.z0, meta.dz, nz)
        let data = try Data(contentsOf: folder.appendingPathComponent("volume.bin"), options: .mappedIfSafe)
        guard data.count == 4 * nx * ny * nz, meta.x.count == nx, y.count == ny, z.count == nz else {
            throw ModelLoadError.malformed("volume.bin is \(data.count) bytes, expected \(4 * nx * ny * nz)")
        }
        let values: [Float] = data.withUnsafeBytes { raw in
            (0..<(nx * ny * nz)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self))) }
        }
        let cmap = meta.colormap.map { SIMD3<Float>(Float($0[0]), Float($0[1]), Float($0[2])) }
        return FlowVolume(x: meta.x, y: y, z: z, sweepAxis: meta.sweep_axis ?? "x", right: meta.right ?? "+y",
                          up: meta.up ?? "+z", frames: meta.frames, vmin: meta.value_range[0], vmax: meta.value_range[1],
                          colormap: cmap.isEmpty ? [SIMD3(0, 0, 0), SIMD3(1, 1, 1)] : cmap, values: values)
    }

    public init(x: [Double], y: [Double], z: [Double], sweepAxis: String = "x", right: String = "+y", up: String = "+z",
                frames: [Int], vmin: Double, vmax: Double, colormap: [SIMD3<Float>], values: [Float]) {
        nx = x.count
        ny = y.count
        nz = z.count
        self.x = x
        self.y = y
        self.z = z
        self.sweepAxis = ["x", "y", "z"].firstIndex(of: sweepAxis) ?? 0
        self.right = Axis(right)
        self.up = Axis(up)
        self.frames = frames
        self.vmin = vmin
        self.vmax = vmax
        self.colormap = colormap
        self.values = values
    }

    @inline(__always) public func value(_ i: Int, _ j: Int, _ k: Int) -> Float {
        values[(i * ny + j) * nz + k]
    }

    public func coordinates(_ axis: Int) -> [Double] { [x, y, z][axis] }
    public var counts: [Int] { [nx, ny, nz] }

    public var bounds: (min: SIMD3<Double>, max: SIMD3<Double>) {
        (SIMD3(x.first ?? 0, y.first ?? 0, z.first ?? 0), SIMD3(x.last ?? 0, y.last ?? 0, z.last ?? 0))
    }

    // MARK: Planes

    public var sweepLetter: String { ["x", "y", "z"][sweepAxis] }
    public var planeCount: Int { counts[sweepAxis] }
    public func planePosition(_ i: Int) -> Double { coordinates(sweepAxis)[Swift.min(Swift.max(i, 0), planeCount - 1)] }

    /// Grid spacing across a plane (the in-plane axes are evenly spaced).
    public var cellSize: Double {
        let c = coordinates(right.index)
        return c.count > 1 ? abs(c[1] - c[0]) : 0
    }

    /// The span of one in-plane axis as (low, high) metres.
    public func range(_ axis: Int) -> ClosedRange<Double> {
        let c = coordinates(axis)
        return (c.first ?? 0)...(c.last ?? 0)
    }

    /// Where a slice image sits in the world: its centre and its full-width
    /// and full-height edge vectors (image right and image up), metres.
    public func sliceFrame(plane i: Int) -> (center: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>) {
        var center = SIMD3<Double>(repeating: 0)
        center[sweepAxis] = planePosition(i)
        var r = SIMD3<Double>(repeating: 0), u = SIMD3<Double>(repeating: 0)
        let rr = range(right.index), ur = range(up.index)
        center[right.index] = (rr.lowerBound + rr.upperBound) / 2
        center[up.index] = (ur.lowerBound + ur.upperBound) / 2
        r[right.index] = Double(right.sign) * (rr.upperBound - rr.lowerBound)
        u[up.index] = Double(up.sign) * (ur.upperBound - ur.lowerBound)
        return (center, r, u)
    }

    /// Colour for a value from the volume's own colour map.
    public func color(_ v: Double) -> SIMD3<Float> {
        let t = Swift.min(Swift.max((v - vmin) / (vmax - vmin), 0), 1)
        let i = Int((t * Double(colormap.count - 1)).rounded())
        return colormap[i]
    }

    /// One plane as an RGBA image, laid out as the video showed it: the right
    /// axis across, the up axis upward. Empty voxels are transparent.
    public func sliceImage(plane i: Int) -> CGImage? {
        guard (0..<planeCount).contains(i) else { return nil }
        let w = counts[right.index], h = counts[up.index]
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        var index = [0, 0, 0]
        index[sweepAxis] = i
        for row in 0..<h {
            // Top row is the far end of the up axis.
            index[up.index] = up.sign > 0 ? h - 1 - row : row
            for col in 0..<w {
                index[right.index] = right.sign > 0 ? col : w - 1 - col
                let v = value(index[0], index[1], index[2])
                guard !v.isNaN else { continue }
                let c = color(Double(v))
                let o = (row * w + col) * 4
                rgba[o] = UInt8((c.x * 255).rounded())
                rgba[o + 1] = UInt8((c.y * 255).rounded())
                rgba[o + 2] = UInt8((c.z * 255).rounded())
                rgba[o + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Voxel centres with lo <= value <= hi, thinned evenly to at most maxPoints.
    public func windowPoints(lo: Double, hi: Double, maxPoints: Int = 250_000) -> (positions: [SIMD3<Float>], colors: [SIMD4<Float>]) {
        let flo = Float(lo), fhi = Float(hi)
        var count = 0
        for v in values where v >= flo && v <= fhi { count += 1 }
        guard count > 0 else { return ([], []) }
        let skip = Swift.max(1, Int((Double(count) / Double(maxPoints)).rounded(.up)))
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []
        positions.reserveCapacity(count / skip + 1)
        colors.reserveCapacity(count / skip + 1)
        var seen = 0
        for i in 0..<nx {
            for j in 0..<ny {
                for k in 0..<nz {
                    let v = value(i, j, k)
                    guard v >= flo && v <= fhi else { continue }
                    defer { seen += 1 }
                    guard seen % skip == 0 else { continue }
                    positions.append(SIMD3(Float(x[i]), Float(y[j]), Float(z[k])))
                    let c = color(Double(v))
                    colors.append(SIMD4(c, 1))
                }
            }
        }
        return (positions, colors)
    }
}
