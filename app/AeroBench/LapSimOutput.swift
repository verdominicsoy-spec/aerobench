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
        let config: String
    }

    /// Where on the track one car gains or loses on A: seconds per 100 m, negative where it gains.
    struct Gain {
        let points: [GainPoint]
        let limit: Double
    }

    let jobID: String
    let result: LapSimResult
    /// The cars' labels, A first.
    let labels: [String]
    let speed: [SpeedPoint]
    /// The track coloured by each car's speed, in the order of `labels`.
    let maps: [[MapPoint]]
    /// Each car against A along the lap (A itself has none).
    let delta: [DeltaPoint]
    /// Per car, nil for A.
    let gains: [Gain?]

    struct GainPoint: Identifiable {
        let id: Int
        let x: Double
        let y: Double
        let rate: Double  // s per 100 m
    }
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

        let labels = Array(LapSimSetup.labels.prefix(result.configs.count))
        self.labels = labels
        var speed: [SpeedPoint] = []
        // Ids unique across cars: car index times the track's point count, plus the point.
        let n = track.s.count
        for (k, (name, config)) in zip(labels, result.configs).enumerated() {
            speed += idx.map { SpeedPoint(id: k * n + $0, s: track.s[$0], kmh: config.v[$0] * 3.6, config: name) }
        }
        self.speed = speed
        maps = result.configs.map { config in idx.map { MapPoint(id: $0, x: track.x[$0], y: track.y[$0], kmh: config.v[$0] * 3.6) } }

        var delta: [DeltaPoint] = []
        for (k, (name, dt)) in zip(labels, result.deltas).enumerated() {
            guard let dt, dt.count == n else { continue }
            delta += idx.map { DeltaPoint(id: k * n + $0, s: track.s[$0], dt: dt[$0], config: name) }
        }
        self.delta = delta
        // Slope of the time delta along the lap, smoothed over about 5 m so one
        // step's noise does not paint the map.
        gains = result.deltas.map { dt -> Gain? in
            guard let dt, dt.count == track.s.count, dt.count > 2 else { return nil }
            let n = dt.count
            let ds = max((track.s.last ?? 1) / Double(n - 1), 1e-6)
            let reach = max(Int((2.5 / ds).rounded()), 1)
            var points: [GainPoint] = []
            for i in idx {
                let a = max(i - reach, 0), b = min(i + reach, n - 1)
                let span = track.s[b] - track.s[a]
                guard span > 0 else { continue }
                points.append(GainPoint(id: i, x: track.x[i], y: track.y[i], rate: (dt[b] - dt[a]) / span * 100))
            }
            // Symmetric colour range from the 95th percentile, so one spike does not wash out the rest.
            let mags = points.map { abs($0.rate) }.sorted()
            return Gain(points: points, limit: max(mags.isEmpty ? 0.01 : mags[min(Int(Double(mags.count) * 0.95), mags.count - 1)], 1e-4))
        }

        // Square domains so the map keeps its true shape.
        let (x0, x1) = (track.x.min() ?? 0, track.x.max() ?? 1)
        let (y0, y1) = (track.y.min() ?? 0, track.y.max() ?? 1)
        let half = max(x1 - x0, y1 - y0, 1) / 2 * 1.08
        let (cx, cy) = ((x0 + x1) / 2, (y0 + y1) / 2)
        xDomain = (cx - half)...(cx + half)
        yDomain = (cy - half)...(cy + half)

        let all = result.configs.flatMap(\.v)
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
