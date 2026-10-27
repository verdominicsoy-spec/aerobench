import CoreGraphics
import Foundation
import simd

/// A reconstructed volume as the engine writes it: volume.json + volume.bin
/// (float32, x then y then z, z fastest, NaN empty).
public struct FlowVolume: Sendable {
    public let nx: Int
    public let ny: Int
    public let nz: Int
    public let x: [Double]
    public let y0: Double
    public let dy: Double
    public let z0: Double
    public let dz: Double
    public let frames: [Int]
    public let vmin: Double
    public let vmax: Double
    public let colormap: [SIMD3<Float>]
    public let values: [Float]

    struct Meta: Decodable {
        var shape: [Int]
        var x: [Double]
        var y0: Double
        var dy: Double
        var z0: Double
        var dz: Double
        var frames: [Int]
        var value_range: [Double]
        var colormap: [[Double]]
    }

    public static func load(folder: URL) throws -> FlowVolume {
        let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: folder.appendingPathComponent("volume.json")))
        guard meta.shape.count == 3, meta.value_range.count == 2 else { throw ModelLoadError.malformed("bad volume.json") }
        let (nx, ny, nz) = (meta.shape[0], meta.shape[1], meta.shape[2])
        let data = try Data(contentsOf: folder.appendingPathComponent("volume.bin"), options: .mappedIfSafe)
        guard data.count == 4 * nx * ny * nz, meta.x.count == nx else {
            throw ModelLoadError.malformed("volume.bin is \(data.count) bytes, expected \(4 * nx * ny * nz)")
        }
        let values: [Float] = data.withUnsafeBytes { raw in
            (0..<(nx * ny * nz)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self))) }
        }
        let cmap = meta.colormap.map { SIMD3<Float>(Float($0[0]), Float($0[1]), Float($0[2])) }
        return FlowVolume(nx: nx, ny: ny, nz: nz, x: meta.x, y0: meta.y0, dy: meta.dy, z0: meta.z0, dz: meta.dz,
                          frames: meta.frames, vmin: meta.value_range[0], vmax: meta.value_range[1],
                          colormap: cmap.isEmpty ? [SIMD3(0, 0, 0), SIMD3(1, 1, 1)] : cmap, values: values)
    }

    public init(nx: Int, ny: Int, nz: Int, x: [Double], y0: Double, dy: Double, z0: Double, dz: Double,
                frames: [Int], vmin: Double, vmax: Double, colormap: [SIMD3<Float>], values: [Float]) {
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.x = x
        self.y0 = y0
        self.dy = dy
        self.z0 = z0
        self.dz = dz
        self.frames = frames
        self.vmin = vmin
        self.vmax = vmax
        self.colormap = colormap
        self.values = values
    }

    @inline(__always) public func value(_ i: Int, _ j: Int, _ k: Int) -> Float {
        values[(i * ny + j) * nz + k]
    }

    public var y1: Double { y0 + dy * Double(ny - 1) }
    public var z1: Double { z0 + dz * Double(nz - 1) }

    public var bounds: (min: SIMD3<Double>, max: SIMD3<Double>) {
        (SIMD3(x.first ?? 0, y0, z0), SIMD3(x.last ?? 0, y1, z1))
    }

    /// Colour for a value from the volume's own colour map.
    public func color(_ v: Double) -> SIMD3<Float> {
        let t = Swift.min(Swift.max((v - vmin) / (vmax - vmin), 0), 1)
        let i = Int((t * Double(colormap.count - 1)).rounded())
        return colormap[i]
    }

    /// One plane as an RGBA image: width ny (y to the right), height nz,
    /// first row the top (max z). Empty voxels are transparent.
    public func sliceImage(plane i: Int) -> CGImage? {
        guard (0..<nx).contains(i) else { return nil }
        var rgba = [UInt8](repeating: 0, count: ny * nz * 4)
        for row in 0..<nz {
            let k = nz - 1 - row
            for j in 0..<ny {
                let v = value(i, j, k)
                guard !v.isNaN else { continue }
                let c = color(Double(v))
                let o = (row * ny + j) * 4
                rgba[o] = UInt8((c.x * 255).rounded())
                rgba[o + 1] = UInt8((c.y * 255).rounded())
                rgba[o + 2] = UInt8((c.z * 255).rounded())
                rgba[o + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: ny, height: nz, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ny * 4,
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
                    positions.append(SIMD3(Float(x[i]), Float(y0 + dy * Double(j)), Float(z0 + dz * Double(k))))
                    let c = color(Double(v))
                    colors.append(SIMD4(c, 1))
                }
            }
        }
        return (positions, colors)
    }
}
