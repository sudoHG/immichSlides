import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct MotionPresentationClockTests {
    @Test
    func `pure value clock only derives the frozen window and owns no deadline extension`() {
        let clock = MotionPacingPolicy(configuredPlaybackIntervalSeconds: 5)
            .makePresentationClock(timelineStartTime: 10, stableVisibleStartTime: 11)

        assertApproximatelyEqual(clock.timelineStartTime, 10)
        assertApproximatelyEqual(clock.stableVisibleStartTime, 11)
        assertApproximatelyEqual(clock.handoffStartDeadlineTime, 16)
        assertApproximatelyEqual(clock.removalDeadlineTime, 18.025)
        assertApproximatelyEqual(clock.progress(at: 10), 0)
        assertApproximatelyEqual(clock.progress(at: 13), 0.5)
        assertApproximatelyEqual(clock.progress(at: 16), 1)
        #expect(clock.progress(at: 18.025) > 1)
    }

    @Test
    func `raw progress keeps increasing linearly past the waypoint without clamping`() {
        let clock = MotionPacingPolicy(configuredPlaybackIntervalSeconds: 5)
            .makePresentationClock(timelineStartTime: 0, stableVisibleStartTime: 0)

        assertApproximatelyEqual(clock.progress(at: 0), 0)
        assertApproximatelyEqual(clock.progress(at: 2.5), 0.5)
        assertApproximatelyEqual(clock.progress(at: 5), 1)
        assertApproximatelyEqual(clock.progress(at: 7), 1.4)
        #expect(clock.progress(at: 7) > clock.progress(at: 6))
    }

    @Test
    func `all visible render roles share one raw sample while prerender stays zero`() {
        let clock = MotionPacingPolicy(configuredPlaybackIntervalSeconds: 5)
            .makePresentationClock(timelineStartTime: 0, stableVisibleStartTime: 0)

        let incoming = MotionRenderRole.incoming.progress(for: clock, at: 6)
        let settled = MotionRenderRole.settled.progress(for: clock, at: 6)
        let outgoing = MotionRenderRole.outgoing.progress(for: clock, at: 6)

        assertApproximatelyEqual(incoming, 1.2)
        assertApproximatelyEqual(settled, incoming)
        assertApproximatelyEqual(outgoing, incoming)
        assertApproximatelyEqual(MotionRenderRole.prerender.progress(for: clock, at: 6), 0)
    }

    @Test
    func `configured interval below five seconds still freezes to the minimum stable visible interval`() {
        let clock = MotionPacingPolicy(configuredPlaybackIntervalSeconds: 2)
            .makePresentationClock(timelineStartTime: 4, stableVisibleStartTime: 5)

        assertApproximatelyEqual(clock.configuredPlaybackIntervalSeconds, 2)
        assertApproximatelyEqual(clock.resolvedPlaybackIntervalSeconds, 5)
        assertApproximatelyEqual(clock.handoffStartDeadlineTime, 10)
        assertApproximatelyEqual(clock.motionDurationSeconds, 6)
    }

    @Test
    func `identical frozen inputs create identical pure value clocks`() {
        let policy = MotionPacingPolicy(configuredPlaybackIntervalSeconds: 8)
        let first = policy.makePresentationClock(
            timelineStartTime: 20,
            stableVisibleStartTime: 21
        )
        let repeated = policy.makePresentationClock(
            timelineStartTime: 20,
            stableVisibleStartTime: 21
        )

        #expect(first == repeated)
        assertApproximatelyEqual(first.handoffToHandoffCadenceSeconds, 10.025)
    }

    @Test
    func `active-time clock does not advance while suspended between pause and resume`() {
        var clock = SceneActiveTimeClock(startedAt: 10)
        assertApproximatelyEqual(clock.activeTime(at: 13), 3)

        clock.suspend(at: 13)
        assertApproximatelyEqual(clock.activeTime(at: 99), 3)

        clock.resume(at: 99)
        assertApproximatelyEqual(clock.activeTime(at: 101), 5)
    }

    @Test
    func `active-time sample can be replaced atomically and keeps accumulating`() {
        var clock = SceneActiveTimeClock(startedAt: 10)
        clock.replaceActiveTime(with: 4, at: 12)

        assertApproximatelyEqual(clock.activeTime(at: 12), 4)
        assertApproximatelyEqual(clock.activeTime(at: 14), 6)

        clock.suspend(at: 14)
        clock.replaceActiveTime(with: 1.5, at: 30)
        assertApproximatelyEqual(clock.activeTime(at: 40), 1.5)
    }

    @Test
    func `progress frame records whether its value came from shared active-time or a pure clock`() {
        let identity = MotionFrameIdentity(
            sceneId: "scene-a",
            slotId: "slot-a",
            assetId: "asset-a",
            renderRole: .settled,
            clockGeneration: 0
        )
        let sceneFrame = MotionRenderProgressFrame.fromSceneActiveTime(
            identity: identity,
            rawProgress: 1.25
        )
        let pureClock = MotionPacingPolicy(configuredPlaybackIntervalSeconds: 5)
            .makePresentationClock(timelineStartTime: 0, stableVisibleStartTime: 0)
        let clockFrame = MotionRenderProgressFrame.fromPresentationClock(
            identity: identity,
            clock: pureClock,
            at: 6.25
        )

        #expect(sceneFrame.source == .sceneActiveTime)
        #expect(clockFrame.source == .presentationClock)
        assertApproximatelyEqual(sceneFrame.progress, clockFrame.progress)
    }

    private func assertApproximatelyEqual(
        _ actual: TimeInterval,
        _ expected: TimeInterval,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual - expected) < 0.000_1, sourceLocation: sourceLocation)
    }
}
