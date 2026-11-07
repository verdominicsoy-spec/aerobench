import Foundation

/// How number boxes read and show numbers: points for decimals in every locale and no
/// thousands separators, so "1,184" is refused instead of read as 1184.
public enum NumberText {
    static let posix = Locale(identifier: "en_US_POSIX")

    public static func format(_ v: Double, digits: Int) -> String {
        let fixed = v.formatted(.number.precision(.fractionLength(0...digits)).grouping(.never).locale(posix))
        // A small value (a viscosity in Pa s) would round to 0: show its significant digits instead.
        guard v != 0, Double(fixed) == 0 else { return fixed }
        return v.formatted(.number.precision(.significantDigits(1...4)).grouping(.never).locale(posix))
    }

    /// The number typed, nil for an empty box, or why it is not a number.
    public static func parse(_ text: String) -> Result<Double?, Problem> {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "−", with: "-")
        if t.isEmpty { return .success(nil) }
        if t.contains(",") { return .failure(Problem("Use a point for decimals and no thousands commas")) }
        guard let v = Double(t), v.isFinite else { return .failure(Problem("“\(t)” is not a number")) }
        return .success(v)
    }

    public struct Problem: Error, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// "Expected 0.3 to 2 kg/m³" outside `range`, else nil.
    public static func within(_ range: ClosedRange<Double>, _ unit: String = "") -> (Double) -> String? {
        { v in range.contains(v) ? nil
            : "Expected \(format(range.lowerBound, digits: 6)) to \(format(range.upperBound, digits: 6))" + (unit.isEmpty ? "" : " \(unit)") }
    }
}
