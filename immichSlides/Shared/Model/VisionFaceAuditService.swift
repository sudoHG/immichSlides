import Foundation
import SDWebImage
import OSLog
#if canImport(Vision)
import Vision
import UIKit
import ImageIO
import CoreImage
#endif

struct VisionFaceAuditResult {

    let assetId: String

    let faceCount: Int

    let elapsedMilliseconds: Int

    let imageSource: ThumbnailSize

    let imagePixelWidth: Int
    let imagePixelHeight: Int
}

// waitingForImage means a cache miss; the Vision request itself has no cancellation point.
enum VisionFaceAuditState {
    case idle
    case waitingForImage
    case running
    case finished(VisionFaceAuditResult)
    case failed(String)
}

enum VisionFaceAuditService {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "immichSlides",
        category: "VisionAudit"
    )

    #if canImport(Vision)

    private struct ImageCandidate {
        let source: ThumbnailSize
        let url: URL
    }

    static func audit(
        assetId: String,
        candidateURLs: [(ThumbnailSize, URL)]
    ) async -> VisionFaceAuditState {
        let orderedCandidates = candidateURLs.map { pair in
            ImageCandidate(source: pair.0, url: pair.1)
        }

        guard let preparedImage = preparedImageForAudit(from: orderedCandidates) else {
            return .waitingForImage
        }

        return await auditPreparedImage(
            assetId: assetId,
            source: preparedImage.source,
            cgImage: preparedImage.cgImage,
            orientation: preparedImage.orientation
        )
    }

    static func audit(
        assetId: String,
        imageSource: ThumbnailSize,
        image: UIImage
    ) async -> VisionFaceAuditState {
        guard let preparedImage = preparedImage(from: image, source: imageSource) else {
            return .failed("vision-image-unavailable")
        }

        return await auditPreparedImage(
            assetId: assetId,
            source: preparedImage.source,
            cgImage: preparedImage.cgImage,
            orientation: preparedImage.orientation
        )
    }

    private static func auditPreparedImage(
        assetId: String,
        source: ThumbnailSize,
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) async -> VisionFaceAuditState {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let startedAt = CFAbsoluteTimeGetCurrent()

                do {
                    let request = VNDetectFaceRectanglesRequest()
                    let handler = VNImageRequestHandler(
                        cgImage: cgImage,
                        orientation: orientation,
                        options: [:]
                    )
                    try handler.perform([request])

                    let elapsedMilliseconds = Int(
                        ((CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0).rounded()
                    )
                    let result = VisionFaceAuditResult(
                        assetId: assetId,
                        faceCount: request.results?.count ?? 0,
                        elapsedMilliseconds: elapsedMilliseconds,
                        imageSource: source,
                        imagePixelWidth: cgImage.width,
                        imagePixelHeight: cgImage.height
                    )
                    logger.info(
                        "vision audit success assetId=\(assetId, privacy: .private) source=\(source.rawValue, privacy: .public) faceCount=\(result.faceCount, privacy: .private) elapsedMs=\(elapsedMilliseconds, privacy: .public) pixelWidth=\(cgImage.width, privacy: .public) pixelHeight=\(cgImage.height, privacy: .public)"
                    )
                    continuation.resume(returning: .finished(result))
                } catch {
                    let message = Self.shortErrorMessage(from: error)
                    logger.error(
                        "vision audit failed assetId=\(assetId, privacy: .private) source=\(source.rawValue, privacy: .public) error=\(message, privacy: .private)"
                    )
                    continuation.resume(
                        returning: .failed(message)
                    )
                }
            }
        }
    }

    private static func preparedImageForAudit(from candidates: [ImageCandidate]) -> (
        source: ThumbnailSize, cgImage: CGImage, orientation: CGImagePropertyOrientation
    )? {
        for candidate in candidates {
            guard let image = SDImageCache.shared.imageFromCache(forKey: candidate.url.absoluteString) else {
                continue
            }
            guard let preparedImage = preparedImage(from: image, source: candidate.source) else {
                continue
            }
            return preparedImage
        }
        return nil
    }

    private static func preparedImage(
        from image: UIImage,
        source: ThumbnailSize
    ) -> (source: ThumbnailSize, cgImage: CGImage, orientation: CGImagePropertyOrientation)? {
        guard let cgImage = resolvedCGImage(from: image) else {
            return nil
        }

        return (
            source: source,
            cgImage: cgImage,
            orientation: cgImageOrientation(from: image.imageOrientation)
        )
    }

    private static func resolvedCGImage(from image: UIImage) -> CGImage? {
        if let cgImage = image.cgImage {
            return cgImage
        }

        guard let ciImage = image.ciImage else {
            return nil
        }
        let context = CIContext(options: nil)
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    private static func cgImageOrientation(from orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up:
            return .up
        case .down:
            return .down
        case .left:
            return .left
        case .right:
            return .right
        case .upMirrored:
            return .upMirrored
        case .downMirrored:
            return .downMirrored
        case .leftMirrored:
            return .leftMirrored
        case .rightMirrored:
            return .rightMirrored
        @unknown default:
            return .up
        }
    }

    private static func shortErrorMessage(from error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "vision-failed" : message
    }
    #else
    static func audit(
        assetId: String,
        candidateURLs: [(ThumbnailSize, URL)]
    ) async -> VisionFaceAuditState {
        let _ = assetId
        let _ = candidateURLs
        return .failed("vision-unavailable")
    }
    #endif
}
