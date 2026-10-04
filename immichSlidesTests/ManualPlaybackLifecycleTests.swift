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

    @Test
    func `pressing next during an automatic crossfade brings the fading photo back up and holds it`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        startAutomaticCrossfade(from: first, to: second, in: &engine)
        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 6.5)

        #expect(abs(heldOpacity(of: first, in: engine, at: 6.5) - 0.5) < 0.0001)
        for time in [6.65, 6.9, 7.5, 30] {
            let held = engine.sceneRenderSnapshot(at: time)
            #expect(held.underlyingPhase == .grace)
            #expect(abs(heldOpacity(of: first, in: engine, at: time) - 1) < 0.0001)
            #expect(held.layers.first { $0.identity == third.identity }?.opacity == 0)
            #expect(!held.layers.contains { $0.identity == second.identity })
        }
        let earlier = try #require(engine.sceneRenderSnapshot(at: 7).layers.first { $0.identity == first.identity })
        let later = try #require(engine.sceneRenderSnapshot(at: 7.4).layers.first { $0.identity == first.identity })
        #expect(later.motionActiveTime > earlier.motionActiveTime)

        engine.reduceScenePresentation(.targetReady(third.identity), at: 7.5)
        for step in 0...30 {
            let snapshot = engine.sceneRenderSnapshot(at: 7.5 + Double(step) * 0.01)
            #expect(snapshot.underlyingPhase == .transition)
            #expect(SceneTransitionDiagnostic.photoCoverage(of: snapshot.layers.map(\.opacity)) >= 0.75 - 0.0001)
        }
    }

    @Test
    func
        `next or previous when the automatic crossfade is nearly dark raises the fading photo instead of holding it dim`()
        throws
    {
        for source in [PlaybackSessionEngine.ScenePresentationRequestSource.manualNext, .manualPrevious] {
            var engine = PlaybackSessionEngine()
            let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
            let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
            let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
            startAutomaticCrossfade(from: first, to: second, in: &engine)
            engine.reduceScenePresentation(.request(target: third, source: source, readiness: .pending), at: 6.75)

            #expect(abs(heldOpacity(of: first, in: engine, at: 6.75) - 0.25) < 0.0001)
            #expect(
                SceneTransitionDiagnostic.photoCoverage(of: engine.sceneRenderSnapshot(at: 6.9).layers.map(\.opacity))
                    >= 0.5)
            for time in [6.975, 7.5, 30] {
                #expect(abs(heldOpacity(of: first, in: engine, at: time) - 1) < 0.0001)
                #expect(engine.sceneRenderSnapshot(at: time).underlyingPhase == .grace)
            }
        }
    }

    @Test
    func `pressing next after the next photo has been seen raises that photo`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        startAutomaticCrossfade(from: first, to: second, in: &engine)
        engine.reduceScenePresentation(.incomingBecameVisible(second.identity), at: 7.05)
        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 7.1)

        let held = engine.sceneRenderSnapshot(at: 7.4)
        #expect(held.underlyingPhase == .grace)
        #expect(abs(heldOpacity(of: second, in: engine, at: 7.4) - 1) < 0.0001)
        #expect(!held.layers.contains { $0.identity == first.identity })
        #expect(held.layers.first { $0.identity == third.identity }?.opacity == 0)
    }

    @Test
    func `pressing next before the arriving photo has been seen brings back the photo that faded out instead`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        startAutomaticCrossfade(from: first, to: second, in: &engine)
        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 7.03)

        for step in 0...40 {
            let time = 7.03 + Double(step) * 0.01
            let snapshot = engine.sceneRenderSnapshot(at: time)
            #expect(snapshot.underlyingPhase == .grace)
            if step > 0 {
                #expect(heldOpacity(of: first, in: engine, at: time) > 0)
            }
        }
        #expect(abs(heldOpacity(of: first, in: engine, at: 7.4) - 1) < 0.0001)
        #expect(heldOpacity(of: second, in: engine, at: 7.1) == 0)
    }

    @Test
    func `previous during a hold raised from a fading photo keeps that photo up and replays the automatic crossfade`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        startAutomaticCrossfade(from: first, to: second, in: &engine)
        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 6.75)
        let beforeCancel = try #require(
            engine.sceneRenderSnapshot(at: 6.9).layers.first { $0.identity == first.identity })

        let effects = engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 6.9)
        let afterCancel = try #require(
            engine.sceneRenderSnapshot(at: 6.9).layers.first { $0.identity == first.identity })
        #expect(abs(afterCancel.opacity - beforeCancel.opacity) < 0.0001)
        #expect(abs(afterCancel.motionActiveTime - beforeCancel.motionActiveTime) < 0.0001)
        #expect(
            effects.contains { effect in
                guard case let .download(request) = effect else { return false }
                return request.identity == second.identity
            })
        for step in 0...40 {
            let snapshot = engine.sceneRenderSnapshot(at: 6.9 + Double(step) * 0.01)
            #expect(snapshot.underlyingPhase == .grace)
            #expect(SceneTransitionDiagnostic.photoCoverage(of: snapshot.layers.map(\.opacity)) >= 0.75 - 0.0001)
        }

        engine.reduceScenePresentation(.targetReady(second.identity), at: 7.4)
        let replay = engine.sceneRenderSnapshot(at: 7.5)
        #expect(replay.underlyingPhase == .transition)
        #expect(replay.layers.first { $0.identity == first.identity }?.role == .outgoing)
        #expect(replay.layers.first { $0.identity == second.identity }?.opacity == 0)
    }

    @Test
    func `previous during a hold raised onto the arriving photo finishes the crossfade to it`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        startAutomaticCrossfade(from: first, to: second, in: &engine)
        let incomingVisibleTimeSeconds: TimeInterval = 7.05
        let manualRequestTimeSeconds: TimeInterval = 7.1
        let elapsedFadeProgress: Double = 0.075
        engine.reduceScenePresentation(.incomingBecameVisible(second.identity), at: incomingVisibleTimeSeconds)
        engine.reduceScenePresentation(
            .request(target: third, source: .manualNext, readiness: .pending), at: manualRequestTimeSeconds)
        let beforeCancel = heldOpacity(of: second, in: engine, at: 7.3)

        let effects = engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 7.3)
        #expect(abs(heldOpacity(of: second, in: engine, at: 7.3) - beforeCancel) < 0.0001)
        #expect(engine.sceneRenderSnapshot(at: 7.3).underlyingPhase == .transition)
        let completion = try #require(
            effects.compactMap { effect -> TimeInterval? in
                guard case let .scheduleWakeUp(_, deadline) = effect else { return nil }
                return deadline
            }.first)
        #expect(
            abs(
                completion
                    - (manualRequestTimeSeconds + ScenePresentationPacingPolicy.manualReady.completionDuration
                        * (1 - elapsedFadeProgress))) < 0.001)

        engine.reduceScenePresentation(.transitionCompleted, at: completion)
        let settled = engine.sceneRenderSnapshot(at: completion)
        #expect(settled.underlyingPhase == .stablePhoto)
        #expect(settled.layers.map(\.identity) == [second.identity])
        #expect(settled.layers.first?.role == .stable)
    }

    @Test
    func `previous while paused during a raised hold does not fall back to the dim frame`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        startAutomaticCrossfade(from: first, to: second, in: &engine)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 6.7)
        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 6.8)
        engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 6.9)

        for time in [7.1, 30] {
            let paused = engine.sceneRenderSnapshot(at: time)
            #expect(paused.phase == .paused)
            #expect(abs(heldOpacity(of: first, in: engine, at: time) - 1) < 0.0001)
        }
    }

    @Test
    func `pausing while a photo is being raised lets it finish coming back up`() {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        startAutomaticCrossfade(from: first, to: second, in: &engine)
        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 6.99)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 7)

        #expect(engine.sceneRenderSnapshot(at: 7.5).phase == .paused)
        #expect(abs(heldOpacity(of: first, in: engine, at: 7.5) - 1) < 0.0001)
    }

    @Test
    func `pressing next in the black gap of an automatic crossfade brings back the photo that just faded out`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        startAutomaticCrossfade(from: first, to: second, in: &engine)
        #expect(
            SceneTransitionDiagnostic.photoCoverage(of: engine.sceneRenderSnapshot(at: 7.01).layers.map(\.opacity)) == 0
        )

        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 7.01)
        #expect(engine.sceneRenderSnapshot(at: 7.01).underlyingPhase == .grace)
        for time in [7.31, 8.5] {
            #expect(abs(heldOpacity(of: first, in: engine, at: time) - 1) < 0.0001)
            #expect(!engine.sceneRenderSnapshot(at: time).layers.contains { $0.identity == second.identity })
        }
    }

    @Test
    func `resuming playback while a raised photo is held keeps it up and starts its motion again`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        startAutomaticCrossfade(from: first, to: second, in: &engine)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 6.5)
        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 7)

        let pausedEarly = try #require(engine.sceneRenderSnapshot(at: 7).layers.first { $0.identity == first.identity })
        let pausedLater = try #require(
            engine.sceneRenderSnapshot(at: 7.15).layers.first { $0.identity == first.identity })
        #expect(pausedLater.motionActiveTime == pausedEarly.motionActiveTime)
        #expect(abs(pausedLater.opacity - 1) < 0.0001)

        engine.reduceScenePresentation(.resume(.userPaused), at: 7.2)
        let resumedEarly = try #require(
            engine.sceneRenderSnapshot(at: 7.3).layers.first { $0.identity == first.identity })
        let resumedLater = try #require(
            engine.sceneRenderSnapshot(at: 7.8).layers.first { $0.identity == first.identity })
        #expect(engine.sceneRenderSnapshot(at: 7.8).underlyingPhase == .grace)
        #expect(abs(resumedLater.opacity - 1) < 0.0001)
        #expect(resumedLater.motionActiveTime > resumedEarly.motionActiveTime)

        engine.reduceScenePresentation(.targetReady(third.identity), at: 8)
        let crossfade = engine.sceneRenderSnapshot(at: 8.1)
        #expect(crossfade.underlyingPhase == .transition)
        #expect((crossfade.layers.first { $0.identity == third.identity }?.opacity ?? 0) > 0)
    }

    @Test
    func `a manual next with nothing on screen drops the replaced target and its pending wake-up`() {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .pending), at: 0)
        engine.reduceScenePresentation(.targetReady(first.identity), at: 1)
        #expect(
            SceneTransitionDiagnostic.photoCoverage(of: engine.sceneRenderSnapshot(at: 1).layers.map(\.opacity)) == 0)

        let effects = engine.reduceScenePresentation(
            .request(target: second, source: .manualNext, readiness: .pending), at: 1)
        #expect(
            effects.contains { effect in
                guard case .cancelWakeUp = effect else { return false }
                return true
            })
        let loading = engine.sceneRenderSnapshot(at: 1.5)
        #expect(loading.underlyingPhase == .loading)
        #expect(loading.layers.map(\.identity) == [second.identity])

        engine.reduceScenePresentation(.targetReady(second.identity), at: 1.6)
        engine.reduceScenePresentation(.transitionCompleted, at: 1.9)
        #expect(engine.sceneRenderSnapshot(at: 2).layers.map(\.identity) == [second.identity])
    }

    @Test
    func `a second next during a raised hold lets the photo behind finish fading out`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        let fourth = makeManualLifecycleTarget(sceneID: "fourth", interval: 5)
        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.request(target: second, source: .manualNext, readiness: .pending), at: 1.5)
        engine.reduceScenePresentation(.targetReady(second.identity), at: 2)
        engine.reduceScenePresentation(.incomingBecameVisible(second.identity), at: 2.05)
        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 2.1)
        engine.reduceScenePresentation(.request(target: fourth, source: .manualNext, readiness: .pending), at: 2.15)

        #expect(heldOpacity(of: first, in: engine, at: 2.2) < heldOpacity(of: first, in: engine, at: 2.15))
        #expect(heldOpacity(of: first, in: engine, at: 2.3) < 0.000_001)

        let effects = engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 2.2)
        let completion = try #require(
            effects.compactMap { effect -> TimeInterval? in
                guard case let .scheduleWakeUp(_, deadline) = effect else { return nil }
                return deadline
            }.first)
        engine.reduceScenePresentation(.transitionCompleted, at: completion)
        let settled = engine.sceneRenderSnapshot(at: completion)
        #expect(settled.underlyingPhase == .stablePhoto)
        #expect(settled.layers.map(\.identity) == [second.identity])
    }

    @Test
    func `backgrounding while a photo is being raised finishes the raise at once`() {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        startAutomaticCrossfade(from: first, to: second, in: &engine)
        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 6.75)
        #expect(heldOpacity(of: first, in: engine, at: 6.8) < 1)

        engine.reduceScenePresentation(.suspend(.background), at: 6.8)
        #expect(abs(heldOpacity(of: first, in: engine, at: 6.8) - 1) < 0.0001)
        #expect(
            engine.sceneRenderSnapshot(at: 6.8).layers.allSatisfy { $0.identity == first.identity || $0.opacity == 0 })

        engine.reduceScenePresentation(.resume(.background), at: 10)
        #expect(abs(heldOpacity(of: first, in: engine, at: 10) - 1) < 0.0001)
    }

    @Test
    func `a target that became ready in the background crossfades from the fully raised photo on return`() {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        startAutomaticCrossfade(from: first, to: second, in: &engine)
        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 6.75)
        engine.reduceScenePresentation(.suspend(.background), at: 6.8)
        engine.reduceScenePresentation(.targetReady(third.identity), at: 8)
        engine.reduceScenePresentation(.resume(.background), at: 10)

        for step in 0...40 {
            let snapshot = engine.sceneRenderSnapshot(at: 10 + Double(step) * 0.01)
            #expect(
                SceneTransitionDiagnostic.photoCoverage(of: snapshot.layers.map(\.opacity))
                    >= SceneTransitionDiagnostic.minimumPhotoCoverage)
        }
        #expect(engine.sceneRenderSnapshot(at: 10.2).underlyingPhase == .transition)
    }

    @Test
    func `a raise cut short by the background while paused comes back fully up and still`() {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        startAutomaticCrossfade(from: first, to: second, in: &engine)
        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 6.75)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 6.78)
        engine.reduceScenePresentation(.suspend(.background), at: 6.8)
        engine.reduceScenePresentation(.resume(.background), at: 10)

        let returned = engine.sceneRenderSnapshot(at: 10)
        let motionAtReturn = returned.layers.first { $0.identity == first.identity }?.motionActiveTime
        #expect(returned.phase == .paused)
        #expect(abs(heldOpacity(of: first, in: engine, at: 10) - 1) < 0.0001)
        let later = engine.sceneRenderSnapshot(at: 11)
        #expect(later.layers.first { $0.identity == first.identity }?.motionActiveTime == motionAtReturn)
    }

    @Test
    func `a raise kept up by previous finishes when paused and when the app goes to the background`() {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        startAutomaticCrossfade(from: first, to: second, in: &engine)
        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 6.75)
        engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 6.78)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 6.79)
        #expect(abs(heldOpacity(of: first, in: engine, at: 7.5) - 1) < 0.0001)

        var backgrounded = PlaybackSessionEngine()
        startAutomaticCrossfade(from: first, to: second, in: &backgrounded)
        backgrounded.reduceScenePresentation(
            .request(target: third, source: .manualNext, readiness: .pending), at: 6.75)
        backgrounded.reduceScenePresentation(.suspend(.userPaused), at: 6.78)
        backgrounded.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 6.79)
        backgrounded.reduceScenePresentation(.suspend(.background), at: 6.8)
        backgrounded.reduceScenePresentation(.targetReady(second.identity), at: 8)
        backgrounded.reduceScenePresentation(.resume(.background), at: 10)
        #expect(abs(heldOpacity(of: first, in: backgrounded, at: 10) - 1) < 0.0001)
        #expect(abs(heldOpacity(of: first, in: backgrounded, at: 30) - 1) < 0.0001)
    }

    @Test
    func `a raise onto a seen photo kept up by previous stays up when paused or backgrounded`() {
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        var paused = PlaybackSessionEngine()
        startAutomaticCrossfade(from: first, to: second, in: &paused)
        paused.reduceScenePresentation(.incomingBecameVisible(second.identity), at: 7.05)
        paused.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 7.1)
        paused.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 7.12)
        paused.reduceScenePresentation(.suspend(.userPaused), at: 7.13)
        for time in [7.5, 30] {
            #expect(abs(heldOpacity(of: second, in: paused, at: time) - 1) < 0.0001)
        }

        var backgrounded = PlaybackSessionEngine()
        startAutomaticCrossfade(from: first, to: second, in: &backgrounded)
        backgrounded.reduceScenePresentation(.incomingBecameVisible(second.identity), at: 7.05)
        backgrounded.reduceScenePresentation(
            .request(target: third, source: .manualNext, readiness: .pending), at: 7.1)
        backgrounded.reduceScenePresentation(.suspend(.userPaused), at: 7.11)
        backgrounded.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 7.12)
        backgrounded.reduceScenePresentation(.suspend(.background), at: 7.13)
        backgrounded.reduceScenePresentation(.resume(.background), at: 10)
        for time: TimeInterval in [10, 30] {
            #expect(abs(heldOpacity(of: second, in: backgrounded, at: time) - 1) < 0.0001)
        }
    }

    @Test
    func `a target ready before the raised photo is fully up crossfades only once it is`() throws {
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        var manual = PlaybackSessionEngine()
        startAutomaticCrossfade(from: first, to: second, in: &manual)
        manual.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 6.75)
        let readyEffects = manual.reduceScenePresentation(.targetReady(third.identity), at: 6.8)
        let raiseEnd = try #require(wakeUpDeadline(in: readyEffects))
        #expect(abs(raiseEnd - 6.975) < 0.0001)
        #expect(manual.sceneRenderSnapshot(at: 6.9).underlyingPhase == .grace)

        // Sample each moment before the next event, so every snapshot shows what was on screen then.
        for step in 0...14 {
            expectPhotoCovered(manual.sceneRenderSnapshot(at: 6.83 + Double(step) * 0.01))
        }
        let crossfadeEffects = manual.reduceScenePresentation(
            .wakeUp(generation: third.identity.generation, deadline: raiseEnd), at: raiseEnd)
        #expect(manual.sceneRenderSnapshot(at: raiseEnd).underlyingPhase == .transition)
        // A manual target keeps the short manual crossfade.
        let completion = try #require(wakeUpDeadline(in: crossfadeEffects))
        #expect(abs(completion - (raiseEnd + ScenePresentationPacingPolicy.manualReady.completionDuration)) < 0.0001)
        #expect(abs(heldOpacity(of: first, in: manual, at: raiseEnd) - 1) < 0.0001)
        for step in 0...40 {
            expectPhotoCovered(manual.sceneRenderSnapshot(at: raiseEnd + Double(step) * 0.01))
        }

        var replayed = PlaybackSessionEngine()
        startAutomaticCrossfade(from: first, to: second, in: &replayed)
        replayed.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 6.75)
        replayed.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 6.76)
        let replayEffects = replayed.reduceScenePresentation(.targetReady(second.identity), at: 6.8)
        let replayStart = try #require(wakeUpDeadline(in: replayEffects))
        #expect(abs(replayStart - 6.975) < 0.0001)
        replayed.reduceScenePresentation(
            .wakeUp(generation: second.identity.generation, deadline: replayStart), at: replayStart)
        #expect(replayed.sceneRenderSnapshot(at: replayStart).underlyingPhase == .transition)
        #expect(abs(heldOpacity(of: first, in: replayed, at: replayStart) - 1) < 0.0001)
    }

    @Test
    func `pausing while a ready manual target waits for the raised photo still cross fades it in`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        startAutomaticCrossfade(from: first, to: second, in: &engine)
        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 6.75)
        engine.reduceScenePresentation(.targetReady(third.identity), at: 6.8)
        let pauseEffects = engine.reduceScenePresentation(.suspend(.userPaused), at: 6.81)

        #expect(engine.sceneRenderSnapshot(at: 6.9).underlyingPhase == .transition)
        let completion = try #require(wakeUpDeadline(in: pauseEffects))
        engine.reduceScenePresentation(
            .wakeUp(generation: third.identity.generation, deadline: completion), at: completion)
        let settled = engine.sceneRenderSnapshot(at: completion + 1)
        #expect(settled.phase == .paused)
        #expect(settled.layers.map(\.identity) == [third.identity])
    }

    @Test
    func `play during a raise waits for the raised photo before the restored crossfade`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeManualLifecycleTarget(sceneID: "first", interval: 5)
        let second = makeManualLifecycleTarget(sceneID: "second", interval: 5)
        let third = makeManualLifecycleTarget(sceneID: "third", interval: 5)
        startAutomaticCrossfade(from: first, to: second, in: &engine)
        engine.reduceScenePresentation(.request(target: third, source: .manualNext, readiness: .pending), at: 6.75)
        engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 6.76)
        engine.reduceScenePresentation(.targetReady(second.identity), at: 6.8)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 6.805)
        let playEffects = engine.reduceScenePresentation(.resume(.userPaused), at: 6.81)

        let start = try #require(wakeUpDeadline(in: playEffects))
        #expect(abs(start - 6.975) < 0.0001)
        #expect(engine.sceneRenderSnapshot(at: 6.9).underlyingPhase == .grace)
        engine.reduceScenePresentation(.wakeUp(generation: second.identity.generation, deadline: start), at: start)
        #expect(engine.sceneRenderSnapshot(at: start).underlyingPhase == .transition)
        #expect(abs(heldOpacity(of: first, in: engine, at: start) - 1) < 0.0001)
    }

    private func expectPhotoCovered(
        _ snapshot: PlaybackSessionEngine.SceneRenderSnapshot,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            SceneTransitionDiagnostic.photoCoverage(of: snapshot.layers.map(\.opacity))
                >= SceneTransitionDiagnostic.minimumPhotoCoverage,
            sourceLocation: sourceLocation)
    }

    private func wakeUpDeadline(in effects: [ScenePresentationEffect]) -> TimeInterval? {
        effects.compactMap { effect -> TimeInterval? in
            guard case let .scheduleWakeUp(_, deadline) = effect else { return nil }
            return deadline
        }.last
    }

    /// Settles `first`, then starts the automatic crossfade at 6 s: `first` fades out until 7 s and `second` fades in
    /// from 7.025 s, leaving 25 ms with no visible layer.
    private func startAutomaticCrossfade(
        from first: PlaybackSessionEngine.ScenePresentationTarget,
        to second: PlaybackSessionEngine.ScenePresentationTarget,
        in engine: inout PlaybackSessionEngine
    ) {
        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: second, readiness: .ready), at: 6)
    }

    private func heldOpacity(
        of target: PlaybackSessionEngine.ScenePresentationTarget,
        in engine: PlaybackSessionEngine,
        at time: TimeInterval
    ) -> Double {
        engine.sceneRenderSnapshot(at: time).layers.first { $0.identity == target.identity }?.opacity ?? 0
    }
}

private func makeManualLifecycleTarget(
    sceneID: String,
    interval: TimeInterval
) -> PlaybackSessionEngine.ScenePresentationTarget {
    PlaybackSessionEngine.ScenePresentationTarget(
        identity: .init(generation: UUID(), sceneID: sceneID),
        configuredInterval: interval
    )
}
