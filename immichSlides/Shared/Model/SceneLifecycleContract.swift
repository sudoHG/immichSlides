import Foundation

/// Automatic and manual share one pacing contract; only the reducer picks by request source, so the host does
/// not build another timer.
struct ScenePresentationPacingPolicy: Equatable, Sendable {
    nonisolated static let automatic = ScenePresentationPacingPolicy(
        outgoingFadeDuration: 1.0,
        incomingDelay: 1.025,
        incomingFadeDuration: 1.0,
        completionDuration: 2.025
    )
    nonisolated static let manualReady = ScenePresentationPacingPolicy(
        outgoingFadeDuration: 0.3,
        incomingDelay: 0,
        incomingFadeDuration: 0.3,
        completionDuration: 0.3
    )
    nonisolated static let automaticIncoming = ScenePresentationPacingPolicy(
        outgoingFadeDuration: 0,
        incomingDelay: 0,
        incomingFadeDuration: 1.0,
        completionDuration: 1.0
    )

    let outgoingFadeDuration: TimeInterval
    let incomingDelay: TimeInterval
    let incomingFadeDuration: TimeInterval
    let completionDuration: TimeInterval
}

/// Only describes contract timings; it does not schedule, download or autoplay.

struct SceneLifecycleContract: Equatable, Sendable {
    nonisolated static let outgoingFadeDuration = ScenePresentationPacingPolicy.automatic.outgoingFadeDuration
    nonisolated static let incomingDelay = ScenePresentationPacingPolicy.automatic.incomingDelay
    nonisolated static let incomingFadeDuration = ScenePresentationPacingPolicy.automatic.incomingFadeDuration
    nonisolated static let transitionDuration = ScenePresentationPacingPolicy.automatic.completionDuration
    nonisolated static let minimumInterval: TimeInterval = PlaybackIntervalPolicy.minimumInterval
    nonisolated static let minimumGrace: TimeInterval = 1.0
    nonisolated static let maximumGrace: TimeInterval = 4.0
    private nonisolated static let graceIntervalFraction: Double = 0.2
    nonisolated static let retryLimit = 3

    let configuredInterval: TimeInterval
    let frozenInterval: TimeInterval
    /// Freezes the window from the actual incoming pacing, so a short manual fade does not still use the automatic
    /// 1-second fade-in.
    let visibleIncomingFadeDuration: TimeInterval

    nonisolated init(
        configuredInterval: TimeInterval,
        incomingFadeDuration: TimeInterval = Self.incomingFadeDuration
    ) {
        self.configuredInterval = configuredInterval
        self.frozenInterval = Self.normalizedInterval(configuredInterval)
        self.visibleIncomingFadeDuration = max(0, incomingFadeDuration)
    }

    nonisolated var graceDuration: TimeInterval {
        min(
            Self.maximumGrace,
            max(Self.minimumGrace, frozenInterval * Self.graceIntervalFraction)
        )
    }

    nonisolated var longestVisibleMotionDuration: TimeInterval {
        visibleIncomingFadeDuration + frozenInterval + graceDuration + Self.outgoingFadeDuration
    }

    nonisolated static func normalizedInterval(_ interval: TimeInterval) -> TimeInterval {
        max(minimumInterval, interval)
    }
}
