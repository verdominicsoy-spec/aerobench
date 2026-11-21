@preconcurrency import AVFoundation
import Observation
import QuartzCore
import Vision

/// The built-in webcam and Vision face landmarks: one HeadGeometry.Sample per
/// camera frame (nil when no face is found), delivered on the main actor.
@MainActor @Observable
public final class HeadTracker {
    public enum Status: Equatable, Sendable { case off, needsPermission, denied, noCamera, starting, running }

    public private(set) var status: Status = .off
    /// Main actor, once per camera frame; nil = no face this frame.
    @ObservationIgnored public var onSample: ((HeadGeometry.Sample?) -> Void)?
    /// Width / height of the frames.
    public private(set) var imageAspect = 16.0 / 9
    /// Whether frames arrive mirrored (then your right is the image's right).
    public private(set) var mirrored = false

    @ObservationIgnored private let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "dev.aerobench.head-tracker")
    @ObservationIgnored private var reader: FrameReader?

    public init() {
        status = Self.permissionStatus ?? .off
    }

    /// nil when access is granted; otherwise the status that explains why not.
    private static var permissionStatus: Status? {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: nil
        case .notDetermined: .needsPermission
        default: .denied
        }
    }

    public func requestAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        if status != .running && status != .starting { status = granted ? .off : .denied }
        return granted
    }

    public func start() {
        if let blocked = Self.permissionStatus {
            status = blocked
            return
        }
        guard status != .running, status != .starting else { return }
        if reader == nil, !configure() {
            status = .noCamera
            return
        }
        status = .starting
        queue.async { [session] in
            session.startRunning()
            let running = session.isRunning
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.status == .starting else { return }
                    self.status = running ? .running : .noCamera
                }
            }
        }
    }

    public func stop() {
        guard status == .running || status == .starting else { return }
        status = .off
        queue.async { [session] in session.stopRunning() }
    }

    /// The Mac's own camera, not an iPhone (Continuity) or a USB camera:
    /// the layout assumes it sits at the top centre of the built-in display.
    private func configure() -> Bool {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video,
                                                       position: .unspecified).devices
        guard let device = devices.first, let input = try? AVCaptureDeviceInput(device: device) else { return false }
        // Center Stage crops and pans the frame, which would move the head estimate.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        let reader = FrameReader { [weak self] sample, aspect in
            guard let self else { return }
            self.imageAspect = aspect
            self.onSample?(sample)
        }
        output.setSampleBufferDelegate(reader, queue: queue)

        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        mirrored = output.connection(with: .video)?.isVideoMirrored ?? false
        self.reader = reader
        return true
    }
}

/// Runs on the capture queue: finds the largest face and its eyes.
private final class FrameReader: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let deliver: @MainActor (HeadGeometry.Sample?, Double) -> Void

    init(deliver: @escaping @MainActor (HeadGeometry.Sample?, Double) -> Void) {
        self.deliver = deliver
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
        let face = request.results?.max { area($0.boundingBox) < area($1.boundingBox) }
        let sample = face.flatMap { Self.sample($0, size: size, time: CACurrentMediaTime()) }
        let aspect = Double(size.width / max(size.height, 1))
        let deliver = deliver
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(sample, aspect) } }
    }

    private func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    /// Pupils when Vision finds them, else the centres of the eye contours.
    private static func sample(_ face: VNFaceObservation, size: CGSize, time: TimeInterval) -> HeadGeometry.Sample? {
        guard let marks = face.landmarks else { return nil }
        func centre(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let points = region?.pointsInImage(imageSize: size), !points.isEmpty else { return nil }
            let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
        }
        guard let left = centre(marks.leftPupil) ?? centre(marks.leftEye),
              let right = centre(marks.rightPupil) ?? centre(marks.rightEye) else { return nil }
        let mid = SIMD2(Double((left.x + right.x) / 2 / size.width), Double((left.y + right.y) / 2 / size.height))
        let separation = Double(hypot(left.x - right.x, left.y - right.y) / size.width)
        let angle = HeadGeometry.eyeAngle(SIMD2(Double(left.x), Double(left.y)), SIMD2(Double(right.x), Double(right.y)))
        return HeadGeometry.Sample(eyeMid: mid, separation: separation, eyeAngle: angle, time: time)
    }
}
