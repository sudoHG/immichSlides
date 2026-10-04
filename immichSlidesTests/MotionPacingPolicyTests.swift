import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct MotionPacingPolicyTests {

    @Test
    func `default transition pacing values stay centralized in one policy`() {
        let policy = MotionTransitionPacingPolicy.v1Default

        assertApproximatelyEqual(policy.outgoingFadeDurationSeconds, 1.0)
        assertApproximatelyEqual(policy.incomingDelaySeconds, 1.025)
        assertApproximatelyEqual(policy.incomingFadeDurationSeconds, 1.0)
        assertApproximatelyEqual(policy.completionDelaySeconds, 2.025)
        assertApproximatelyEqual(policy.swiftUIIncomingDelayCompensationSeconds, 0.25)
        assertApproximatelyEqual(policy.scheduledIncomingDelayForSwiftUISeconds, 0.775)
    }

    @Test
    func `5s and 10s playback intervals resolve as stable-visible duration, not timeline duration`() {
        let fiveSecondPolicy = MotionPacingPolicy(configuredPlaybackIntervalSeconds: 5)
        let fiveSecondClock = fiveSecondPolicy.makePresentationClock(
            timelineStartTime: 100,
            stableVisibleStartTime: 101
        )

        assertApproximatelyEqual(fiveSecondClock.resolvedPlaybackIntervalSeconds, 5)
        assertApproximatelyEqual(fiveSecondClock.stableVisibleDurationSeconds, 5)
        assertApproximatelyEqual(fiveSecondClock.handoffStartDeadlineTime, 106)
        assertApproximatelyEqual(fiveSecondClock.removalDeadlineTime, 108.025)
        assertApproximatelyEqual(fiveSecondClock.motionDurationSeconds, 6)
        assertApproximatelyEqual(fiveSecondClock.handoffToHandoffCadenceSeconds, 7.025)

        let tenSecondPolicy = MotionPacingPolicy(configuredPlaybackIntervalSeconds: 10)
        let tenSecondClock = tenSecondPolicy.makePresentationClock(
            timelineStartTime: 200,
            stableVisibleStartTime: 201
        )

        assertApproximatelyEqual(tenSecondClock.resolvedPlaybackIntervalSeconds, 10)
        assertApproximatelyEqual(tenSecondClock.stableVisibleDurationSeconds, 10)
        assertApproximatelyEqual(tenSecondClock.handoffStartDeadlineTime, 211)
        assertApproximatelyEqual(tenSecondClock.removalDeadlineTime, 213.025)
        assertApproximatelyEqual(tenSecondClock.motionDurationSeconds, 11)
        assertApproximatelyEqual(tenSecondClock.handoffToHandoffCadenceSeconds, 12.025)
    }

    @Test
    func `configured intervals shorter than 5s resolve to the minimum stable-visible duration`() {
        let policy = MotionPacingPolicy(configuredPlaybackIntervalSeconds: 2.5)
        let clock = policy.makePresentationClock(
            timelineStartTime: 0,
            stableVisibleStartTime: 0
        )

        assertApproximatelyEqual(policy.resolvedPlaybackIntervalSeconds, 5)
        assertApproximatelyEqual(clock.resolvedPlaybackIntervalSeconds, 5)
        assertApproximatelyEqual(clock.stableVisibleDurationSeconds, 5)
        assertApproximatelyEqual(clock.handoffStartDeadlineTime, 5)
        assertApproximatelyEqual(clock.removalDeadlineTime, 7.025)
    }

    private func assertApproximatelyEqual(
        _ actual: TimeInterval,
        _ expected: TimeInterval,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual - expected) < 0.000_1, sourceLocation: sourceLocation)
    }
}
