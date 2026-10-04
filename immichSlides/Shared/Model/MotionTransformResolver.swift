import CoreGraphics
import Foundation
import CryptoKit

enum MotionTransformResolver {
    nonisolated static func resolve(
        _ input: MotionTransformInput,
        policy: MotionTransformPolicy = .v1Default
    ) -> MotionTransform {
        let phaseAction = input.progressFrame.identity.renderRole.phaseAction(
            progress: input.progressFrame.progress
        )
        // Reduce Motion freezes active-time; a transform that has started keeps sampling the frozen value so it does
        // not jump back to identity.

        guard input.isMotionEnabled,
            input.renderGeometry.isRenderable,
            !isIdentityPhaseAction(phaseAction)
        else {
            return .identity
        }

        let seed = stableSeed(input).hash
        let zoomsIn = seed.isMultiple(of: 2)
        let startScale = zoomsIn ? policy.minimumScale : policy.maximumScale
        let endScale = zoomsIn ? policy.maximumScale : policy.minimumScale
        let progress = input.progressFrame.progress
        let scale = startScale + (endScale - startScale) * progress
        let focal = MotionTransformGeometry.focalPoint(input)
        let requestedTranslation = MotionTransformGeometry.requestedTranslationInSlot(
            focalPointInSlot: focal.pointInSlot,
            slotSize: input.renderGeometry.slotSize,
            maxFraction: policy.panFractionOfSlot,
            seed: seed
        )
        let endTranslation = MotionTransformGeometry.clampedTranslationInSlot(
            requested: requestedTranslation,
            scale: CGFloat(endScale),
            anchorUnitPointInSlot: focal.anchorUnitPointInSlot,
            renderGeometry: input.renderGeometry
        )
        let translation = coverageSafeTranslation(
            legacyEndTranslation: endTranslation,
            startScale: startScale,
            endScale: endScale,
            progress: progress,
            maximumCoverageProgress: input.maximumCoverageProgress,
            anchorUnitPointInSlot: focal.anchorUnitPointInSlot,
            renderGeometry: input.renderGeometry
        )

        return MotionTransform(
            scale: scale,
            translationInSlot: translation,
            anchorUnitPointInSlot: focal.anchorUnitPointInSlot,
            applicationSpace: .slotSizedClippedContainer,
            phaseAction: phaseAction,
            focalSource: focal.source
        )
    }

    nonisolated static func diagnostics(
        _ input: MotionTransformInput,
        policy: MotionTransformPolicy = .v1Default
    ) -> MotionTransformDiagnostics {
        let seed = stableSeed(input)
        let zoomsIn = seed.hash.isMultiple(of: 2)
        let endScale = zoomsIn ? policy.maximumScale : policy.minimumScale
        let focal = MotionTransformGeometry.focalPoint(input)
        let requestedTranslation = MotionTransformGeometry.requestedTranslationInSlot(
            focalPointInSlot: focal.pointInSlot,
            slotSize: input.renderGeometry.slotSize,
            maxFraction: policy.panFractionOfSlot,
            seed: seed.hash
        )
        let clampedTranslation = MotionTransformGeometry.clampedTranslationInSlot(
            requested: requestedTranslation,
            scale: CGFloat(endScale),
            anchorUnitPointInSlot: focal.anchorUnitPointInSlot,
            renderGeometry: input.renderGeometry
        )
        return MotionTransformDiagnostics(
            stableSeedHash: seed.hash,
            zoomDirection: zoomsIn ? .zoomIn : .zoomOut,
            seedInputSummary: seed.summary,
            requestedTranslationInSlot: requestedTranslation,
            clampedTranslationInSlot: clampedTranslation,
            endTranslationInSlot: clampedTranslation
        )
    }

