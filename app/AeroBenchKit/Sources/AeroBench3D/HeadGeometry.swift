import CoreGraphics
import Foundation
import simd

/// Where the viewer's head is, from the webcam: the physical layout of the
/// view on the glass, the head position at a locked distance, and the
/// webcam's field of view from a one-time calibration. Pure maths.
public enum HeadGeometry {
    /// Average adult interpupillary distance.
    public static let ipdCM = 6.3
    /// The built-in webcam sits just above the top edge of the display.
    public static let cameraAboveGlassCM = 0.8

    /// The view on the glass and the webcam relative to the view's centre, in cm (x right, y up).
    public struct Layout: Equatable, Sendable {
        public var viewWidthCM: Double
        public var viewHeightCM: Double
        public var cameraCM: SIMD2<Double>
    }

    /// viewRect and screenFrame in AppKit screen points (y up); screenSizeMM from CGDisplayScreenSize.
    public static func layout(viewRect: CGRect, screenFrame: CGRect, screenSizeMM: CGSize) -> Layout {
        let k = Double(screenSizeMM.width) / 10 / max(Double(screenFrame.width), 1)  // cm per point
        return Layout(
            viewWidthCM: Double(viewRect.width) * k,
            viewHeightCM: Double(viewRect.height) * k,
            cameraCM: SIMD2(Double(screenFrame.midX - viewRect.midX) * k,
                            Double(screenFrame.maxY - viewRect.midY) * k + cameraAboveGlassCM))
    }

    /// One face seen by the webcam.
    public struct Sample: Sendable {
        /// Eye midpoint in normalised image coordinates as Vision gives them (origin bottom left).
        public var eyeMid: SIMD2<Double>
        /// Distance between the eyes as a fraction of the image width.
        public var separation: Double
        public var time: TimeInterval

        public init(eyeMid: SIMD2<Double>, separation: Double, time: TimeInterval) {
            self.eyeMid = eyeMid
            self.separation = separation
            self.time = time
        }
    }

    /// Head (eye) position in cm relative to the view centre: x right, y up,
    /// z = distanceCM. The distance is locked: estimating it from the eye
    /// separation swung by ±8 cm and made the view stretch (spike, 2026-11-20).
    public static func head(_ s: Sample, hfov: Double, imageAspect: Double, distanceCM: Double,
                            layout: Layout, mirrored: Bool) -> SIMD3<Double>
    {
        let tanH = tan(hfov / 2), tanV = tanH / imageAspect
        // The webcam faces you: your right is the image's left, unless the frames are mirrored.
        let u = mirrored ? s.eyeMid.x - 0.5 : 0.5 - s.eyeMid.x
        return SIMD3(layout.cameraCM.x + u * 2 * tanH * distanceCM,
                     layout.cameraCM.y + (s.eyeMid.y - 0.5) * 2 * tanV * distanceCM,
                     distanceCM)
    }

    /// The webcam's horizontal field of view (radians) that makes the median
    /// eye separation mean `distanceCM`. nil without a usable separation.
    public static func calibratedHFOV(separations: [Double], distanceCM: Double) -> Double? {
        let valid = separations.filter { $0 > 0 }.sorted()
        guard !valid.isEmpty, distanceCM > 0 else { return nil }
        let median = valid[valid.count / 2]
        return 2 * atan(ipdCM / (median * 2 * distanceCM))
    }
}
