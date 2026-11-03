import Foundation

/// A prism layer sized from the free stream, with the same flat-plate
/// estimates the engine meshes Wing Lab's RANS runs with (wing/mesh.py):
/// Schlichting's Cf = 0.026 Re^-1/7 for the wall distance and
/// 0.37 L Re^-0.2 for the turbulent boundary layer. Gives the three values
/// STAR 2606's custom prism control takes in near wall thickness mode.
public struct PrismLayer: Equatable, Sendable {
    public enum WallTreatment: String, CaseIterable, Sendable {
        /// y+ about 1: the stack holds the whole boundary layer
        case resolved
        /// y+ 30 to 50: a few layers, sized by count and stretching, not by δ
        case wallFunctions
    }

    /// Something in the stack that will hurt the mesh or the solve
    public enum Warning: Equatable, Sendable {
        /// Resolved with no clearance: the total is the full boundary layer
        case noClearance
        /// Wall functions with a total over 10 mm
        case thickStack
        /// Stretching over 1.3
        case steepStretching
        /// Achieved y+ outside 0.5 to 5 (resolved) or 30 to 100 (wall functions)
        case yPlusOutOfRange
        /// Near wall thickness under 5 µm
        case thinFirstCell
    }

    public var treatment: WallTreatment
    public var reynolds: Double
    /// u* = U sqrt(Cf / 2)
    public var frictionVelocity: Double
    /// y = y+ μ / (ρ u*), wall to where y+ is read. STAR reads y+ at the cell centroid.
    public var wallDistance: Double
    /// STAR's Prism Layer Near Wall Thickness: the whole first cell, 2 y.
    public var firstCell: Double
    /// The flat-plate boundary layer δ = 0.37 L Re^-0.2.
    public var boundaryLayer: Double
    /// The total before the clearance cap: δ when resolved, the layer sum with wall functions.
    public var uncappedTotal: Double
    /// STAR's Prism Layer Total Thickness: the uncapped total, at most a third of the clearance.
    public var total: Double
    /// True when the clearance cap cut the total.
    public var capped: Bool
    /// STAR's Number of Prism Layers.
    public var layers: Int
    public var stretching: Double
    /// y+ at the first cell's centroid, from the near wall thickness as printed.
    public var achievedYPlus: Double
    public var warnings: [Warning]

    /// - Parameters:
    ///   - length: the reference length the boundary layer grows along, in metres.
    ///   - layers: the layer count with wall functions, 2 to 6; ignored when resolved.
    ///   - clearance: the nearest gap to another wall, in metres; nil when there is none.
    public init?(velocity: Double, density: Double, yPlus: Double, viscosity: Double = 1.81e-5,
                 length: Double, treatment: WallTreatment = .resolved, layers wallFunctionLayers: Int = 4,
                 clearance: Double? = nil, stretching: Double = 1.2) {
        guard velocity > 0, density > 0, yPlus > 0, viscosity > 0, length > 0, stretching > 1, clearance ?? 1 > 0,
              treatment == .resolved || (2...6).contains(wallFunctionLayers) else { return nil }
        self.treatment = treatment
        self.stretching = stretching
        reynolds = density * velocity * length / viscosity
        let cf = 0.026 / pow(reynolds, 1.0 / 7)
        frictionVelocity = velocity * (cf / 2).squareRoot()
        wallDistance = yPlus * viscosity / (density * frictionVelocity)
        let h1 = 2 * wallDistance
        firstCell = h1
        boundaryLayer = 0.37 * length * pow(reynolds, -0.2)
        let sum = { (n: Int) in h1 * (pow(stretching, Double(n)) - 1) / (stretching - 1) }
        uncappedTotal = treatment == .resolved ? boundaryLayer : sum(wallFunctionLayers)
        // Both walls grow prisms into the gap, and the core cells need the middle third.
        let cap = clearance.map { $0 / 3 } ?? .infinity
        capped = uncappedTotal > cap
        let total = min(uncappedTotal, cap)
        self.total = total
        switch treatment {
        case .resolved:
            layers = max(1, Int(ceil(log(1 + total * (stretching - 1) / h1) / log(stretching))))
        case .wallFunctions:
            // Under the cap the layers can't be thicker than the first, so drop the ones that don't fit.
            layers = capped ? max(1, min(wallFunctionLayers, Int(total / h1))) : wallFunctionLayers
        }
        let printed = Double(millimetres(h1))! / 1000
        achievedYPlus = printed / 2 * density * frictionVelocity / viscosity

        warnings = []
        if treatment == .resolved, clearance == nil { warnings.append(.noClearance) }
        if treatment == .wallFunctions, total > 0.010 { warnings.append(.thickStack) }
        if stretching > 1.3 { warnings.append(.steepStretching) }
        let band = treatment == .resolved ? 0.5...5 : 30...100
        if !band.contains(achievedYPlus) { warnings.append(.yPlusOutOfRange) }
        if h1 < 5e-6 { warnings.append(.thinFirstCell) }
    }

    /// The lines to paste into STAR 2606's custom prism control, in mm, with
    /// what STAR doesn't take (it has no stretching field there) as a comment.
    public var starLines: String {
        """
        Number of Prism Layers\t\(layers)
        Prism Layer Total Thickness\t\(millimetres(total)) mm
        Prism Layer Near Wall Thickness\t\(millimetres(firstCell)) mm
        // stretching \(stretching.formatted(.number.precision(.significantDigits(1...3)))), \
        achieved y+ \(achievedYPlus.formatted(.number.precision(.significantDigits(1...3)))), \
        Re \(reynolds.formatted(.number.notation(.scientific).precision(.significantDigits(3))))
        """
    }
}

/// Metres as mm to four significant figures, plain digits with no grouping, so it pastes as a number
public func millimetres(_ metres: Double) -> String {
    String(format: "%.4g", metres * 1000)
}
