import CoreGraphics
import Foundation

enum SceneAnimationDirection: Equatable, Sendable {
    case zoomIn
    case zoomOut
}

/// Pure-value entry point that maps shared active-time to animation samples.
struct SceneAnimationProfile: Equatable, Sendable {
    let lifecycle: SceneLifecycleContract
    let singlePhotoTunables: SinglePhotoAnimationTunables

    nonisolated init(
        lifecycle: SceneLifecycleContract,
        singlePhotoTunables: SinglePhotoAnimationTunables = .default
    ) {
        self.lifecycle = lifecycle
        self.singlePhotoTunables = singlePhotoTunables
    }

    /// SmartFill still derives its existing raw progress from the frozen interval; single photo picks the longest
    /// window only inside its own adapter.
    nonisolated func rawProgress(for activeTime: TimeInterval) -> Double {
        guard lifecycle.frozenInterval > 0 else { return 0 }
        return max(0, activeTime / lifecycle.frozenInterval)
    }

    /// For single photo, both directions run from the start of the incoming fade to the end of the full visible
    /// interval; the window must not be extended for zoom-out only.
    nonisolated func rawProgress(
        for activeTime: TimeInterval,
        direction: SceneAnimationDirection
    ) -> Double {
        let duration = lifecycle.longestVisibleMotionDuration
        guard duration > 0 else { return 0 }
        return max(0, activeTime / duration)
    }

    nonisolated func singlePhotoTransform(
        direction: SceneAnimationDirection,
        activeTime: TimeInterval,
        isMotionEnabled: Bool,
        reduceMotionEnabled: Bool
    ) -> MotionTransform {
        SinglePhotoGeometryPolicy(tunables: singlePhotoTunables).transform(
            direction: direction,
            rawProgress: rawProgress(for: activeTime, direction: direction),
            isMotionEnabled: isMotionEnabled,
            reduceMotionEnabled: reduceMotionEnabled
        )
    }

}

/// Single photo only scales around the center; there is deliberately no focal input here, to avoid
/// introducing face or subject tracking.
struct SinglePhotoGeometryPolicy: Equatable, Sendable {
    let tunables: SinglePhotoAnimationTunables

    nonisolated init(tunables: SinglePhotoAnimationTunables = .default) {
        self.tunables = tunables
    }

    nonisolated func transform(
        direction: SceneAnimationDirection,
        rawProgress: Double,
        isMotionEnabled: Bool,
        reduceMotionEnabled: Bool
    ) -> MotionTransform {
        // A layer that has started freezes active-time and keeps its last sample; only motion disabled from the
        // start returns identity.

        guard isMotionEnabled else {
            return .identity
        }

        let progress = max(0, rawProgress)
        let scale: Double
        switch direction {
        case .zoomIn:
            scale = 1 + (tunables.zoomInTargetScale - 1) * progress
        case .zoomOut:
            scale = tunables.zoomInTargetScale - tunables.continueShrinkRange * progress
        }

        return MotionTransform(
            scale: scale,
            translationInSlot: .zero,
            anchorUnitPointInSlot: CGPoint(x: 0.5, y: 0.5),
            applicationSpace: .slotSizedClippedContainer,
            phaseAction: progress == 0 ? .showStartWithoutAnimation : .animateForwardAndHold,
            focalSource: .slotCenterFallback
        )
    }
}
