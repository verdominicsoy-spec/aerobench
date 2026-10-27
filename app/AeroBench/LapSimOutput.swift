import AeroBenchKit
import Foundation

/// A decoded lap sim result with its chart data prepared once.
struct LapSimOutput {
    struct SpeedPoint: Identifiable {
        let id: Int
        let s: Double
        let kmh: Double
        let config: String
    }

    struct MapPoint: Identifiable {
        let id: Int
        let x: Double
        let y: Double
        let kmh: Double
    }

    struct DeltaPoint: Identifiable {
        let id: Int
        let s: Double
        let dt: Double
    }

    let jobID: String
    let result: LapSimResult
    let speed: [SpeedPoint]
    let mapA: [MapPoint]
    let mapB: [MapPoint]
    let delta: [DeltaPoint]
    let xDomain: ClosedRange<Double>
    let yDomain: ClosedRange<Double>
    let kmhRange: ClosedRange<Double>

    /// Charts stay responsive with a couple of thousand marks per series.
    private static let maxPoints = 1500

    init(jobID: String, result: LapSimResult) {
        self.jobID = jobID
        self.result = result
        let track = result.track
        let idx = Self.indices(count: track.s.count)

        var speed: [SpeedPoint] = []
        let configs: [(String, LapSimResult.Config?)] = [("A", result.a), ("B", result.b)]
        for (name, config) in configs {
            guard let config else { continue }
            let base = speed.count
            speed += idx.map { SpeedPoint(id: base + $0, s: track.s[$0], kmh: config.v[$0] * 3.6, config: name) }
        }
        self.speed = speed

        func map(_ config: LapSimResult.Config?) -> [MapPoint] {
            guard let config else { return [] }
            return idx.map { MapPoint(id: $0, x: track.x[$0], y: track.y[$0], kmh: config.v[$0] * 3.6) }
        }
        mapA = map(result.a)
        mapB = map(result.b)
        delta = result.deltaT.map { dt in idx.map { DeltaPoint(id: $0, s: track.s[$0], dt: dt[$0]) } } ?? []

        // Square domains so the map keeps its true shape.
        let (x0, x1) = (track.x.min() ?? 0, track.x.max() ?? 1)
        let (y0, y1) = (track.y.min() ?? 0, track.y.max() ?? 1)
        let half = max(x1 - x0, y1 - y0, 1) / 2 * 1.08
        let (cx, cy) = ((x0 + x1) / 2, (y0 + y1) / 2)
        xDomain = (cx - half)...(cx + half)
        yDomain = (cy - half)...(cy + half)

        let all = result.a.v + (result.b?.v ?? [])
        let lo = (all.min() ?? 0) * 3.6
        let hi = (all.max() ?? 1) * 3.6
        kmhRange = lo...max(hi, lo + 0.1)
    }

    private static func indices(count: Int) -> [Int] {
        guard count > maxPoints else { return Array(0..<count) }
        let step = Double(count - 1) / Double(maxPoints - 1)
        var out = (0..<maxPoints).map { Int((Double($0) * step).rounded()) }
        out[out.count - 1] = count - 1
        return Array(Set(out)).sorted()
    }
}
