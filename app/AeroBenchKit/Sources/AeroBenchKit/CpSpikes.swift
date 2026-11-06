import Foundation

/// −Cp lines with their spikes cut, so one spike can't squash the scale for
/// the rest: the high end of any segment steeper than `limit` (−Cp per chord)
/// is left out and the line breaks there.
public enum CpSpikes {
    public static let limit = 1000.0  // a jump of 10 in 1% of the chord

    /// For each point, the run it draws in (a new run after every cut), or nil when cut
    public static func runs(x: [Double], y: [Double]) -> [Int?] {
        let n = min(x.count, y.count)
        guard n > 1, let lo = x.prefix(n).min(), let hi = x.prefix(n).max(), hi > lo else { return Array(repeating: 0, count: n) }
        let chord = hi - lo
        var cut = Array(repeating: false, count: n)
        for k in 0..<(n - 1) {
            let dy = abs(y[k + 1] - y[k]), dx = abs(x[k + 1] - x[k]) / chord
            if dy > 0.5 && dy > limit * dx { cut[abs(y[k + 1]) > abs(y[k]) ? k + 1 : k] = true }
        }
        var run = 0, out: [Int?] = []
        for k in 0..<n {
            if cut[k] {
                out.append(nil)
                if k == 0 || !cut[k - 1] { run += 1 }
            } else {
                out.append(run)
            }
        }
        return out
    }
}
