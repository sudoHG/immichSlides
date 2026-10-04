import CoreGraphics
import Foundation

enum MotionTransformGeometry {
    private nonisolated static let geometryTolerancePoints: CGFloat = 0.000_1
    private nonisolated static let sideDriftFraction: Double = 0.3
    private nonisolated static let sideDriftSeedOffset: UInt64 = 0x9E37_79B9_7F4A_7C15
    private nonisolated static let fractionSamplingModulus: UInt64 = 10_000
    private nonisolated static let fractionSamplingScale: Double = 10_000
    nonisolated static func focalPoint(
        _ input: MotionTransformInput
    ) -> (pointInSlot: CGPoint, anchorUnitPointInSlot: CGPoint, source: MotionFocalSourceKind) {
        let geometry = input.renderGeometry
        switch input.focalSource.kind {
        case .slotCenterFallback:
            let center = CGPoint(x: geometry.slotSize.width * 0.5, y: geometry.slotSize.height * 0.5)
            return (center, CGPoint(x: 0.5, y: 0.5), .slotCenterFallback)
        case .cropCenterFallback:
            if let cropCenter = input.cropRectInSource.validCenter {
                let point = pointInSlot(sourcePoint: cropCenter, imageFrameInSlot: geometry.imageFrameInSlot)
                return (point, normalizedSlotPoint(point, slotSize: geometry.slotSize), .cropCenterFallback)
            }
        case .face, .subject, .person, .soloOnly:
            break
        }
        if let sourcePoint = input.focalSource.centerInSource {
            let point = pointInSlot(sourcePoint: sourcePoint, imageFrameInSlot: geometry.imageFrameInSlot)
            return (point, normalizedSlotPoint(point, slotSize: geometry.slotSize), input.focalSource.kind)
        }
        if let cropCenter = input.cropRectInSource.validCenter {
            let point = pointInSlot(sourcePoint: cropCenter, imageFrameInSlot: geometry.imageFrameInSlot)
            return (point, normalizedSlotPoint(point, slotSize: geometry.slotSize), .cropCenterFallback)
        }
        let center = CGPoint(x: geometry.slotSize.width * 0.5, y: geometry.slotSize.height * 0.5)
        return (center, CGPoint(x: 0.5, y: 0.5), .slotCenterFallback)
    }

    nonisolated static func requestedTranslationInSlot(
        focalPointInSlot: CGPoint,
        slotSize: CGSize,
        maxFraction: CGFloat,
        seed: UInt64
    ) -> CGSize {
        let maxX = slotSize.width * maxFraction
        let maxY = slotSize.height * maxFraction
        let center = CGPoint(x: slotSize.width * 0.5, y: slotSize.height * 0.5)
        var dx = clamped(center.x - focalPointInSlot.x, minimum: -maxX, maximum: maxX)
        var dy = clamped(center.y - focalPointInSlot.y, minimum: -maxY, maximum: maxY)
        if abs(dx) < geometryTolerancePoints && abs(dy) < geometryTolerancePoints {
            let sideDrift = CGFloat((fraction(seed &+ sideDriftSeedOffset) - 0.5) * sideDriftFraction)
            dx = maxX * sideDrift
            dy = maxY * -sideDrift
        }
        return CGSize(width: dx, height: dy)
    }

    nonisolated static func clampedTranslationInSlot(
        requested: CGSize,
        scale: CGFloat,
        anchorUnitPointInSlot: CGPoint,
        renderGeometry: MotionSlotRenderGeometry
    ) -> CGSize {
        let slotSize = renderGeometry.slotSize
        let imageFrameInSlot = renderGeometry.imageFrameInSlot
        let anchor = CGPoint(
            x: slotSize.width * anchorUnitPointInSlot.x,
            y: slotSize.height * anchorUnitPointInSlot.y
        )
        let minXNoTranslation = anchor.x + (imageFrameInSlot.minX - anchor.x) * scale
        let maxXNoTranslation = anchor.x + (imageFrameInSlot.maxX - anchor.x) * scale
        let minYNoTranslation = anchor.y + (imageFrameInSlot.minY - anchor.y) * scale
        let maxYNoTranslation = anchor.y + (imageFrameInSlot.maxY - anchor.y) * scale
        return CGSize(
            width: nonReversingClamp(
                requested.width,
                allowed: (slotSize.width - maxXNoTranslation, -minXNoTranslation)
            ),
            height: nonReversingClamp(
                requested.height,
                allowed: (slotSize.height - maxYNoTranslation, -minYNoTranslation)
            )
        )
    }

