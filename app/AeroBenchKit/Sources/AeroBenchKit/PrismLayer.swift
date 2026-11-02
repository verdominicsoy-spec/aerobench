import Foundation

/// A prism layer sized from the free stream, with the same flat-plate
/// estimates the engine meshes Wing Lab's RANS runs with (wing/mesh.py):
/// Schlichting's Cf = 0.026 Re^-1/7 for the wall distance and
/// 0.37 L Re^-0.2 for the turbulent boundary layer the layers must hold.
public struct PrismLayer: Equatable, Sendable {
    public var reynolds: Double
    /// Wall to where y+ is read: the first node in SU2, the first cell's centre in STAR.
    public var wallDistance: Double
    /// STAR's near-wall thickness: the whole first cell, twice the wall
    /// distance, since STAR is cell-centred.
    public var firstCell: Double
    /// STAR's absolute total thickness: the boundary layer at the reference length.
    public var total: Double
    /// Layers from the first cell to the total at the given stretching.
    public var layers: Int

    public init?(velocity: Double, density: Double, yPlus: Double, viscosity: Double = 1.81e-5,
                 length: Double = 1, stretching: Double = 1.2) {
        guard velocity > 0, density > 0, yPlus > 0, viscosity > 0, length > 0, stretching > 1 else { return nil }
        reynolds = density * velocity * length / viscosity
        let cf = 0.026 / pow(reynolds, 1.0 / 7)
        wallDistance = yPlus * viscosity / (density * velocity * (cf / 2).squareRoot())
        firstCell = 2 * wallDistance
        total = 0.37 * length * pow(reynolds, -0.2)
        layers = max(1, Int(ceil(log(1 + total * (stretching - 1) / firstCell) / log(stretching))))
    }
}
