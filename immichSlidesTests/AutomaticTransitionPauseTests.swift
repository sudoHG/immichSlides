import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct AutomaticTransitionPauseTests {
    #if DEBUG
    @Test(arguments: [
        [:], ["UI_TEST_PAUSE_AT_AUTOMATIC_FADE_MIDPOINT": "0"], ["UI_TEST_PAUSE_AT_AUTOMATIC_FADE_MIDPOINT": "1"]
    ])
    func `the midpoint launch hook pauses through the user path only when enabled and only once`(
        environment: [String: String]
    ) throws {
        let suiteName = "AutomaticTransitionPauseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlaybackSettingsStore(key: suiteName, defaults: defaults)
        let vm = SlideShowViewModel(settingsStore: store, observeSettingsChanges: false)
        var now = 0.0
        vm.scenePresentationTimestampProviderForTesting = { now }
        let first = makeTarget(sceneID: "first")
        let second = makeTarget(sceneID: "second")
        let third = makeTarget(sceneID: "third")
        vm.playbackSession.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        vm.playbackSession.reduceScenePresentation(.transitionCompleted, at: 1)
        vm.playbackSession.reduceScenePresentation(.stableDeadlineReached(target: second, readiness: .ready), at: 6)

        now = 6.5
        // An automatic fade before the first user Play must not consume the hook.
        #expect(!vm.pauseAtAutomaticFadeMidpointForTesting(environment: environment))
        #expect(vm.isAutoPlay)
        vm.playbackSession.reduceScenePresentation(.transitionCompleted, at: 8.025)
        now = 9
        vm.toggleAutoPlayFromUserInteraction()
        vm.toggleAutoPlayFromUserInteraction()
        vm.playbackSession.reduceScenePresentation(.stableDeadlineReached(target: third, readiness: .ready), at: 14)
        now = 14.49
        #expect(!vm.pauseAtAutomaticFadeMidpointForTesting(environment: environment))
        now = 14.5
        let isEnabled = environment["UI_TEST_PAUSE_AT_AUTOMATIC_FADE_MIDPOINT"] == "1"
        #expect(vm.pauseAtAutomaticFadeMidpointForTesting(environment: environment) == isEnabled)
        #expect(vm.isAutoPlay == !isEnabled)
        if isEnabled {
            #expect(store.load()?.autoPlayEnabled == false)
            vm.toggleAutoPlayFromUserInteraction()
            #expect(store.load()?.autoPlayEnabled == true)
            #expect(!vm.pauseAtAutomaticFadeMidpointForTesting(environment: environment))
            vm.playbackSession.resetPlayback(with: [], initialScene: nil, reason: .sourceChanged)
            vm.playbackSession.reduceScenePresentation(.start(target: first, readiness: .ready), at: 21)
            vm.playbackSession.reduceScenePresentation(.transitionCompleted, at: 22)
            vm.playbackSession.reduceScenePresentation(
                .stableDeadlineReached(target: second, readiness: .ready), at: 27)
            now = 27.5
            #expect(!vm.pauseAtAutomaticFadeMidpointForTesting(environment: environment))
            #expect(vm.isAutoPlay)
        }
    }
    #endif

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
