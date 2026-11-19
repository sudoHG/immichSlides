import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct AutomaticTransitionPauseTests {
    @Test
    func `a pause in the gap between the automatic fade-out and fade-in brings the next photo in and holds it still`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeTarget(sceneID: "first")
        let second = makeTarget(sceneID: "second")
        startAutomaticTransition(from: first, to: second, in: &engine)
        #expect(
            SceneTransitionDiagnostic.photoCoverage(of: engine.sceneRenderSnapshot(at: 7.01).layers.map(\.opacity)) == 0
        )

        let pauseEffects = engine.reduceScenePresentation(.suspend(.userPaused), at: 7.01)
        // The faded-out photo keeps its layer until the next one shows, so EXIF does not blink off meanwhile.
        #expect(engine.sceneRenderSnapshot(at: 7.01).layers.first { $0.identity == first.identity }?.role == .outgoing)
        let fadingIn = engine.sceneRenderSnapshot(at: 7.16)
        let incoming = try #require(fadingIn.layers.first { $0.identity == second.identity })
        #expect(fadingIn.phase == .paused)
        #expect(abs(incoming.opacity - 0.5) < 0.0001)
        #expect(!incoming.isMotionEnabled)
        let completion = try #require(
            pauseEffects.compactMap { effect -> TimeInterval? in
                guard case let .scheduleWakeUp(_, deadline) = effect else { return nil }
                return deadline
            }.first)
        #expect(abs(completion - 7.31) < 0.0001)

        engine.reduceScenePresentation(.transitionCompleted, at: completion)
        let held = engine.sceneRenderSnapshot(at: 100)
        let settled = try #require(held.layers.first { $0.identity == second.identity })
        #expect(held.phase == .paused)
        #expect(held.underlyingPhase == .stablePhoto)
        #expect(settled.opacity == 1)
        #expect(settled.motionActiveTime == 0)

        let resumeEffects = engine.reduceScenePresentation(.resume(.userPaused), at: 100)
        #expect(
            resumeEffects.contains { effect in
                guard case let .scheduleWakeUp(_, deadline) = effect else { return false }
                return abs(deadline - 105) < 0.0001
            })
    }

    @Test
    func `resuming during the short fade-in after a pause in the gap continues the fade and starts the motion`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeTarget(sceneID: "first")
        let second = makeTarget(sceneID: "second")
        startAutomaticTransition(from: first, to: second, in: &engine)

        engine.reduceScenePresentation(.suspend(.userPaused), at: 7.01)
        engine.reduceScenePresentation(.resume(.userPaused), at: 7.1)
        let early = try #require(engine.sceneRenderSnapshot(at: 7.15).layers.first { $0.identity == second.identity })
        let later = try #require(engine.sceneRenderSnapshot(at: 7.25).layers.first { $0.identity == second.identity })
        #expect(later.opacity > early.opacity)
        #expect(later.motionActiveTime > early.motionActiveTime)
        #expect(later.isMotionEnabled)

        let settleEffects = engine.reduceScenePresentation(.transitionCompleted, at: 7.31)
        #expect(engine.sceneRenderSnapshot(at: 7.31).underlyingPhase == .stablePhoto)
        #expect(
            settleEffects.contains { effect in
                guard case let .scheduleWakeUp(_, deadline) = effect else { return false }
                return abs(deadline - 12.31) < 0.0001
            })
    }

    @Test
    func `a pause while the old photo is still fading out keeps freezing that frame`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeTarget(sceneID: "first")
        let second = makeTarget(sceneID: "second")
        startAutomaticTransition(from: first, to: second, in: &engine)

        engine.reduceScenePresentation(.suspend(.userPaused), at: 6.5)
        let frozen = engine.sceneRenderSnapshot(at: 20)
        #expect(frozen.underlyingPhase == .transition)
        #expect(abs((frozen.layers.first { $0.identity == first.identity }?.opacity ?? 0) - 0.5) < 0.0001)
        #expect(frozen.layers.first { $0.identity == second.identity }?.opacity == 0)
    }

    @Test
    func `leaving for the background in the fade gap still freezes and then resumes the automatic fade-in`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeTarget(sceneID: "first")
        let second = makeTarget(sceneID: "second")
        startAutomaticTransition(from: first, to: second, in: &engine)

        engine.reduceScenePresentation(.suspend(.background), at: 7.01)
        #expect(
            SceneTransitionDiagnostic.photoCoverage(of: engine.sceneRenderSnapshot(at: 20).layers.map(\.opacity)) == 0)

        engine.reduceScenePresentation(.resume(.background), at: 20)
        let resumed = try #require(
            engine.sceneRenderSnapshot(at: 20.515).layers.first { $0.identity == second.identity })
        #expect(abs(resumed.opacity - 0.5) < 0.0001)
    }

    /// Settles `first`, then starts the automatic transition at 6 s: `first` fades out over 1 s and `second` fades in
    /// from 7.025 s, leaving 25 ms with no visible layer.
    private func startAutomaticTransition(
        from first: PlaybackSessionEngine.ScenePresentationTarget,
        to second: PlaybackSessionEngine.ScenePresentationTarget,
        in engine: inout PlaybackSessionEngine
    ) {
        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: second, readiness: .ready), at: 6)
    }

    private func makeTarget(sceneID: String) -> PlaybackSessionEngine.ScenePresentationTarget {
        PlaybackSessionEngine.ScenePresentationTarget(
            identity: .init(generation: UUID(), sceneID: sceneID),
            configuredInterval: 5
        )
    }
}
