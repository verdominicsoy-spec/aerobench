import Foundation

/// A prism layer sized from the free stream, with the same flat-plate
/// estimates the engine meshes Wing Lab's RANS runs with (wing/mesh.py):
/// Schlichting's Cf = 0.026 Re^-1/7 for the wall distance and
/// 0.37 c Re^-0.2 for the turbulent boundary layer the layers must hold.
/// Gives STAR's prism layer mesher settings: STAR thins the layer only in a
/// slot (gap fill), so the total is not capped by the slot as it is in the
/// engine's gmsh meshes.
public struct PrismLayer: Equatable, Sendable {
    public var reynolds: Double
    /// Wall to where y+ is read: the first node in SU2, the first cell's centre in STAR.
    public var wallDistance: Double
    /// STAR's Prism Layer Near Wall Thickness: the whole first cell, twice
    /// the wall distance, since STAR is cell-centred.
    public var firstCell: Double
    /// STAR's Prism Layer Total Thickness (absolute): the boundary layer at the chord's trailing edge.
    public var total: Double
    /// STAR's Number of Prism Layers: from the first cell to the total at the given stretching.
    public var layers: Int
    /// STAR's Gap Fill Percentage, the prism share of the slot on each side:
    /// STAR's 25 by default, up to 40 (the engine's max_layer_fraction_of_gap)
    /// to fit the whole layer in the slot.
    public var gapFillPercentage: Double
    /// The layer's thickness in the slot as a share of the total, 1 when it fits.
    public var slotShare: Double
    /// STAR's Prism Layer Reduction Percentage: below the slot share, so no
    /// layer is dropped in the slot (STAR removes layers where the local
    /// thickness falls under this share of the total). 50, STAR's default, when nothing thins.
    public var reductionPercentage: Double
    /// STAR's Minimum Thickness Percentage: under the reduction percentage,
    /// so the layer never collapses; 10, STAR's default, when nothing thins.
    public var minimumThicknessPercentage: Double

    public init?(velocity: Double, density: Double, yPlus: Double, viscosity: Double = 1.81e-5,
                 chord: Double, slotGap: Double? = nil, stretching: Double = 1.2) {
        guard velocity > 0, density > 0, yPlus > 0, viscosity > 0, chord > 0, stretching > 1, slotGap ?? 1 > 0 else { return nil }
        reynolds = density * velocity * chord / viscosity
        let cf = 0.026 / pow(reynolds, 1.0 / 7)
        wallDistance = yPlus * viscosity / (density * velocity * (cf / 2).squareRoot())
        firstCell = 2 * wallDistance
        total = 0.37 * chord * pow(reynolds, -0.2)
        layers = max(1, Int(ceil(log(1 + total * (stretching - 1) / firstCell) / log(stretching))))
        if let slotGap {
            gapFillPercentage = min(40, max(25, (100 * total / slotGap).rounded(.up)))
            slotShare = min(1, gapFillPercentage / 100 * slotGap / total)
        } else {
            gapFillPercentage = 25
            slotShare = 1
        }
        // A fifth below the slot share, so rounding in STAR's own gap measure does not cost a layer.
        reductionPercentage = min(50, (80 * slotShare).rounded(.down))
        minimumThicknessPercentage = max(1, min(10, (reductionPercentage / 2).rounded(.down)))
    }
}