    private nonisolated static func coverageSafeTranslation(
        legacyEndTranslation: CGSize,
        startScale: Double,
        endScale: Double,
        progress: Double,
        maximumCoverageProgress: Double,
        anchorUnitPointInSlot: CGPoint,
        renderGeometry: MotionSlotRenderGeometry
    ) -> CGSize {
        guard progress > 1 else {
            return CGSize(
                width: legacyEndTranslation.width * CGFloat(progress),
                height: legacyEndTranslation.height * CGFloat(progress)
            )
        }
        let maximumProgress = maximumCoverageProgress
        guard maximumProgress > 1 else {
            return legacyEndTranslation
        }
        let maximumProgressScale = startScale + (endScale - startScale) * maximumProgress
        let legacyTranslationAtMaximumProgress = CGSize(
            width: legacyEndTranslation.width * CGFloat(maximumProgress),
            height: legacyEndTranslation.height * CGFloat(maximumProgress)
        )
        // p<=1 follows the frozen path; the extension moves linearly to the safe offset at the end of the longest
        // window, with no re-clamping while running.

        let safeTranslationAtMaximumProgress = MotionTransformGeometry.clampedTranslationInSlot(
            requested: legacyTranslationAtMaximumProgress,
            scale: CGFloat(maximumProgressScale),
            anchorUnitPointInSlot: anchorUnitPointInSlot,
            renderGeometry: renderGeometry
        )
        let extensionFraction = (progress - 1) / (maximumProgress - 1)
        return CGSize(
            width: legacyEndTranslation.width + (safeTranslationAtMaximumProgress.width - legacyEndTranslation.width)
                * CGFloat(extensionFraction),
            height: legacyEndTranslation.height
                + (safeTranslationAtMaximumProgress.height - legacyEndTranslation.height) * CGFloat(extensionFraction)
        )
    }

    private nonisolated static func isIdentityPhaseAction(_ phaseAction: MotionPhaseAction) -> Bool {
        switch phaseAction {
        case .identity:
            return true
        case .showStartWithoutAnimation, .animateForwardAndHold:
            return false
        }
    }

    private nonisolated static func stableSeed(_ input: MotionTransformInput) -> MotionStableSeed {
        let identity = input.progressFrame.identity
        let focalRect = input.focalSource.rectInSource
        let focalKey: String
        let focalKeySource: String
        if let focalRect {
            focalKeySource = input.focalSource.kind.v1SeedKey
            focalKey = [
                focalKeySource,
                "\(focalRect.x)",
                "\(focalRect.y)",
                "\(focalRect.width)",
                "\(focalRect.height)"
            ].joined(separator: "|")
        } else {
            focalKeySource = "no-focal"
            focalKey = "no-focal"
        }
        let key = [
            identity.sceneId,
            identity.slotId,
            identity.assetId,
            "\(input.cropRectInSource.x)|\(input.cropRectInSource.y)|\(input.cropRectInSource.width)|\(input.cropRectInSource.height)",
            focalKey
        ].joined(separator: "|")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for scalar in key.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return MotionStableSeed(
            hash: hash,
            summary: [
                "seedContractVersion=ambient-v1-scene-slot-asset-crop-raw-focal-rect",
                "seedHashIncludesSceneId=true",
                "seedFocalKeySource=\(focalKeySource)",
                "sceneId=\(diagnosticIdentityToken(identity.sceneId))",
                "slotId=\(diagnosticIdentityToken(identity.slotId))",
                "assetId=\(diagnosticIdentityToken(identity.assetId))",
                "cropRect=\(input.cropRectInSource.x),\(input.cropRectInSource.y),\(input.cropRectInSource.width),\(input.cropRectInSource.height)",
                "focalKey=\(focalKey)"
            ].joined(separator: "|")
        )
    }

    nonisolated static func diagnosticIdentityToken(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

}

private struct MotionStableSeed {
    let hash: UInt64
    let summary: String
}

private extension MotionFocalSourceKind {
    nonisolated var v1SeedKey: String {
        switch self {
        case .face:
            return "face"
        case .subject:
            return "subject"
        case .person:
            return "person"
        case .soloOnly:
            return "soloOnly"
        case .cropCenterFallback:
            return "cropCenterFallback"
        case .slotCenterFallback:
            return "slotCenterFallback"
        }
    }
}
