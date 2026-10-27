import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Random access to the frames of a video or a folder of images.
final class FrameGrabber: @unchecked Sendable {
    let url: URL
    let frameCount: Int
    let fps: Double
    let size: CGSize
    private let generator: AVAssetImageGenerator?
    private let images: [URL]

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "bmp"]

    init(url: URL) async throws {
        self.url = url
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard let first = files.first, let image = Self.loadImage(first) else {
                throw FlowError.source("No readable images in \(url.lastPathComponent).")
            }
            images = files
            generator = nil
            frameCount = files.count
            fps = 30
            size = CGSize(width: image.width, height: image.height)
        } else {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw FlowError.source("\(url.lastPathComponent) has no video track.")
            }
            let duration = try await asset.load(.duration)
            let rate = Double(try await track.load(.nominalFrameRate))
            let natural = try await track.load(.naturalSize)
            fps = rate > 0 ? rate : 30
            frameCount = max(Int((duration.seconds * fps).rounded()), 1)
            size = natural
            let g = AVAssetImageGenerator(asset: asset)
            g.requestedTimeToleranceBefore = .zero
            g.requestedTimeToleranceAfter = .zero
            g.appliesPreferredTrackTransform = true
            generator = g
            images = []
        }
    }

    func image(at index: Int) async throws -> CGImage {
        let i = min(max(index, 0), frameCount - 1)
        if let generator {
            // The middle of frame i, so a zero-tolerance request lands on it.
            let time = CMTime(seconds: (Double(i) + 0.5) / fps, preferredTimescale: 60_000)
            return try await generator.image(at: time).image
        }
        guard let image = Self.loadImage(images[i]) else { throw FlowError.source("Could not read \(images[i].lastPathComponent).") }
        return image
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

enum FlowError: LocalizedError {
    case source(String)

    var errorDescription: String? {
        switch self {
        case .source(let message): message
        }
    }
}

extension CGImage {
    /// RGB of one pixel, 0...255, x and y from the top left.
    func pixelRGB(x: Int, y: Int) -> [Double]? {
        guard x >= 0, y >= 0, x < width, y < height,
              let one = cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let drew: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drew ? [Double(px[0]), Double(px[1]), Double(px[2])] : nil
    }
}
