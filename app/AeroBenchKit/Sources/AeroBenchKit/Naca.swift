import Foundation
import simd

extension Airfoil {
    /// A NACA 4-digit section (MPXX) straight from the formula, the same
    /// points as the engine's naca4: cosine spacing, open trailing edge,
    /// Selig order.
    public static func naca4(_ code: String, points: Int = 161) -> Airfoil? {
        let digits = code.uppercased().replacingOccurrences(of: "NACA", with: "").trimmingCharacters(in: .whitespaces)
        guard digits.count == 4, let value = Int(digits) else { return nil }
        let m = Double(value / 1000) / 100
        let p = Double((value / 100) % 10) / 10
        let t = Double(value % 100) / 100
        guard t > 0 else { return nil }
        let half = (points + 1) / 2
        var upper: [SIMD2<Double>] = [], lower: [SIMD2<Double>] = []
        for i in 0..<half {
            let x = 0.5 * (1 - cos(Double.pi * Double(i) / Double(half - 1)))
            let yt = 5 * t * (0.2969 * x.squareRoot() - 0.1260 * x - 0.3516 * x * x + 0.2843 * x * x * x - 0.1015 * x * x * x * x)
            var yc = 0.0, dyc = 0.0
            if m > 0 && p > 0 {
                if x < p {
                    yc = m / (p * p) * (2 * p * x - x * x)
                    dyc = 2 * m / (p * p) * (p - x)
                } else {
                    yc = m / ((1 - p) * (1 - p)) * (1 - 2 * p + 2 * p * x - x * x)
                    dyc = 2 * m / ((1 - p) * (1 - p)) * (p - x)
                }
            }
            let th = atan(dyc)
            upper.append(SIMD2(x - yt * sin(th), yc + yt * cos(th)))
            lower.append(SIMD2(x + yt * sin(th), yc - yt * cos(th)))
        }
        let coords = Array(upper.reversed()) + lower.dropFirst()
        let te = simd_length(coords[0] - coords[coords.count - 1])
        return Airfoil(key: "naca/\(digits)", name: "NACA \(digits)", family: "NACA", source: "naca", thickness: t,
                       thicknessX: 0.3, camber: m, camberX: p, teThickness: te, coords: coords)
    }
}
