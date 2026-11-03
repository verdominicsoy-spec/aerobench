import Foundation

/// A prism layer sized from the free stream, with the same flat-plate
/// estimates the engine meshes Wing Lab's RANS runs with (wing/mesh.py):
/// Schlichting's Cf = 0.026 Re^-1/7 for the wall distance and
/// 0.37 L Re^-0.2 for the turbulent boundary layer. Gives the three values
/// STAR 2606's custom prism control takes in near wall thickness mode.
public struct PrismLayer: Equatable, Sendable {
    /// Which maths sizes the stack, set by the target y+
    public enum WallTreatment: String, CaseIterable, Sendable {
        /// y+ up to 1 (up to 5 in the buffer band): the stack holds the whole boundary layer
        case resolved
        /// y+ 30 to 100 (and above 5 in the buffer band): a few layers, sized by count and stretching, not by δ
        case wallFunctions

        public init(yPlus: Double) { self = yPlus <= 1 || (yPlus < 30 && yPlus <= 5) ? .resolved : .wallFunctions }
    }

    /// Something in the stack that will hurt the mesh or the solve
    public enum Warning: Equatable, Sendable {
        /// Resolved with no clearance: the total is the full boundary layer
        case noClearance
        /// Wall functions with a total over 10 mm
        case thickStack
        /// Stretching over 1.3
        case steepStretching
        /// y+ between 1 and 30: the first cell lands in the buffer layer
        case bufferLayer
        /// y+ over 100: the first cell is too far from the wall for wall functions
        case tooFar
        /// Wall functions under the gap cap: fewer layers than asked for fit
        case layersDropped
        /// Not even the near wall cell fits in a third of the gap
        case gapTooSmall
        /// The first cell's centroid sits past a fifth of δ: the part is too small for this y+
        case smallPart
        /// Over 40 layers, usually a stretching typo
        case manyLayers
        /// A reference length over 10 m, usually millimetres typed into the metres box
        case unlikelyLength
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
    /// STAR's Prism Layer Total Thickness: the uncapped total, or under the gap cap a third
    /// of the clearance (resolved) or the sum of the layers that fit (wall functions).
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
    ///   - yPlus: the target y+, which also picks the wall treatment.
    ///   - layers: the layer count with wall functions, 2 to 6; ignored when resolved.
    ///   - clearance: the nearest gap to another wall, in metres; nil when there is none.
    public init?(velocity: Double, density: Double, yPlus: Double, viscosity: Double = 1.81e-5,
                 length: Double, layers wallFunctionLayers: Int = 4,
                 clearance: Double? = nil, stretching: Double = 1.2) {
        let treatment = WallTreatment(yPlus: yPlus)
        // Finite as well as positive: an infinity saved in the settings would trap on every open.
        guard [velocity, density, yPlus, viscosity, length, stretching, clearance ?? 1].allSatisfy({ $0.isFinite && $0 > 0 }),
              stretching > 1, treatment == .resolved || (2...6).contains(wallFunctionLayers) else { return nil }
        self.treatment = treatment
        self.stretching = stretching
        reynolds = density * velocity * length / viscosity
        let cf = 0.026 / pow(reynolds, 1.0 / 7)
        frictionVelocity = velocity * (cf / 2).squareRoot()
        wallDistance = yPlus * viscosity / (density * frictionVelocity)
        let h1 = 2 * wallDistance
        firstCell = h1
        boundaryLayer = 0.37 * length * pow(reynolds, -0.2)
        guard h1.isFinite, h1 > 0, boundaryLayer.isFinite, boundaryLayer > 0 else { return nil }
        let sum = { (n: Int) in h1 * (pow(stretching, Double(n)) - 1) / (stretching - 1) }
        uncappedTotal = treatment == .resolved ? boundaryLayer : sum(wallFunctionLayers)
        // Both walls grow prisms into the gap, and the core cells need the middle third.
        let cap = clearance.map { $0 / 3 } ?? .infinity
        capped = uncappedTotal > cap
        switch treatment {
        case .resolved:
            total = min(uncappedTotal, cap)
            layers = max(1, Int(ceil(log(1 + total * (stretching - 1) / h1) / log(stretching))))
        case .wallFunctions:
            // Under the cap, keep the most layers whose sum still fits, at the same stretching.
            var n = wallFunctionLayers
            while capped, n > 1, sum(n) > cap { n -= 1 }
            layers = n
            total = sum(n)
        }
        guard total.isFinite else { return nil }
        let printed = Double(millimetres(h1))! / 1000
        achievedYPlus = printed / 2 * density * frictionVelocity / viscosity

        warnings = []
        if treatment == .resolved, clearance == nil { warnings.append(.noClearance) }
        if treatment == .wallFunctions, total > 0.010 { warnings.append(.thickStack) }
        if stretching > 1.3 { warnings.append(.steepStretching) }
        if yPlus > 1, yPlus < 30 { warnings.append(.bufferLayer) }
        if yPlus > 100 { warnings.append(.tooFar) }
        if h1 > cap {
            warnings.append(.gapTooSmall)
        } else if layers < wallFunctionLayers, treatment == .wallFunctions {
            warnings.append(.layersDropped)
        }
        if wallDistance > 0.2 * boundaryLayer { warnings.append(.smallPart) }
        if layers > 40 { warnings.append(.manyLayers) }
        if length > 10 { warnings.append(.unlikelyLength) }
        if h1 < 5e-6 { warnings.append(.thinFirstCell) }
    }
}

/// Metres as mm to four significant figures, plain digits with no grouping, so it pastes as a number
public func millimetres(_ metres: Double) -> String {
    String(format: "%.4g", metres * 1000)
}
