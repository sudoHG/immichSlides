import Foundation
import Testing
@testable import immichSlides

extension ScenePresentationReducerTests {
    @Test
    func
        `a stable scene from a paused startup commits its initial history exactly once and supports previous after next`()
    {
        var engine = PlaybackSessionEngine()
        let first = makeTarget(sceneID: "first", interval: 5)
        let second = makeTarget(sceneID: "second", interval: 5)

        engine.reduceScenePresentation(.suspend(.userPaused), at: 0)
        engine.reduceScenePresentation(.start(target: first, readiness: .pending), at: 1)
        engine.reduceScenePresentation(.targetReady(first.identity), at: 2)
        engine.reduceScenePresentation(.incomingBecameVisible(first.identity), at: 2.1)
        engine.reduceScenePresentation(.incomingBecameVisible(first.identity), at: 2.2)

        engine.reduceScenePresentation(.request(target: second, source: .manualNext, readiness: .ready), at: 3)
        engine.reduceScenePresentation(.transitionCompleted, at: 3.3)
        engine.reduceScenePresentation(.incomingBecameVisible(second.identity), at: 3.4)
        engine.reduceScenePresentation(.request(target: first, source: .manualPrevious, readiness: .ready), at: 4)

        #expect(engine.scenePresentationState.history == [first.identity, second.identity])
        #expect(engine.sceneRenderSnapshot(at: 4).currentTarget?.identity == first.identity)
    }

    @Test
    func
        `enabling reduce motion mid scene freezes the current sample and only the next scene restores motion once disabled`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let a = makeTarget(sceneID: "scene-a", interval: 5)
        let b = makeTarget(sceneID: "scene-b", interval: 5)

        engine.reduceScenePresentation(.start(target: a, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.reduceMotionChanged(true), at: 0.4)
        engine.reduceScenePresentation(.reduceMotionChanged(false), at: 0.5)

        let current = engine.sceneRenderSnapshot(at: 0.8)
        let currentLayer = try #require(current.layers.first)
        #expect(currentLayer.isMotionEnabled)
        #expect(abs(currentLayer.motionActiveTime - 0.4) < 0.0001)

        engine.reduceScenePresentation(
            .request(target: b, source: .manualNext, readiness: .ready),
            at: 0.8
        )
        let next = engine.sceneRenderSnapshot(at: 1.9)
        let nextLayer = try #require(next.layers.first(where: { $0.identity == b.identity }))
        #expect(nextLayer.isMotionEnabled)
    }

