import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct ManualPlaybackLifecycleTests {
    @Test
    func `user pausing before launch settles the first scene as a fully visible static scene once ready`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)

        engine.reduceScenePresentation(.suspend(.userPaused), at: 0)
        engine.reduceScenePresentation(.start(target: first, readiness: .pending), at: 1)
        engine.reduceScenePresentation(.targetReady(first.identity), at: 2)

        let visible = engine.sceneRenderSnapshot(at: 2.1)
        let layer = try #require(visible.layers.first { $0.identity == first.identity })
        #expect(visible.underlyingPhase == .stablePhoto)
        #expect(layer.opacity == 1)
        #expect(layer.motionActiveTime == 0)

        let afterThreeSeconds = engine.sceneRenderSnapshot(at: 5.1)
        let frozen = try #require(afterThreeSeconds.layers.first { $0.identity == first.identity })
        #expect(frozen.opacity == 1)
        #expect(frozen.motionActiveTime == 0)
    }

    @Test
    func `pausing before the first ready scene is created freezes its layer until resume starts the motion`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)

        engine.reduceScenePresentation(.suspend(.userPaused), at: 0)
        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 1)

        let pausedInitial = try #require(
            engine.sceneRenderSnapshot(at: 1.1).layers.first { $0.identity == first.identity }
        )
        let pausedAfterThreeSeconds = try #require(
            engine.sceneRenderSnapshot(at: 4.1).layers.first { $0.identity == first.identity }
        )
        #expect(pausedAfterThreeSeconds.motionActiveTime == pausedInitial.motionActiveTime)
        #expect(pausedAfterThreeSeconds.opacity == pausedInitial.opacity)

        engine.reduceScenePresentation(.resume(.userPaused), at: 5)
        let resumed = try #require(
            engine.sceneRenderSnapshot(at: 5.2).layers.first { $0.identity == first.identity }
        )
        #expect(resumed.motionActiveTime > pausedInitial.motionActiveTime)
    }

    @Test
    func `pausing before a pending first scene becomes ready freezes its layer until resume starts the motion`() throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)

        engine.reduceScenePresentation(.suspend(.userPaused), at: 0)
        engine.reduceScenePresentation(.start(target: first, readiness: .pending), at: 1)
        engine.reduceScenePresentation(.targetReady(first.identity), at: 2)

        let pausedInitial = try #require(
            engine.sceneRenderSnapshot(at: 2.1).layers.first { $0.identity == first.identity }
        )
        let pausedAfterThreeSeconds = try #require(
            engine.sceneRenderSnapshot(at: 5.1).layers.first { $0.identity == first.identity }
        )
        #expect(pausedAfterThreeSeconds.motionActiveTime == pausedInitial.motionActiveTime)
        #expect(pausedAfterThreeSeconds.opacity == pausedInitial.opacity)

        engine.reduceScenePresentation(.resume(.userPaused), at: 6)
        let resumed = try #require(
            engine.sceneRenderSnapshot(at: 6.2).layers.first { $0.identity == first.identity }
        )
        #expect(resumed.motionActiveTime > pausedInitial.motionActiveTime)
    }

    @Test
    func `backgrounding before the first ready scene freezes its new layer and does not catch up before resume`() throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)

        engine.reduceScenePresentation(.suspend(.background), at: 0)
        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 1)

        let backgroundInitial = try #require(
            engine.sceneRenderSnapshot(at: 1.1).layers.first { $0.identity == first.identity }
        )
        let backgroundAfterThreeSeconds = try #require(
            engine.sceneRenderSnapshot(at: 4.1).layers.first { $0.identity == first.identity }
        )
        #expect(backgroundAfterThreeSeconds.motionActiveTime == backgroundInitial.motionActiveTime)
        #expect(backgroundAfterThreeSeconds.opacity == backgroundInitial.opacity)

        engine.reduceScenePresentation(.resume(.background), at: 5)
        let resumed = try #require(
            engine.sceneRenderSnapshot(at: 5.2).layers.first { $0.identity == first.identity }
        )
        #expect(resumed.motionActiveTime > backgroundInitial.motionActiveTime)
    }

    @Test
    func `manual next while paused cross fades briefly to a static scene without advancing raw progress indefinitely`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 2)
        engine.reduceScenePresentation(
            .request(target: second, source: .manualNext, readiness: .ready),
            at: 3
        )

        let visible = engine.sceneRenderSnapshot(at: 3.1)
        let incoming = try #require(visible.layers.first { $0.identity == second.identity })
        #expect(incoming.opacity > 0)
        #expect(!incoming.isMotionEnabled)
        #expect(incoming.motionActiveTime == 0)

        engine.reduceScenePresentation(.transitionCompleted, at: 3.3)
        let staticStart = try #require(
            engine.sceneRenderSnapshot(at: 3.3).layers.first { $0.identity == second.identity }
        )
        let staticAfterUnboundedWait = try #require(
            engine.sceneRenderSnapshot(at: 3_603.3).layers.first { $0.identity == second.identity }
        )
        #expect(!staticAfterUnboundedWait.isMotionEnabled)
        #expect(staticAfterUnboundedWait.motionActiveTime == staticStart.motionActiveTime)
    }

    @Test
    func `a manual pending scene becoming ready while paused still cross fades and settles at the static origin`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 2)
        engine.reduceScenePresentation(
            .request(target: second, source: .manualNext, readiness: .pending),
            at: 3
        )
        #expect(engine.sceneRenderSnapshot(at: 3).underlyingPhase == .grace)
        #expect(engine.sceneRenderSnapshot(at: 3).layers.first { $0.identity == first.identity }?.opacity == 1)

        engine.reduceScenePresentation(.targetReady(second.identity), at: 3.1)
        let incoming = try #require(
            engine.sceneRenderSnapshot(at: 3.2).layers.first { $0.identity == second.identity }
        )
        #expect(engine.sceneRenderSnapshot(at: 3.2).underlyingPhase == .transition)
        #expect(incoming.opacity > 0)
        #expect(!incoming.isMotionEnabled)

        engine.reduceScenePresentation(.transitionCompleted, at: 3.4)
        let settled = engine.sceneRenderSnapshot(at: 3.4)
        #expect(settled.underlyingPhase == .stablePhoto)
        #expect(settled.layers.first { $0.identity == second.identity }?.motionActiveTime == 0)
    }

    @Test
    func `resuming a manual static scene starts the current scene from progress zero with a full deadline`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 2)
        engine.reduceScenePresentation(
            .request(target: second, source: .manualPrevious, readiness: .ready),
            at: 3
        )
        engine.reduceScenePresentation(.transitionCompleted, at: 3.3)

        engine.reduceScenePresentation(.resume(.userPaused), at: 20)
        let resumedAtOrigin = try #require(
            engine.sceneRenderSnapshot(at: 20).layers.first { $0.identity == second.identity }
        )
        let resumedProgress = try #require(
            engine.sceneRenderSnapshot(at: 21).layers.first { $0.identity == second.identity }
        )

        #expect(resumedAtOrigin.isMotionEnabled)
        #expect(resumedAtOrigin.motionActiveTime == 0)
        #expect(resumedProgress.motionActiveTime == 1)
        #expect(engine.sceneRenderSnapshot(at: 24.9).underlyingPhase == .stablePhoto)
    }

    @Test
    func
        `switching a paused transition to manual next cross fades from the frozen sample without losing the current scene`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(
            .request(target: second, source: .automatic, readiness: .ready),
            at: 2
        )
        let frozenOutgoing = try #require(
            engine.sceneRenderSnapshot(at: 2.5).layers.first { $0.identity == first.identity }
        )

        engine.reduceScenePresentation(.suspend(.userPaused), at: 2.5)
        engine.reduceScenePresentation(
            .request(target: third, source: .manualNext, readiness: .ready),
            at: 20
        )
        let afterManualNext = engine.sceneRenderSnapshot(at: 20.1)
        let preservedOutgoing = try #require(afterManualNext.layers.first { $0.identity == first.identity })
        let incoming = try #require(afterManualNext.layers.first { $0.identity == third.identity })
        #expect(preservedOutgoing.opacity > 0)
        #expect(preservedOutgoing.opacity <= frozenOutgoing.opacity)
        #expect(incoming.opacity > 0)
        #expect(!incoming.isMotionEnabled)
    }

    @Test
    func `a pending manual next keeps the current photo fully visible until the next scene is ready`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.request(target: second, source: .manualNext, readiness: .pending), at: 2)

        for time in [2.0, 2.5, 30.0] {
            let snapshot = engine.sceneRenderSnapshot(at: time)
            let held = try #require(snapshot.layers.first { $0.identity == first.identity })
            let hidden = try #require(snapshot.layers.first { $0.identity == second.identity })
            #expect(snapshot.underlyingPhase == .grace)
            #expect(held.role == .stable)
            #expect(held.opacity == 1)
            #expect(hidden.opacity == 0)
            #expect(!hidden.isPresentationReady)
        }
    }

    @Test
    func `a manual target that becomes ready crossfades from the held photo without dropping below half coverage`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.request(target: second, source: .manualNext, readiness: .pending), at: 2)
        engine.reduceScenePresentation(.targetReady(second.identity), at: 2.2)

        let crossfadeStart = engine.sceneRenderSnapshot(at: 2.2)
        #expect(crossfadeStart.layers.first { $0.identity == first.identity }?.role == .outgoing)
        #expect(crossfadeStart.layers.first { $0.identity == first.identity }?.opacity == 1)
        for step in 0...30 {
            let snapshot = engine.sceneRenderSnapshot(at: 2.2 + Double(step) * 0.01)
            #expect(snapshot.underlyingPhase == .transition)
            #expect(
                SceneTransitionDiagnostic.photoCoverage(of: snapshot.layers.map(\.opacity))
                    >= SceneTransitionDiagnostic.minimumPhotoCoverage)
        }

        engine.reduceScenePresentation(.transitionCompleted, at: 2.5)
        let settled = engine.sceneRenderSnapshot(at: 2.5)
        let settledLayer = try #require(settled.layers.first { $0.identity == second.identity })
        #expect(settled.underlyingPhase == .stablePhoto)
        #expect(settledLayer.role == .stable)
        #expect(settledLayer.opacity == 1)
        #expect((settled.layers.first { $0.identity == first.identity }?.opacity ?? 0) < 0.0001)
    }

    @Test
    func `the held photo keeps moving while playing and carries its motion into the crossfade`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.request(target: second, source: .manualNext, readiness: .pending), at: 2)

        let heldEarly = try #require(engine.sceneRenderSnapshot(at: 2.0).layers.first { $0.identity == first.identity })
        let heldLater = try #require(engine.sceneRenderSnapshot(at: 2.1).layers.first { $0.identity == first.identity })
        #expect(heldLater.motionActiveTime > heldEarly.motionActiveTime)

        engine.reduceScenePresentation(.targetReady(second.identity), at: 2.2)
        let outgoingEarly = try #require(
            engine.sceneRenderSnapshot(at: 2.2).layers.first { $0.identity == first.identity })
        let outgoingLater = try #require(
            engine.sceneRenderSnapshot(at: 2.3).layers.first { $0.identity == first.identity })
        #expect(outgoingLater.motionActiveTime > outgoingEarly.motionActiveTime)
    }

    @Test
    func `a held photo while paused stays on its paused frame through the crossfade`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 1.5)
        let pausedFrame = try #require(
            engine.sceneRenderSnapshot(at: 1.5).layers.first { $0.identity == first.identity })

        engine.reduceScenePresentation(.request(target: second, source: .manualNext, readiness: .pending), at: 2)
        let held = try #require(engine.sceneRenderSnapshot(at: 2.1).layers.first { $0.identity == first.identity })
        #expect(held.opacity == 1)
        #expect(held.motionActiveTime == pausedFrame.motionActiveTime)

        engine.reduceScenePresentation(.targetReady(second.identity), at: 2.2)
        let crossfade = engine.sceneRenderSnapshot(at: 2.35)
        let outgoing = try #require(crossfade.layers.first { $0.identity == first.identity })
        let incoming = try #require(crossfade.layers.first { $0.identity == second.identity })
        #expect(outgoing.motionActiveTime == pausedFrame.motionActiveTime)
        #expect(!incoming.isMotionEnabled)

        engine.reduceScenePresentation(.transitionCompleted, at: 2.5)
        let settled = try #require(
            engine.sceneRenderSnapshot(at: 100).layers.first { $0.identity == second.identity })
        #expect(engine.sceneRenderSnapshot(at: 100).underlyingPhase == .stablePhoto)
        #expect(settled.motionActiveTime == 0)
    }

    @Test
    func `cancelling a held manual target while playing continues the current photo without rewinding its motion`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.request(target: second, source: .manualNext, readiness: .pending), at: 2)
        let beforeCancel = try #require(
            engine.sceneRenderSnapshot(at: 2.4).layers.first { $0.identity == first.identity })

        let effects = engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 2.4)
        let restored = engine.sceneRenderSnapshot(at: 2.4)
        let restoredLayer = try #require(restored.layers.first { $0.identity == first.identity })
        let deadlines = effects.compactMap { effect -> TimeInterval? in
            guard case let .scheduleWakeUp(_, deadline) = effect else { return nil }
            return deadline
        }

        #expect(restored.underlyingPhase == .stablePhoto)
        #expect(restored.layers.map(\.identity) == [first.identity])
        #expect(abs(restoredLayer.motionActiveTime - beforeCancel.motionActiveTime) < 0.0001)
        // The photo kept its clock on screen, so its original deadline still applies.
        #expect(deadlines.count == 1)
        #expect(deadlines.contains { abs($0 - 6) < 0.0001 })
    }

    @Test
    func `a second manual target replacing a held one keeps the same photo and drops the unseen target`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.request(target: second, source: .manualNext, readiness: .pending), at: 2)
        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 2.1)

        let replaced = engine.sceneRenderSnapshot(at: 2.2)
        #expect(replaced.underlyingPhase == .grace)
        #expect(replaced.layers.map(\.identity) == [first.identity, third.identity])
        #expect(replaced.layers.first?.opacity == 1)

        engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 2.3)
        let restored = engine.sceneRenderSnapshot(at: 2.3)
        #expect(restored.underlyingPhase == .stablePhoto)
        #expect(restored.layers.map(\.identity) == [first.identity])
    }

    @Test
    func `a held manual target that becomes ready after the user pauses still crossfades and then holds still`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.request(target: second, source: .manualNext, readiness: .pending), at: 2)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 2.1)
        engine.reduceScenePresentation(.targetReady(second.identity), at: 2.2)

        let crossfade = engine.sceneRenderSnapshot(at: 2.3)
        let incoming = try #require(crossfade.layers.first { $0.identity == second.identity })
        #expect(crossfade.phase == .paused)
        #expect(crossfade.underlyingPhase == .transition)
        #expect(incoming.opacity > 0)
        #expect(!incoming.isMotionEnabled)

        engine.reduceScenePresentation(.transitionCompleted, at: 2.5)
        let settled = try #require(
            engine.sceneRenderSnapshot(at: 100).layers.first { $0.identity == second.identity })
        #expect(engine.sceneRenderSnapshot(at: 100).underlyingPhase == .stablePhoto)
        #expect(settled.opacity == 1)
        #expect(settled.motionActiveTime == 0)
    }
}

func makeManualLifecycleTarget(
    sceneID: String,
    interval: TimeInterval
) -> PlaybackSessionEngine.ScenePresentationTarget {
    PlaybackSessionEngine.ScenePresentationTarget(
        identity: .init(generation: UUID(), sceneID: sceneID),
        configuredInterval: interval
    )
}
