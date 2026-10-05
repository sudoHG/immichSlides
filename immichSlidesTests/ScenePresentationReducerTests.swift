import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct ScenePresentationReducerTests {
    @Test
    func `manual ready target becomes visible within 100ms and completes a short crossfade`() throws {
        var engine = PlaybackSessionEngine()
        let a = makeTarget(sceneID: "scene-a", interval: 5)
        let b = makeTarget(sceneID: "scene-b", interval: 5)

        engine.reduceScenePresentation(.start(target: a, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.request(target: b, source: .manualNext, readiness: .ready), at: 2)

        let visible = engine.sceneRenderSnapshot(at: 2.1)
        let incoming = try #require(visible.layers.first(where: { $0.identity == b.identity }))
        #expect(incoming.opacity > 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 2.3)
        #expect(engine.sceneRenderSnapshot(at: 2.35).phase == .stablePhoto)
    }

    @Test
    func `a manual pending target holds the current photo instead of fading it out or entering loading`() {
        var engine = PlaybackSessionEngine()
        let a = makeTarget(sceneID: "scene-a", interval: 5)
        let b = makeTarget(sceneID: "scene-b", interval: 5)

        engine.reduceScenePresentation(.start(target: a, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.request(target: b, source: .manualNext, readiness: .pending), at: 2)

        let halfSecondLater = engine.sceneRenderSnapshot(at: 2.5)
        #expect(halfSecondLater.underlyingPhase == .grace)
        #expect(halfSecondLater.layers.first { $0.identity == a.identity }?.opacity == 1)
        #expect(halfSecondLater.layers.first { $0.identity == a.identity }?.role == .stable)
    }

    @Test
    func `the reducer keeps the visible outgoing sample by stable identity and lets the latest manual target win`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let a = makeTarget(sceneID: "scene-a", interval: 5)
        let b = makeTarget(sceneID: "scene-b", interval: 8)
        let c = makeTarget(sceneID: "scene-c", interval: 10)

        engine.reduceScenePresentation(.start(target: a, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        let firstSnapshot = engine.sceneRenderSnapshot(at: 1)
        #expect(firstSnapshot.phase == .stablePhoto)
        #expect(firstSnapshot.layers.map(\.identity) == [a.identity])

        engine.reduceScenePresentation(
            .request(target: b, source: .manualNext, readiness: .ready),
            at: 2
        )
        let beforeReplacement = engine.sceneRenderSnapshot(at: 2.1)
        let outgoingBeforeReplacement = try #require(
            beforeReplacement.layers.first(where: { $0.identity == a.identity }))
        #expect(outgoingBeforeReplacement.role == .outgoing)
        #expect(outgoingBeforeReplacement.opacity > 0)

        engine.reduceScenePresentation(
            .request(target: c, source: .manualNext, readiness: .ready),
            at: 2.1
        )
        let afterReplacement = engine.sceneRenderSnapshot(at: 2.1)
        let outgoingAfterReplacement = try #require(afterReplacement.layers.first(where: { $0.identity == a.identity }))

        #expect(outgoingAfterReplacement.opacity == outgoingBeforeReplacement.opacity)
        #expect(afterReplacement.currentTarget?.identity == c.identity)
        #expect(afterReplacement.frozenInterval == 10)
        #expect(engine.sceneRenderSnapshot(at: 2.1) == afterReplacement)
    }

    @Test
    func `suspend and resume freeze then continue each layer's independent fade instead of pinning opacity`() throws {
        var engine = PlaybackSessionEngine()
        let a = makeTarget(sceneID: "scene-a", interval: 5)
        let b = makeTarget(sceneID: "scene-b", interval: 5)

        engine.reduceScenePresentation(.start(target: a, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(
            .request(target: b, source: .manualNext, readiness: .ready),
            at: 2
        )

        let beforePause = engine.sceneRenderSnapshot(at: 2.1)
        let opacityBeforePause = try #require(beforePause.layers.first(where: { $0.identity == a.identity }))
        #expect(abs(opacityBeforePause.opacity - (2.0 / 3.0)) < 0.0001)

        engine.reduceScenePresentation(.suspend(.userPaused), at: 2.1)
        let whilePaused = engine.sceneRenderSnapshot(at: 8)
        let pausedLayer = try #require(whilePaused.layers.first(where: { $0.identity == a.identity }))
        #expect(abs(pausedLayer.opacity - opacityBeforePause.opacity) < 0.0001)

        engine.reduceScenePresentation(.resume(.userPaused), at: 8)
        let resumed = engine.sceneRenderSnapshot(at: 8.1)
        let resumedLayer = try #require(resumed.layers.first(where: { $0.identity == a.identity }))
        #expect(abs(resumedLayer.opacity - (1.0 / 3.0)) < 0.0001)
    }

    @Test
    func `a pending hidden incoming does not fade in on its own across a suspend and resume before it is ready`() throws
    {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "visible-current", interval: 5)
        let pending = makeTarget(sceneID: "hidden-pending", interval: 5)

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: pending, readiness: .pending), at: 6)
        engine.reduceScenePresentation(.suspend(.background), at: 6.1)
        engine.reduceScenePresentation(.resume(.background), at: 10)

        let hidden = try #require(
            engine.sceneRenderSnapshot(at: 10.5).layers.first { $0.identity == pending.identity }
        )
        #expect(!hidden.isPresentationReady)
        #expect(hidden.opacity == 0)
        #expect(hidden.fadeStartTime == nil)
    }

    @Test
    func `a target becoming ready during grace begins the photo transition immediately`() throws {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "grace-current", interval: 5)
        let pending = makeTarget(sceneID: "grace-pending", interval: 5)

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: pending, readiness: .pending), at: 6)
        let effects = engine.reduceScenePresentation(.targetReady(pending.identity), at: 6.1)

        let transition = engine.sceneRenderSnapshot(at: 6.1)
        #expect(transition.underlyingPhase == .transition)
        #expect(transition.currentTarget?.identity == pending.identity)
        let incoming = try #require(
            transition.layers.first { $0.identity == pending.identity }
        )
        #expect(incoming.isPresentationReady)
        #expect(
            effects.contains { effect in
                guard case .scheduleWakeUp = effect else { return false }
                return true
            })
    }

    @Test
    func `a grace target that becomes ready in the background begins the photo transition once playback resumes`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "suspended-grace-current", interval: 5)
        let pending = makeTarget(sceneID: "suspended-grace-pending", interval: 5)

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: pending, readiness: .pending), at: 6)
        engine.reduceScenePresentation(.suspend(.background), at: 6.2)
        engine.reduceScenePresentation(.targetReady(pending.identity), at: 6.4)

        let resumeEffects = engine.reduceScenePresentation(.resume(.background), at: 10)
        let transition = engine.sceneRenderSnapshot(at: 10)

        #expect(transition.underlyingPhase == .transition)
        #expect(transition.currentTarget?.identity == pending.identity)
        #expect(
            resumeEffects.contains { effect in
                guard case .scheduleWakeUp = effect else { return false }
                return true
            })
    }

    @Test
    func `a hidden automatic grace target is not treated as a cancellable manual pending target`() {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "automatic-grace-current", interval: 5)
        let pending = makeTarget(sceneID: "automatic-grace-pending", interval: 5)

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: pending, readiness: .pending), at: 6)

        #expect(!engine.canCancelUnseenManualPendingScenePresentation)
    }

    @Test
    func `resuming a delayed incoming starts its motion at the same time as its fade`() throws {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "delayed-motion-current", interval: 5)
        let pending = makeTarget(sceneID: "delayed-motion-pending", interval: 5)

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: pending, readiness: .ready), at: 6)

        let beforeSuspend = engine.sceneRenderSnapshot(at: 6.5)
        let delayedIncoming = try #require(
            beforeSuspend.layers.first { $0.identity == pending.identity }
        )
        #expect((delayedIncoming.fadeStartTime ?? 0) > 6.5)

        engine.reduceScenePresentation(.suspend(.background), at: 6.5)
        engine.reduceScenePresentation(.resume(.background), at: 10)

        let afterResume = engine.sceneRenderSnapshot(at: 10)
        let resumedIncoming = try #require(
            afterResume.layers.first { $0.identity == pending.identity }
        )
        let fadeStart = try #require(resumedIncoming.fadeStartTime)
        let firstVisible = engine.sceneRenderSnapshot(at: fadeStart + 0.0001)
        let firstVisibleIncoming = try #require(
            firstVisible.layers.first { $0.identity == pending.identity }
        )

        #expect(firstVisibleIncoming.motionActiveTime < 0.001)
    }

    @Test
    func `cancelling an unseen manual pending target while paused restores the original stable deadline on play`() {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "paused-cancel-current", interval: 5)
        let pending = makeTarget(sceneID: "paused-cancel-pending", interval: 5)

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 2)
        engine.reduceScenePresentation(.request(target: pending, source: .manualNext, readiness: .pending), at: 3)
        engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 3.1)

        let resumeEffects = engine.reduceScenePresentation(.resume(.userPaused), at: 4)
        let restoredDeadlines = resumeEffects.compactMap { effect -> TimeInterval? in
            guard case let .scheduleWakeUp(_, deadline) = effect else { return nil }
            return deadline
        }

        #expect(engine.sceneRenderSnapshot(at: 4).underlyingPhase == .stablePhoto)
        #expect(restoredDeadlines.contains { abs($0 - 8) < 0.0001 })
    }

    @Test
    func `cancelling a manual pending target re-issues the interrupted automatic grace download`() {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "restore-grace-current", interval: 5)
        let automaticPending = makeTarget(sceneID: "restore-grace-automatic", interval: 5)
        let manualPending = makeTarget(sceneID: "restore-grace-manual", interval: 5)

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: automaticPending, readiness: .pending), at: 6)
        engine.reduceScenePresentation(
            .request(target: manualPending, source: .manualNext, readiness: .pending), at: 6.1)

        let restoreEffects = engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 6.2)
        let restoredPlans = restoreEffects.contains { effect in
            guard case let .restartPreparation(request) = effect else { return false }
            return request.identity == automaticPending.identity && request.source == .automatic
        }
        let restoredDownloads = restoreEffects.contains { effect in
            guard case let .download(request) = effect else { return false }
            return request.identity == automaticPending.identity && request.source == .automatic
        }

        #expect(engine.sceneRenderSnapshot(at: 6.2).underlyingPhase == .grace)
        #expect(restoredPlans)
        #expect(restoredDownloads)
    }

    @Test
    func
        `cancelling a manual target that interrupted an automatic crossfade keeps the raised photo and replays the crossfade`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "restore-transition-current", interval: 5)
        let automaticIncoming = makeTarget(sceneID: "restore-transition-automatic", interval: 5)
        let manualPending = makeTarget(sceneID: "restore-transition-manual", interval: 5)

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: automaticIncoming, readiness: .ready), at: 6)
        engine.reduceScenePresentation(
            .request(target: manualPending, source: .manualNext, readiness: .pending), at: 6.5)
        let restoreEffects = engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 6.7)

        let restored = engine.sceneRenderSnapshot(at: 6.7)
        let raised = try #require(restored.layers.first { $0.identity == current.identity })
        let waiting = try #require(restored.layers.first { $0.identity == automaticIncoming.identity })
        #expect(restored.underlyingPhase == .grace)
        #expect(abs(raised.opacity - 1) < 0.0001)
        #expect(waiting.opacity == 0)
        #expect(!waiting.isPresentationReady)
        #expect(
            restoreEffects.contains { effect in
                guard case let .download(request) = effect else { return false }
                return request.identity == automaticIncoming.identity && request.source == .automatic
            })

        engine.reduceScenePresentation(.targetReady(automaticIncoming.identity), at: 6.8)
        let replay = engine.sceneRenderSnapshot(at: 6.8)
        let replayOutgoing = try #require(replay.layers.first { $0.identity == current.identity })
        let replayIncoming = try #require(replay.layers.first { $0.identity == automaticIncoming.identity })
        #expect(replay.underlyingPhase == .transition)
        #expect(replayOutgoing.role == .outgoing)
        #expect(abs(replayOutgoing.opacity - 1) < 0.0001)
        let incomingFadeStart = try #require(replayIncoming.fadeStartTime)
        let firstIncomingFrame = try #require(
            engine.sceneRenderSnapshot(at: incomingFadeStart + 0.0001).layers.first {
                $0.identity == automaticIncoming.identity
            })
        #expect(firstIncomingFrame.motionActiveTime < 0.001)

        engine.reduceScenePresentation(.transitionCompleted, at: 8.825)
        let settled = engine.sceneRenderSnapshot(at: 8.825)
        #expect(settled.layers.allSatisfy { $0.identity != current.identity })
    }
    @Test
    func `multiple suspension reasons, ready reconciliation and the next interval template stay independent`() throws {
        var engine = PlaybackSessionEngine()
        let a = makeTarget(sceneID: "scene-a", interval: 5)
        let b = makeTarget(sceneID: "scene-b", interval: 8)

        engine.reduceScenePresentation(.start(target: a, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.intervalTemplateChanged(12), at: 2)
        let stableSnapshot = engine.sceneRenderSnapshot(at: 2)
        #expect(stableSnapshot.frozenInterval == 5)

        engine.reduceScenePresentation(.stableDeadlineReached(target: b, readiness: .pending), at: 6)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 6.2)
        engine.reduceScenePresentation(.suspend(.background), at: 6.3)
        engine.reduceScenePresentation(.targetReady(b.identity), at: 7)

        engine.reduceScenePresentation(.resume(.background), at: 9)
        let stillPaused = engine.sceneRenderSnapshot(at: 9)
        #expect(stillPaused.phase == .paused)
        #expect(stillPaused.isPendingTargetReady)

        let reconcileEffects = engine.reduceScenePresentation(.resume(.userPaused), at: 10)
        let reconciled = engine.sceneRenderSnapshot(at: 10)
        // Ready during nested pauses only fills in state; the photo transition starts as soon as the last pause reason
        // is cleared.
        #expect(reconciled.underlyingPhase == .transition)
        #expect(reconciled.currentTarget?.identity == b.identity)
        #expect(reconciled.frozenInterval == 8)
        #expect(
            reconcileEffects.contains { effect in
                guard case .scheduleWakeUp = effect else { return false }
                return true
            })
    }

    @Test
    func
        `a manual navigation made while user paused freezes in the background and settles its completed transition on foreground return`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeTarget(sceneID: "first", interval: 5)
        let second = makeTarget(sceneID: "second", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 2)
        engine.reduceScenePresentation(.request(target: second, source: .manualNext, readiness: .ready), at: 3)
        let beforeBackground = try #require(
            engine.sceneRenderSnapshot(at: 3.1).layers.first { $0.identity == second.identity }
        )

        engine.reduceScenePresentation(.suspend(.background), at: 3.1)
        engine.reduceScenePresentation(.transitionCompleted, at: 3.3)
        let whileBackground = try #require(
            engine.sceneRenderSnapshot(at: 30).layers.first { $0.identity == second.identity }
        )

        #expect(engine.sceneRenderSnapshot(at: 30).phase == .paused)
        #expect(whileBackground.opacity == beforeBackground.opacity)
        #expect(whileBackground.motionActiveTime == beforeBackground.motionActiveTime)

        engine.reduceScenePresentation(.resume(.background), at: 31)
        #expect(engine.sceneRenderSnapshot(at: 31).phase == .paused)
        #expect(engine.sceneRenderSnapshot(at: 31).underlyingPhase == .stablePhoto)
    }

    @Test
    func
        `a manual short crossfade started while user paused rebuilds its remaining completion deadline after returning from background`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeTarget(sceneID: "first", interval: 5)
        let second = makeTarget(sceneID: "second", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 2)
        engine.reduceScenePresentation(.request(target: second, source: .manualNext, readiness: .ready), at: 3)
        engine.reduceScenePresentation(.suspend(.background), at: 3.1)

        let resumeEffects = engine.reduceScenePresentation(.resume(.background), at: 31)
        guard case let .scheduleWakeUp(generation, deadline)? = resumeEffects.first else {
            #expect(
                Bool(false),
                "Back from background, still user paused: manual short fade must reschedule remaining deadline")
            return
        }
        #expect(abs(deadline - 31.2) < 0.0001)

        engine.reduceScenePresentation(.wakeUp(generation: generation, deadline: deadline), at: deadline)
        let settled = engine.sceneRenderSnapshot(at: deadline)
        #expect(settled.phase == .paused)
        #expect(settled.underlyingPhase == .stablePhoto)
        #expect(settled.currentTarget?.identity == second.identity)
        let settledLayer = try #require(settled.layers.first(where: { $0.identity == second.identity }))
        #expect(!settledLayer.isMotionEnabled)
    }

    @Test
    func
        `a paused manual pending target that becomes ready in the background enters its crossfade on returning to foreground`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeTarget(sceneID: "first", interval: 5)
        let second = makeTarget(sceneID: "second", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 2)
        engine.reduceScenePresentation(.request(target: second, source: .manualNext, readiness: .pending), at: 3)
        engine.reduceScenePresentation(.suspend(.background), at: 3.1)
        engine.reduceScenePresentation(.targetReady(second.identity), at: 3.2)

        #expect(engine.sceneRenderSnapshot(at: 30).underlyingPhase == .grace)
        #expect(engine.sceneRenderSnapshot(at: 30).layers.first { $0.identity == first.identity }?.opacity == 1)

        engine.reduceScenePresentation(.resume(.background), at: 31)
        let incoming = try #require(
            engine.sceneRenderSnapshot(at: 31.1).layers.first { $0.identity == second.identity }
        )
        #expect(engine.sceneRenderSnapshot(at: 31.1).underlyingPhase == .transition)
        #expect(incoming.opacity > 0)
        #expect(!incoming.isMotionEnabled)

        engine.reduceScenePresentation(.transitionCompleted, at: 31.3)
        let settled = engine.sceneRenderSnapshot(at: 31.3)
        #expect(settled.phase == .paused)
        #expect(settled.underlyingPhase == .stablePhoto)
        #expect(settled.currentTarget?.identity == second.identity)
    }

    @Test
    func
        `a paused initial scene that becomes ready in the background settles as the stable visible scene on foreground return`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeTarget(sceneID: "first", interval: 5)

        engine.reduceScenePresentation(.suspend(.userPaused), at: 0)
        engine.reduceScenePresentation(.start(target: first, readiness: .pending), at: 1)
        engine.reduceScenePresentation(.suspend(.background), at: 1.1)
        engine.reduceScenePresentation(.targetReady(first.identity), at: 1.2)

        engine.reduceScenePresentation(.resume(.background), at: 30)
        let visible = try #require(
            engine.sceneRenderSnapshot(at: 30).layers.first { $0.identity == first.identity }
        )
        #expect(engine.sceneRenderSnapshot(at: 30).phase == .paused)
        #expect(engine.sceneRenderSnapshot(at: 30).underlyingPhase == .stablePhoto)
        #expect(visible.opacity == 1)
        #expect(!visible.isMotionEnabled)
    }

    @Test
    func
        `a manual pending target that becomes ready after pressing play while paused restores automatic playback settlement`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let first = makeTarget(sceneID: "first", interval: 5)
        let second = makeTarget(sceneID: "second", interval: 5)

        engine.reduceScenePresentation(.start(target: first, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 2)
        engine.reduceScenePresentation(.request(target: second, source: .manualNext, readiness: .pending), at: 3)
        engine.reduceScenePresentation(.resume(.userPaused), at: 4)
        engine.reduceScenePresentation(.targetReady(second.identity), at: 5)
        let completionEffects = engine.reduceScenePresentation(.transitionCompleted, at: 5.3)

        let settled = engine.sceneRenderSnapshot(at: 6)
        let layer = try #require(settled.layers.first { $0.identity == second.identity })
        #expect(settled.phase == .stablePhoto)
        #expect(settled.currentTarget?.identity == second.identity)
        #expect(layer.isMotionEnabled)
        #expect(layer.motionActiveTime > 0)
        #expect(
            completionEffects.contains { effect in
                if case .scheduleWakeUp = effect { return true }
                return false
            })
    }

    @Test
    func
        `the first visible incoming commits history idempotently, an unseen target does not commit, and attempt counts include every retry`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let visible = makeTarget(sceneID: "visible", interval: 5)
        let unseen = makeTarget(sceneID: "unseen", interval: 5)
        let failing = makeTarget(sceneID: "failing", interval: 5)

        engine.reduceScenePresentation(.start(target: visible, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.incomingBecameVisible(visible.identity), at: 0.2)
        engine.reduceScenePresentation(.incomingBecameVisible(visible.identity), at: 0.3)
        engine.reduceScenePresentation(
            .request(target: unseen, source: .manualNext, readiness: .pending),
            at: 0.3
        )

        let historyState = engine.scenePresentationState
        #expect(historyState.history == [visible.identity])
        #expect(!historyState.history.contains(unseen.identity))

        var retryEngine = PlaybackSessionEngine()
        retryEngine.reduceScenePresentation(.start(target: failing, readiness: .pending), at: 0)
        for attempt in 0..<4 {
            let effects = retryEngine.reduceScenePresentation(
                .targetFailed(failing.identity), at: TimeInterval(attempt + 1))
            if attempt < 3 {
                #expect(
                    effects.contains(
                        .retry(.init(identity: failing.identity, source: .automatic), attemptNumber: attempt + 2)))
            }
        }
        let retryState = retryEngine.scenePresentationState
        #expect(retryState.attemptSummary.totalAttemptCount == 4)
        #expect(retryState.attemptSummary.failedAttemptCount == 4)
        #expect(retryState.attemptSummary.pendingAttemptCount == 0)
    }
}
