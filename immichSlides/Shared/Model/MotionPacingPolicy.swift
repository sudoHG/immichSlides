import Foundation

struct MotionTransitionPacingPolicy: Equatable, Sendable {
    nonisolated static let v1OutgoingFadeDurationSeconds: TimeInterval = 1.0
    nonisolated static let v1IncomingDelaySeconds: TimeInterval = 1.025
    nonisolated static let v1IncomingFadeDurationSeconds: TimeInterval = 1.0
    nonisolated static let v1CompletionDelaySeconds: TimeInterval = 2.025
    nonisolated static let v1SwiftUIIncomingDelayCompensationSeconds: TimeInterval = 0.25

    nonisolated static let v1Default = MotionTransitionPacingPolicy(
        outgoingFadeDurationSeconds: Self.v1OutgoingFadeDurationSeconds,
        incomingDelaySeconds: Self.v1IncomingDelaySeconds,
        incomingFadeDurationSeconds: Self.v1IncomingFadeDurationSeconds,
        completionDelaySeconds: Self.v1CompletionDelaySeconds,
        swiftUIIncomingDelayCompensationSeconds: Self.v1SwiftUIIncomingDelayCompensationSeconds
    )

    let outgoingFadeDurationSeconds: TimeInterval
    let incomingDelaySeconds: TimeInterval
    let incomingFadeDurationSeconds: TimeInterval
    let completionDelaySeconds: TimeInterval
    let swiftUIIncomingDelayCompensationSeconds: TimeInterval

    nonisolated var scheduledIncomingDelayForSwiftUISeconds: TimeInterval {
        max(0, incomingDelaySeconds - swiftUIIncomingDelayCompensationSeconds)
    }
}

struct MotionPacingPolicy: Equatable, Sendable {
    nonisolated static let minimumStableVisibleSeconds: TimeInterval = 5

    let configuredPlaybackIntervalSeconds: TimeInterval
    let transitionPolicy: MotionTransitionPacingPolicy

    nonisolated init(
        configuredPlaybackIntervalSeconds: TimeInterval,
        transitionPolicy: MotionTransitionPacingPolicy = .v1Default
    ) {
        self.configuredPlaybackIntervalSeconds = configuredPlaybackIntervalSeconds
        self.transitionPolicy = transitionPolicy
    }

    nonisolated var resolvedPlaybackIntervalSeconds: TimeInterval {
        max(Self.minimumStableVisibleSeconds, configuredPlaybackIntervalSeconds)
    }

    nonisolated func makePresentationClock(
        timelineStartTime: TimeInterval,
        stableVisibleStartTime: TimeInterval
    ) -> MotionPresentationClock {
        let resolvedInterval = resolvedPlaybackIntervalSeconds
        let handoffStartDeadlineTime = stableVisibleStartTime + resolvedInterval
        return MotionPresentationClock(
            configuredPlaybackIntervalSeconds: configuredPlaybackIntervalSeconds,
            resolvedPlaybackIntervalSeconds: resolvedInterval,
            timelineStartTime: timelineStartTime,
            stableVisibleStartTime: stableVisibleStartTime,
            handoffStartDeadlineTime: handoffStartDeadlineTime,
            removalDeadlineTime: handoffStartDeadlineTime + transitionPolicy.completionDelaySeconds
        )
    }
}
