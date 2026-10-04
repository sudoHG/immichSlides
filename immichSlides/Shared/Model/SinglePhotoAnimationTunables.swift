import Foundation

/// The only two single-photo geometry parameters that may be tuned by hand.
struct SinglePhotoAnimationTunables: Equatable, Sendable {
    nonisolated static let `default` = SinglePhotoAnimationTunables(
        zoomInTargetScale: 1.10,
        continueShrinkRange: 0.10
    )

    let zoomInTargetScale: Double
    let continueShrinkRange: Double

    nonisolated init(
        zoomInTargetScale: Double,
        continueShrinkRange: Double
    ) {
        self.zoomInTargetScale = max(1, zoomInTargetScale)
        self.continueShrinkRange = max(0, continueShrinkRange)
    }
}
