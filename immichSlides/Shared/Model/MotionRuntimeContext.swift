import CoreGraphics
import Foundation

struct MotionRuntimeContext: Equatable, Sendable {
    let sceneId: String
    let renderRole: MotionRenderRole
    let lifecycle: SceneLifecycleContract
    let motionActiveTime: TimeInterval
    let isMotionEnabled: Bool
    let isReduceMotionEnabled: Bool

    nonisolated var rawProgress: Double {
        SceneAnimationProfile(lifecycle: lifecycle).rawProgress(for: motionActiveTime)
    }

    /// The longest visible window of the same frozen scene sets the coverage endpoint; it must not fall back to the
    /// old waypoint constant.
    nonisolated var maximumCoverageProgress: Double {
        SceneAnimationProfile(lifecycle: lifecycle).rawProgress(
            for: lifecycle.longestVisibleMotionDuration
        )
    }

    nonisolated func progressFrame(
        slotId: String,
        assetId: String
    ) -> MotionRenderProgressFrame {
        MotionRenderProgressFrame.fromSceneActiveTime(
            identity: MotionFrameIdentity(
                sceneId: sceneId,
                slotId: slotId,
                assetId: assetId,
                renderRole: renderRole,
                clockGeneration: 0
            ),
            rawProgress: rawProgress
        )
    }
}

struct SmartFillMotionSlotFrameInput: Equatable, Sendable {
    let motionContext: MotionRuntimeContext?
    let slotId: String
    let assetId: String
    let renderGeometry: MotionSlotRenderGeometry
    let cropRectInSource: MotionUnitRect
    let focalSource: MotionFocalSource

    nonisolated init(
        motionContext: MotionRuntimeContext?,
        slotId: String,
        assetId: String,
        renderGeometry: MotionSlotRenderGeometry,
        cropRectInSource: MotionUnitRect,
        focalSource: MotionFocalSource
    ) {
        self.motionContext = motionContext
        self.slotId = slotId
        self.assetId = assetId
        self.renderGeometry = renderGeometry
        self.cropRectInSource = cropRectInSource
        self.focalSource = focalSource
    }
}

struct SmartFillMotionRenderedSlotFrame: Equatable, Sendable {
    let progressFrame: MotionRenderProgressFrame?
    let transform: MotionTransform
    let diagnostics: MotionTransformDiagnostics?
    let imageFrame: CGRect
    let missingProgressReason: String?

    nonisolated var resolvedProgress: Double {
        progressFrame?.progress ?? 0
    }
}

enum SmartFillMotionSlotFrameResolver {
    nonisolated static func resolve(
        _ input: SmartFillMotionSlotFrameInput
    ) -> SmartFillMotionRenderedSlotFrame {
        guard let motionContext = input.motionContext else {
            return SmartFillMotionRenderedSlotFrame(
                progressFrame: nil,
                transform: .identity,
                diagnostics: nil,
                imageFrame: input.renderGeometry.imageFrameInSlot,
                missingProgressReason: "motionContextMissing"
            )
        }

        let baseProgressFrame = motionContext.progressFrame(
            slotId: input.slotId,
            assetId: input.assetId
        )
        let transformInput = MotionTransformInput(
            progressFrame: baseProgressFrame,
            maximumCoverageProgress: motionContext.maximumCoverageProgress,
            renderGeometry: input.renderGeometry,
            cropRectInSource: input.cropRectInSource,
            focalSource: input.focalSource,
            isMotionEnabled: motionContext.isMotionEnabled,
            isReduceMotionEnabled: motionContext.isReduceMotionEnabled
        )
        let transform = MotionTransformResolver.resolve(transformInput)

        return SmartFillMotionRenderedSlotFrame(
            progressFrame: baseProgressFrame,
            transform: transform,
            diagnostics: MotionTransformResolver.diagnostics(transformInput),
            imageFrame: MotionTransformGeometry.transformedImageFrameInSlot(
                transform,
                renderGeometry: input.renderGeometry
            ),
            missingProgressReason: nil
        )
    }
}