    nonisolated static func coversSlot(
        _ transform: MotionTransform,
        renderGeometry: MotionSlotRenderGeometry
    ) -> Bool {
        guard renderGeometry.isRenderable else {
            return transform.isIdentity
        }
        let frame = transformedImageFrameInSlot(transform, renderGeometry: renderGeometry)
        return frame.minX <= geometryTolerancePoints && frame.minY <= geometryTolerancePoints
            && frame.maxX >= renderGeometry.slotSize.width - geometryTolerancePoints
            && frame.maxY >= renderGeometry.slotSize.height - geometryTolerancePoints
    }

    nonisolated static func transformedImageFrameInSlot(
        _ transform: MotionTransform,
        renderGeometry: MotionSlotRenderGeometry
    ) -> CGRect {
        let slotSize = renderGeometry.slotSize
        let imageFrameInSlot = renderGeometry.imageFrameInSlot
        let anchor = CGPoint(
            x: slotSize.width * transform.anchorUnitPointInSlot.x,
            y: slotSize.height * transform.anchorUnitPointInSlot.y
        )
        let minX =
            anchor.x + (imageFrameInSlot.minX - anchor.x) * CGFloat(transform.scale) + transform.translationInSlot.width
        let minY =
            anchor.y + (imageFrameInSlot.minY - anchor.y) * CGFloat(transform.scale)
            + transform.translationInSlot.height
        let maxX =
            anchor.x + (imageFrameInSlot.maxX - anchor.x) * CGFloat(transform.scale) + transform.translationInSlot.width
        let maxY =
            anchor.y + (imageFrameInSlot.maxY - anchor.y) * CGFloat(transform.scale)
            + transform.translationInSlot.height
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private nonisolated static func nonReversingClamp(
        _ value: CGFloat,
        allowed: (minimum: CGFloat, maximum: CGFloat)
    ) -> CGFloat {
        guard allowed.minimum <= allowed.maximum else { return 0 }
        let clampedValue = clamped(value, minimum: allowed.minimum, maximum: allowed.maximum)
        if value > 0, clampedValue < 0, allowed.minimum <= 0, allowed.maximum >= 0 {
            return 0
        }
        if value < 0, clampedValue > 0, allowed.minimum <= 0, allowed.maximum >= 0 {
            return 0
        }
        return clampedValue
    }

    private nonisolated static func pointInSlot(
        sourcePoint: CGPoint,
        imageFrameInSlot: CGRect
    ) -> CGPoint {
        CGPoint(
            x: imageFrameInSlot.minX + sourcePoint.x * imageFrameInSlot.width,
            y: imageFrameInSlot.minY + sourcePoint.y * imageFrameInSlot.height
        )
    }

    private nonisolated static func normalizedSlotPoint(
        _ point: CGPoint,
        slotSize: CGSize
    ) -> CGPoint {
        guard slotSize.width > 0, slotSize.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return CGPoint(
            x: clamped(point.x / slotSize.width, minimum: 0, maximum: 1),
            y: clamped(point.y / slotSize.height, minimum: 0, maximum: 1)
        )
    }

    private nonisolated static func fraction(_ seed: UInt64) -> Double {
        Double(seed % fractionSamplingModulus) / fractionSamplingScale
    }

    private nonisolated static func clamped(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        Swift.max(minimum, Swift.min(maximum, value))
    }
}
