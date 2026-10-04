import Foundation

/// Pure-value active-time clock. When paused or in the background it only freezes the current sample and does
/// not catch up on background time.
struct SceneActiveTimeClock: Equatable, Sendable {
    private(set) var accumulatedActiveTime: TimeInterval
    private(set) var activeAnchorTime: TimeInterval?

    nonisolated init(startedAt startTime: TimeInterval) {
        accumulatedActiveTime = 0
        activeAnchorTime = startTime
    }

    nonisolated init(
        accumulatedActiveTime: TimeInterval,
        activeAnchorTime: TimeInterval?
    ) {
        self.accumulatedActiveTime = max(0, accumulatedActiveTime)
        self.activeAnchorTime = activeAnchorTime
    }

    nonisolated func activeTime(at currentTime: TimeInterval) -> TimeInterval {
        guard let activeAnchorTime else {
            return accumulatedActiveTime
        }
        return accumulatedActiveTime + max(0, currentTime - activeAnchorTime)
    }

    nonisolated mutating func suspend(at currentTime: TimeInterval) {
        accumulatedActiveTime = activeTime(at: currentTime)
        activeAnchorTime = nil
    }

    nonisolated mutating func resume(at currentTime: TimeInterval) {
        guard activeAnchorTime == nil else { return }
        activeAnchorTime = currentTime
    }

    nonisolated mutating func replaceActiveTime(
        with value: TimeInterval,
        at currentTime: TimeInterval
    ) {
        accumulatedActiveTime = max(0, value)
        if activeAnchorTime != nil {
            activeAnchorTime = currentTime
        }
    }
}