    @Test
    func
        `toggling reduce motion on and off does not permanently freeze an automatic incoming that has not faded in yet`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "delayed-incoming-current", interval: 5)
        let incoming = makeTarget(sceneID: "delayed-incoming-next", interval: 5)

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: incoming, readiness: .ready), at: 6)
        engine.reduceScenePresentation(.reduceMotionChanged(true), at: 6.2)
        engine.reduceScenePresentation(.reduceMotionChanged(false), at: 6.4)

        let visibleIncoming = try #require(
            engine.sceneRenderSnapshot(at: 7.5).layers.first { $0.identity == incoming.identity }
        )
        #expect(visibleIncoming.opacity > 0)
        #expect(abs(visibleIncoming.motionActiveTime - 0.475) < 0.0001)
    }

    @Test
    func `enabling reduce motion before a delayed incoming becomes visible keeps its first frame at identity`() throws {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "reduce-motion-current", interval: 5)
        let incoming = makeTarget(sceneID: "reduce-motion-incoming", interval: 5)

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: incoming, readiness: .ready), at: 6)
        engine.reduceScenePresentation(.reduceMotionChanged(true), at: 6.2)

        let visibleIncoming = try #require(
            engine.sceneRenderSnapshot(at: 7.5).layers.first { $0.identity == incoming.identity }
        )
        #expect(visibleIncoming.opacity > 0)
        #expect(!visibleIncoming.isMotionEnabled)
    }

    @Test
    func `disabling reduce motion during suspension restores a delayed incoming's motion at its original fade start`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "suspended-reduce-motion-current", interval: 5)
        let incoming = makeTarget(sceneID: "suspended-reduce-motion-incoming", interval: 5)

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: incoming, readiness: .ready), at: 6)
        engine.reduceScenePresentation(.reduceMotionChanged(true), at: 6.2)
        engine.reduceScenePresentation(.suspend(.background), at: 6.4)
        engine.reduceScenePresentation(.reduceMotionChanged(false), at: 7)
        engine.reduceScenePresentation(.resume(.background), at: 10)

        let resumedIncoming = try #require(
            engine.sceneRenderSnapshot(at: 10).layers.first { $0.identity == incoming.identity }
        )
        let resumedFadeStart = try #require(resumedIncoming.fadeStartTime)
        let firstVisibleIncoming = try #require(
            engine.sceneRenderSnapshot(at: resumedFadeStart + 0.0001).layers.first {
                $0.identity == incoming.identity
            }
        )
        let progressedIncoming = try #require(
            engine.sceneRenderSnapshot(at: resumedFadeStart + 0.2).layers.first {
                $0.identity == incoming.identity
            }
        )

        #expect(firstVisibleIncoming.isMotionEnabled)
        #expect(firstVisibleIncoming.motionActiveTime < 0.001)
        #expect(abs(progressedIncoming.motionActiveTime - 0.2) < 0.0001)
    }

    @Test
    func
        `cancelling a manual pending target brings the automatic incoming back under the current reduce motion state`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "manual-restore-reduce-motion-current", interval: 5)
        let automaticIncoming = makeTarget(sceneID: "manual-restore-reduce-motion-automatic", interval: 5)
        let manualPending = makeTarget(sceneID: "manual-restore-reduce-motion-manual", interval: 5)

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: automaticIncoming, readiness: .ready), at: 6)
        engine.reduceScenePresentation(.reduceMotionChanged(true), at: 6.1)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 6.2)
        engine.reduceScenePresentation(
            .request(target: manualPending, source: .manualNext, readiness: .pending),
            at: 6.3
        )
        engine.reduceScenePresentation(.reduceMotionChanged(false), at: 6.35)
        engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 6.4)

        engine.reduceScenePresentation(.resume(.userPaused), at: 8)
        // The automatic incoming decodes again behind the held photo, then its crossfade starts.
        engine.reduceScenePresentation(.targetReady(automaticIncoming.identity), at: 8)
        let resumedIncoming = try #require(
            engine.sceneRenderSnapshot(at: 8).layers.first { $0.identity == automaticIncoming.identity }
        )
        let resumedFadeStart = try #require(resumedIncoming.fadeStartTime)
        let firstVisibleIncoming = try #require(
            engine.sceneRenderSnapshot(at: resumedFadeStart + 0.0001).layers.first {
                $0.identity == automaticIncoming.identity
            }
        )
        let progressedIncoming = try #require(
            engine.sceneRenderSnapshot(at: resumedFadeStart + 0.2).layers.first {
                $0.identity == automaticIncoming.identity
            }
        )

        #expect(firstVisibleIncoming.isMotionEnabled)
        #expect(firstVisibleIncoming.motionActiveTime < 0.001)
        #expect(abs(progressedIncoming.motionActiveTime - 0.2) < 0.0001)
    }

    @Test
    func `toggling reduce motion and then resuming from background keeps the current layer's frozen sample`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeTarget(sceneID: "first", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.reduceMotionChanged(true), at: 2)
        let frozen = try #require(
            engine.sceneRenderSnapshot(at: 2).layers.first { $0.identity == first.identity }
        )
        engine.reduceScenePresentation(.reduceMotionChanged(false), at: 3)
        engine.reduceScenePresentation(.suspend(.background), at: 4)
        engine.reduceScenePresentation(.resume(.background), at: 10)

        let afterForeground = try #require(
            engine.sceneRenderSnapshot(at: 11).layers.first { $0.identity == first.identity }
        )
        #expect(afterForeground.isMotionEnabled)
        #expect(abs(afterForeground.motionActiveTime - frozen.motionActiveTime) < 0.0001)
    }

    @Test
    func
        `a stable restore frozen during a manual pending keeps its reduce motion freeze across a background and foreground cycle`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "manual-restore-visible-stable", interval: 5)
        let manualPending = makeTarget(sceneID: "manual-restore-stable-pending", interval: 5)

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(
            .request(target: manualPending, source: .manualNext, readiness: .pending),
            at: 2
        )
        engine.reduceScenePresentation(.reduceMotionChanged(true), at: 2.1)
        engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 2.2)

        let restored = try #require(
            engine.sceneRenderSnapshot(at: 2.2).layers.first { $0.identity == current.identity }
        )
        engine.reduceScenePresentation(.reduceMotionChanged(false), at: 2.3)
        engine.reduceScenePresentation(.suspend(.background), at: 2.4)
        engine.reduceScenePresentation(.resume(.background), at: 4)

        let afterForeground = try #require(
            engine.sceneRenderSnapshot(at: 5).layers.first { $0.identity == current.identity }
        )
        #expect(afterForeground.isMotionEnabled)
        #expect(abs(afterForeground.motionActiveTime - restored.motionActiveTime) < 0.0001)
    }

    @Test
    func `a reduce motion toggle during a raised hold keeps the continued crossfade frozen after previous`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let outgoingTarget = makeTarget(sceneID: "manual-restore-visible-outgoing", interval: 5)
        let incomingTarget = makeTarget(sceneID: "manual-restore-visible-incoming", interval: 5)
        let manualPending = makeTarget(sceneID: "manual-restore-transition-pending", interval: 5)

        engine.reduceScenePresentation(.start(target: outgoingTarget, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(
            .request(target: incomingTarget, source: .manualNext, readiness: .ready),
            at: 2
        )
        engine.reduceScenePresentation(.incomingBecameVisible(incomingTarget.identity), at: 2.05)
        engine.reduceScenePresentation(
            .request(target: manualPending, source: .manualNext, readiness: .pending),
            at: 2.1
        )
        engine.reduceScenePresentation(.reduceMotionChanged(true), at: 2.12)
        engine.reduceScenePresentation(.reduceMotionChanged(false), at: 2.13)
        engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 2.14)

        let restored = engine.sceneRenderSnapshot(at: 2.14)
        let restoredOutgoing = try #require(
            restored.layers.first { $0.identity == outgoingTarget.identity }
        )
        let restoredIncoming = try #require(
            restored.layers.first { $0.identity == incomingTarget.identity }
        )
        engine.reduceScenePresentation(.suspend(.userPaused), at: 2.18)
        engine.reduceScenePresentation(.resume(.userPaused), at: 3)

        let resumed = engine.sceneRenderSnapshot(at: 3.1)
        let resumedOutgoing = try #require(
            resumed.layers.first { $0.identity == outgoingTarget.identity }
        )
        let resumedIncoming = try #require(
            resumed.layers.first { $0.identity == incomingTarget.identity }
        )

        #expect(abs(resumedOutgoing.motionActiveTime - restoredOutgoing.motionActiveTime) < 0.0001)
        #expect(abs(resumedIncoming.motionActiveTime - restoredIncoming.motionActiveTime) < 0.0001)
        #expect(resumedOutgoing.opacity < restoredOutgoing.opacity)
        #expect(resumedIncoming.opacity > restoredIncoming.opacity)
    }

    @Test
    func `cancelling a hold while paused keeps the raised photo up until play and the automatic target are ready`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "paused-restore-current", interval: 5)
        let automaticIncoming = makeTarget(sceneID: "paused-restore-automatic", interval: 5)
        let manualPending = makeTarget(sceneID: "paused-restore-manual", interval: 5)

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: automaticIncoming, readiness: .ready), at: 6)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 6.2)
        engine.reduceScenePresentation(
            .request(target: manualPending, source: .manualNext, readiness: .pending),
            at: 6.3
        )
        engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 6.4)

        for time in [6.4, 7] {
            let paused = engine.sceneRenderSnapshot(at: time)
            #expect(paused.phase == .paused)
            #expect(paused.underlyingPhase == .grace)
            #expect(abs((paused.layers.first { $0.identity == current.identity }?.opacity ?? 0) - 1) < 0.0001)
            #expect(paused.layers.first { $0.identity == automaticIncoming.identity }?.opacity == 0)
        }

        engine.reduceScenePresentation(.resume(.userPaused), at: 7.1)
        let early = try #require(engine.sceneRenderSnapshot(at: 7.2).layers.first { $0.identity == current.identity })
        let later = try #require(engine.sceneRenderSnapshot(at: 7.3).layers.first { $0.identity == current.identity })
        #expect(abs(later.opacity - 1) < 0.0001)
        #expect(later.motionActiveTime > early.motionActiveTime)

        engine.reduceScenePresentation(.targetReady(automaticIncoming.identity), at: 7.3)
        let fading = try #require(engine.sceneRenderSnapshot(at: 7.4).layers.first { $0.identity == current.identity })
        #expect(fading.role == .outgoing)
        #expect(fading.opacity < 1)
    }
    @Test
    func `cancelling a pending target during a paused manual crossfade finishes that crossfade without a jump`() throws
    {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "nested-manual-current", interval: 5)
        let manualReady = makeTarget(sceneID: "nested-manual-ready", interval: 5)
        let manualPending = makeTarget(sceneID: "nested-manual-pending", interval: 5)

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 2)
        engine.reduceScenePresentation(
            .request(target: manualReady, source: .manualNext, readiness: .ready),
            at: 3
        )
        engine.reduceScenePresentation(.incomingBecameVisible(manualReady.identity), at: 3.05)

        engine.reduceScenePresentation(
            .request(target: manualPending, source: .manualNext, readiness: .pending),
            at: 3.1
        )
        engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 3.2)

        // The crossfade kept its pace through the hold and the cancel, so nothing jumps back.
        for (time, incoming, outgoing) in [(3.2, 2.0 / 3.0, 1.0 / 3.0), (3.25, 5.0 / 6.0, 1.0 / 6.0)] {
            let snapshot = engine.sceneRenderSnapshot(at: time)
            let continuedIncoming = try #require(snapshot.layers.first { $0.identity == manualReady.identity })
            let continuedOutgoing = try #require(snapshot.layers.first { $0.identity == current.identity })
            #expect(abs(continuedIncoming.opacity - incoming) < 0.0001)
            #expect(abs(continuedOutgoing.opacity - outgoing) < 0.0001)
        }

        engine.reduceScenePresentation(.transitionCompleted, at: 3.4)
        let completed = engine.sceneRenderSnapshot(at: 3.4)
        let settledIncoming = try #require(completed.layers.first { $0.identity == manualReady.identity })
        let retiredOutgoingOpacity = completed.layers.first { $0.identity == current.identity }?.opacity ?? 0
        #expect(settledIncoming.role == .stable)
        #expect(settledIncoming.opacity == 1)
        #expect(retiredOutgoingOpacity < 0.0001)
    }

    @Test
    func
        `an incoming fade resumes by interpolating its remaining amount and reduce motion does not block the fade lifecycle`()
        throws
    {
        var standardEngine = PlaybackSessionEngine()
        let standard = makeTarget(sceneID: "standard", interval: 5)
        standardEngine.reduceScenePresentation(.start(target: standard, readiness: .ready), at: 0)
        standardEngine.reduceScenePresentation(.suspend(.userPaused), at: 0.5)
        standardEngine.reduceScenePresentation(.resume(.userPaused), at: 10)
        let standardMidpoint = try #require(
            standardEngine.sceneRenderSnapshot(at: 10.25).layers.first { $0.identity == standard.identity }
        )
        let standardEnd = try #require(
            standardEngine.sceneRenderSnapshot(at: 10.5).layers.first { $0.identity == standard.identity }
        )
        #expect(abs(standardMidpoint.opacity - 0.75) < 0.0001)
        #expect(standardEnd.opacity == 1)

        var reducedMotionEngine = PlaybackSessionEngine()
        let reduced = makeTarget(sceneID: "reduced", interval: 5)
        reducedMotionEngine.reduceScenePresentation(.reduceMotionChanged(true), at: 0)
        reducedMotionEngine.reduceScenePresentation(.start(target: reduced, readiness: .ready), at: 0)
        reducedMotionEngine.reduceScenePresentation(.suspend(.userPaused), at: 0.5)
        reducedMotionEngine.reduceScenePresentation(.resume(.userPaused), at: 10)
        let reducedMidpoint = try #require(
            reducedMotionEngine.sceneRenderSnapshot(at: 10.25).layers.first { $0.identity == reduced.identity }
        )
        let reducedEnd = try #require(
            reducedMotionEngine.sceneRenderSnapshot(at: 10.5).layers.first { $0.identity == reduced.identity }
        )
        #expect(abs(reducedMidpoint.opacity - 0.75) < 0.0001)
        #expect(reducedEnd.opacity == 1)
        #expect(!reducedMidpoint.isMotionEnabled)
    }

    @Test
    func `an incoming fade keeps the same remaining rate across two consecutive suspend and resume cycles`() throws {
        var engine = PlaybackSessionEngine()
        let target = makeTarget(sceneID: "repeated-fade", interval: 5)

        engine.reduceScenePresentation(.start(target: target, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 0.5)
        engine.reduceScenePresentation(.resume(.userPaused), at: 10)
        engine.reduceScenePresentation(.suspend(.background), at: 10.25)
        engine.reduceScenePresentation(.resume(.background), at: 20)

        let midpoint = try #require(
            engine.sceneRenderSnapshot(at: 20.125).layers.first { $0.identity == target.identity }
        )
        let end = try #require(
            engine.sceneRenderSnapshot(at: 20.25).layers.first { $0.identity == target.identity }
        )

        #expect(abs(midpoint.opacity - 0.875) < 0.0001)
        #expect(end.opacity == 1)
    }

    func makeTarget(
        sceneID: String,
        interval: TimeInterval
    ) -> PlaybackSessionEngine.ScenePresentationTarget {
        PlaybackSessionEngine.ScenePresentationTarget(
            identity: .init(generation: UUID(), sceneID: sceneID, assetID: "asset-\(sceneID)"),
            configuredInterval: interval
        )
    }
}
