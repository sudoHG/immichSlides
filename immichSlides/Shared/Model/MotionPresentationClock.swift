import Foundation

/// Product deadlines/pause are owned by ScenePresentationState; this type only turns a frozen window into raw
/// progress, and the product path does not use it.

struct MotionPresentationClock: Equatable, Sendable {
    let configuredPlaybackIntervalSeconds: TimeInterval
    let resolvedPlaybackIntervalSeconds: TimeInterval
    let timelineStartTime: TimeInterval
    let stableVisibleStartTime: TimeInterval
    let handoffStartDeadlineTime: TimeInterval
    let removalDeadlineTime: TimeInterval

    nonisolated var stableVisibleDurationSeconds: TimeInterval {
        max(0, handoffStartDeadlineTime - stableVisibleStartTime)
    }

    nonisolated var handoffToHandoffCadenceSeconds: TimeInterval {
        resolvedPlaybackIntervalSeconds + max(0, removalDeadlineTime - handoffStartDeadlineTime)
    }

    nonisolated var motionDurationSeconds: TimeInterval {
        max(0, handoffStartDeadlineTime - timelineStartTime)
    }

    /// Keeps growing linearly past the waypoint; the product factory does not clamp it to 1.
    nonisolated func progress(at currentTime: TimeInterval) -> Double {
        let duration = motionDurationSeconds
        guard duration > 0 else { return currentTime >= timelineStartTime ? 1 : 0 }
        return max(0, (currentTime - timelineStartTime) / duration)
    }
}
