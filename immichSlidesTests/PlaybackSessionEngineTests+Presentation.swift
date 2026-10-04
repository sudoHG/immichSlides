import Foundation
import Testing
@testable import immichSlides

extension PlaybackSessionEngineTests {
    @Test
    func `beginScenePresentation atomically commits navigation and drives the transition from a single snapshot`()
        throws
    {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let initialResult = engine.startScenePresentation(configuredInterval: 5, at: 0)
        let initial = try #require(initialResult)
        engine.reduceScenePresentation(.targetReady(initial.identity), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        let fromSceneId = initial.identity.sceneID

        let transition = engine.requestNext(candidate: makeAsset(id: "asset-1"), source: .manualNext)
        let startedResult = engine.beginScenePresentation(
            for: transition,
            configuredInterval: 5,
            requestSource: .manualNext,
            isAutomaticStableDeadline: false,
            at: 2
        )
        let started = try #require(startedResult)
        let transitionSnapshot = engine.sceneRenderSnapshot(at: 2)

        #expect(engine.currentScene?.id == transition.scene.id)
        // The unseen manual target decodes behind the scene that is still on screen.
        #expect(transitionSnapshot.phase == .grace)
        #expect(transitionSnapshot.layers.map(\.role) == [.stable, .incoming])
        #expect(transitionSnapshot.layers.map(\.identity.sceneID) == [fromSceneId, transition.scene.id])
        #expect(transitionSnapshot.layers.map(\.opacity) == [1, 0])

        engine.reduceScenePresentation(.targetReady(started.identity), at: 2.2)
        engine.reduceScenePresentation(.transitionCompleted, at: 4.025)
        engine.reduceScenePresentation(.transitionCompleted, at: 5.025)
        let settledSnapshot = engine.sceneRenderSnapshot(at: 5.025)

        #expect(settledSnapshot.phase == .stablePhoto)
        #expect(settledSnapshot.layers.map(\.role) == [.stable])
        #expect(settledSnapshot.layers.map(\.identity) == [started.identity])
    }

    @Test
    func `a manual short crossfade scene reaches the single photo zoom endpoint over its full visible window`() throws {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "manual-motion-initial")], reason: .sourceChanged)

        let transition = engine.requestNext(
            candidate: makeAsset(id: "manual-motion-next"),
            source: .manualNext
        )
        let startedResult = engine.beginScenePresentation(
            for: transition,
            configuredInterval: 5,
            requestSource: .manualNext,
            isAutomaticStableDeadline: false,
            at: 2
        )
        let started = try #require(startedResult)
        let target = try #require(engine.presentationTarget(for: started.identity))
        let profile = SceneAnimationProfile(lifecycle: target.lifecycle)

        let expectedMotionDurationSeconds: TimeInterval = 7.3
        let expectedZoomOutScale: Double = 1
        let expectedZoomInScale: Double = 1.10
        let motionDurationToleranceSeconds: TimeInterval = 0.0001
        let scaleComparisonTolerance: Double = 0.0001
        #expect(
            abs(target.lifecycle.longestVisibleMotionDuration - expectedMotionDurationSeconds)
                < motionDurationToleranceSeconds)
        let zoomOut = profile.singlePhotoTransform(
            direction: .zoomOut,
            activeTime: target.lifecycle.longestVisibleMotionDuration,
            isMotionEnabled: true
        )
        let zoomIn = profile.singlePhotoTransform(
            direction: .zoomIn,
            activeTime: target.lifecycle.longestVisibleMotionDuration,
            isMotionEnabled: true
        )
        #expect(abs(zoomOut.scale - expectedZoomOutScale) < scaleComparisonTolerance)
        #expect(abs(zoomIn.scale - expectedZoomInScale) < scaleComparisonTolerance)
    }

    @Test
    func `a paused target shortens its motion window only for the incoming fade it actually skipped`() throws {
        var initialEngine = PlaybackSessionEngine()
        initialEngine.reset(with: [makeAsset(id: "paused-initial")], reason: .sourceChanged)
        initialEngine.reduceScenePresentation(.suspend(.userPaused), at: 0)
        let initialResult = initialEngine.startScenePresentation(configuredInterval: 5, at: 1)
        let initial = try #require(initialResult)
        let pendingInitialTarget = try #require(initialEngine.presentationTarget(for: initial.identity))
        #expect(abs(pendingInitialTarget.lifecycle.visibleIncomingFadeDuration - 1) < 0.0001)

        initialEngine.reduceScenePresentation(.targetReady(initial.identity), at: 2)
        let settledInitialTarget = try #require(initialEngine.presentationTarget(for: initial.identity))
        #expect(abs(settledInitialTarget.lifecycle.visibleIncomingFadeDuration) < 0.0001)

        let initialZoomOut = SceneAnimationProfile(lifecycle: settledInitialTarget.lifecycle).singlePhotoTransform(
            direction: .zoomOut,
            activeTime: settledInitialTarget.lifecycle.longestVisibleMotionDuration,
            isMotionEnabled: true
        )
        #expect(abs(initialZoomOut.scale - 1) < 0.0001)

        var manualEngine = PlaybackSessionEngine()
        manualEngine.reset(
            with: [makeAsset(id: "paused-manual-initial"), makeAsset(id: "paused-manual-next")], reason: .sourceChanged)
        manualEngine.reduceScenePresentation(.suspend(.userPaused), at: 0)
        let transition = manualEngine.requestNext(candidate: makeAsset(id: "paused-manual-next"), source: .manualNext)
        let manualResult = manualEngine.beginScenePresentation(
            for: transition,
            configuredInterval: 5,
            requestSource: .manualNext,
            isAutomaticStableDeadline: false,
            at: 1
        )
        let manual = try #require(manualResult)
        let pendingManualTarget = try #require(manualEngine.presentationTarget(for: manual.identity))
        #expect(abs(pendingManualTarget.lifecycle.visibleIncomingFadeDuration - 0.3) < 0.0001)

        manualEngine.reduceScenePresentation(.resume(.userPaused), at: 1.1)
        manualEngine.reduceScenePresentation(.targetReady(manual.identity), at: 1.2)
        let resumedManualTarget = try #require(manualEngine.presentationTarget(for: manual.identity))
        #expect(abs(resumedManualTarget.lifecycle.visibleIncomingFadeDuration - 0.3) < 0.0001)

        let manualZoomIn = SceneAnimationProfile(lifecycle: resumedManualTarget.lifecycle).singlePhotoTransform(
            direction: .zoomIn,
            activeTime: resumedManualTarget.lifecycle.longestVisibleMotionDuration,
            isMotionEnabled: true
        )
        #expect(abs(manualZoomIn.scale - 1.10) < 0.0001)
    }

    @Test
    func `resuming a paused manual incoming counts only the remaining fade window`() throws {
        var engine = PlaybackSessionEngine()
        engine.reset(
            with: [makeAsset(id: "remaining-fade-initial"), makeAsset(id: "remaining-fade-next")],
            reason: .sourceChanged
        )
        let initialResult = engine.startScenePresentation(configuredInterval: 5, at: 0)
        let initial = try #require(initialResult)
        engine.reduceScenePresentation(.targetReady(initial.identity), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 2)

        let transition = engine.requestNext(candidate: makeAsset(id: "remaining-fade-next"), source: .manualNext)
        let manualResult = engine.beginScenePresentation(
            for: transition,
            configuredInterval: 5,
            requestSource: .manualNext,
            isAutomaticStableDeadline: false,
            at: 3
        )
        let manual = try #require(manualResult)
        engine.reduceScenePresentation(.targetReady(manual.identity), at: 3)

        let beforeResume = try #require(
            engine.sceneRenderSnapshot(at: 3.1).layers.first { $0.identity == manual.identity }
        )
        #expect(abs(beforeResume.opacity - (1 / 3)) < 0.0001)

        engine.reduceScenePresentation(.resume(.userPaused), at: 3.1)
        let resumedTarget = try #require(engine.presentationTarget(for: manual.identity))
        #expect(abs(resumedTarget.lifecycle.visibleIncomingFadeDuration - 0.2) < 0.0001)

        let afterResume = try #require(
            engine.sceneRenderSnapshot(at: 3.2).layers.first { $0.identity == manual.identity }
        )
        #expect(abs(afterResume.opacity - (2 / 3)) < 0.0001)

        let profile = SceneAnimationProfile(lifecycle: resumedTarget.lifecycle)
        let zoomOut = profile.singlePhotoTransform(
            direction: .zoomOut,
            activeTime: resumedTarget.lifecycle.longestVisibleMotionDuration,
            isMotionEnabled: true
        )
        let zoomIn = profile.singlePhotoTransform(
            direction: .zoomIn,
            activeTime: resumedTarget.lifecycle.longestVisibleMotionDuration,
            isMotionEnabled: true
        )
        #expect(abs(zoomOut.scale - 1) < 0.0001)
        #expect(abs(zoomIn.scale - 1.10) < 0.0001)
    }

    @Test
    func `a scene rebuilt outside the window also enters the same unified product snapshot`() throws {
        var engine = PlaybackSessionEngine(retainedRenderSceneLimit: 3)
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        for index in 1...5 {
            let transition = engine.requestNext(candidate: makeAsset(id: "asset-\(index)"))
            let didCommit = engine.commit(transition)
            #expect(didCommit)
        }
        #expect(engine.scenes.compactMap(\.primaryAssetId) == ["asset-3", "asset-4", "asset-5"])
        let initialResult = engine.startScenePresentation(configuredInterval: 5, at: 0)
        let initial = try #require(initialResult)
        engine.reduceScenePresentation(.targetReady(initial.identity), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        let fromSceneId = initial.identity.sceneID
        let rebuiltScene = makeSmartFillScene(
            id: "ledger-rebuilt-scene",
            assets: [
                makeAsset(id: "asset-1"),
                makeAsset(id: "asset-2")
            ]
        )

        let transition = engine.requestTransition(to: rebuiltScene, source: .manualPrevious)
        let startedResult = engine.beginScenePresentation(
            for: transition,
            configuredInterval: 5,
            requestSource: .manualPrevious,
            isAutomaticStableDeadline: false,
            at: 2
        )
        let started = try #require(startedResult)
        let snapshot = engine.sceneRenderSnapshot(at: 2)

        #expect(engine.currentScene?.photoSlots.map(\.asset.id) == ["asset-1", "asset-2"])
        #expect(snapshot.phase == .grace)
        #expect(snapshot.layers.map(\.role) == [.stable, .incoming])
        #expect(snapshot.layers.map(\.identity.sceneID) == [fromSceneId, started.identity.sceneID])
        #expect(engine.scene(for: started.identity)?.photoSlots.map(\.asset.id) == ["asset-1", "asset-2"])
    }

    @Test
    func `an autoplay commit enters the fixed grace period from the stable deadline`() throws {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let initialResult = engine.startScenePresentation(configuredInterval: 5, at: 0)
        let initial = try #require(initialResult)
        engine.reduceScenePresentation(.targetReady(initial.identity), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)

        let transition = engine.requestNext(candidate: makeAsset(id: "asset-1"), source: .autoplay)
        let startedResult = engine.beginScenePresentation(
            for: transition,
            configuredInterval: 5,
            requestSource: .automatic,
            isAutomaticStableDeadline: true,
            at: 6
        )
        let started = try #require(startedResult)
        let snapshot = engine.sceneRenderSnapshot(at: 6)

        #expect(transition.transaction.source == .autoplay)
        #expect(engine.currentScene?.id == transition.scene.id)
        #expect(snapshot.phase == .grace)
        #expect(snapshot.layers.map(\.role) == [.stable, .incoming])
        #expect(snapshot.layers.map(\.identity) == [initial.identity, started.identity])
        #expect(snapshot.isPendingTargetReady == false)
    }

    @Test
    func `cancelling a manual pending target preserves and restarts the interrupted automatic grace scene mapping`() {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        guard let initial = engine.startScenePresentation(configuredInterval: 5, at: 0) else {
            Issue.record("initial scene presentation must start")
            return
        }
        engine.reduceScenePresentation(.targetReady(initial.identity), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)

        let automaticTransition = engine.requestNext(
            candidate: makeAsset(id: "asset-1"),
            source: .autoplay
        )
        guard
            let automatic = engine.beginScenePresentation(
                for: automaticTransition,
                configuredInterval: 5,
                requestSource: .automatic,
                isAutomaticStableDeadline: true,
                at: 6
            )
        else {
            Issue.record("automatic grace presentation must start")
            return
        }
        let manualTransition = engine.requestNext(
            candidate: makeAsset(id: "asset-2"),
            source: .manualNext
        )
        guard
            engine.beginScenePresentation(
                for: manualTransition,
                configuredInterval: 5,
                requestSource: .manualNext,
                isAutomaticStableDeadline: false,
                at: 6.1
            ) != nil
        else {
            Issue.record("manual pending presentation must start")
            return
        }

        let effects = engine.cancelUnseenManualPendingScenePresentation(at: 6.2)
        let didRestartPlan = effects.contains { effect in
            guard case let .plan(request) = effect else { return false }
            return request.identity == automatic.identity && request.source == .automatic
        }
        let didRestartDownload = effects.contains { effect in
            guard case let .download(request) = effect else { return false }
            return request.identity == automatic.identity && request.source == .automatic
        }

        #expect(engine.scene(for: automatic.identity)?.id == automaticTransition.scene.id)
        #expect(engine.transition(for: automatic.identity)?.transaction.id == automaticTransition.transaction.id)
        #expect(didRestartPlan)
        #expect(didRestartDownload)
    }

    @Test
    func `the restored automatic grace target writes back the current playback index once it becomes visible`() {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        guard let initial = engine.startScenePresentation(configuredInterval: 5, at: 0) else {
            Issue.record("initial scene presentation must start")
            return
        }
        engine.reduceScenePresentation(.targetReady(initial.identity), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)

        let automaticTransition = engine.requestNext(
            candidate: makeAsset(id: "asset-1"),
            source: .autoplay
        )
        guard
            let automatic = engine.beginScenePresentation(
                for: automaticTransition,
                configuredInterval: 5,
                requestSource: .automatic,
                isAutomaticStableDeadline: true,
                at: 6
            )
        else {
            Issue.record("automatic grace presentation must start")
            return
        }
        let manualTransition = engine.requestNext(
            candidate: makeAsset(id: "asset-2"),
            source: .manualNext
        )
        guard
            engine.beginScenePresentation(
                for: manualTransition,
                configuredInterval: 5,
                requestSource: .manualNext,
                isAutomaticStableDeadline: false,
                at: 6.1
            ) != nil
        else {
            Issue.record("manual pending presentation must start")
            return
        }

        _ = engine.cancelUnseenManualPendingScenePresentation(at: 6.2)
        #expect(engine.currentIndex == 0)
        #expect(engine.currentScene?.id == initial.identity.sceneID)
        engine.reduceScenePresentation(.targetReady(automatic.identity), at: 6.3)
        engine.reduceScenePresentation(.graceExpired, at: 7.3)
        engine.reduceScenePresentation(.transitionCompleted, at: 7.4)
        engine.reduceScenePresentation(.incomingBecameVisible(automatic.identity), at: 7.5)

        #expect(engine.currentIndex == automaticTransition.targetIndex)
        #expect(engine.currentScene?.id == automaticTransition.scene.id)
    }

    @Test
    func `a failed or skipped unseen candidate does not enter the retained history`() {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)

        _ = engine.requestNext(candidate: makeAsset(id: "failed-candidate"))

        #expect(engine.scenes.compactMap(\.primaryAssetId) == ["asset-0"])
        #expect(engine.currentScene?.primaryAssetId == "asset-0")
    }

    @Test
    func `manual next immediately publishes the scene identity and atomically records every slot asset`() throws {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let currentSceneId = try #require(engine.currentScene?.id)
        let smartFillScene = makeSmartFillScene(
            id: "prototype-smartfill",
            assets: [
                makeAsset(id: "asset-1"),
                makeAsset(id: "asset-2")
            ]
        )

        let transition = engine.requestNext(scene: smartFillScene, source: .manualNext)

        #expect(engine.currentScene?.id == currentSceneId)
        #expect(transition.transaction.source == .manualNext)
        #expect(transition.transaction.preparedHit == false)
        #expect(transition.transaction.publishedAssetIds == ["asset-1", "asset-2"])
        #expect(transition.transaction.consumedAssetIds == ["asset-1", "asset-2"])
        #expect(transition.transaction.advancesForwardCursor)
        #expect(engine.publishedSceneRecords.map(\.transactionId) == [transition.transaction.id])
        #expect(engine.publishedSceneRecords.last?.sceneId == transition.scene.id)
        #expect(engine.publishedSceneRecords.last?.preparedHit == false)
        #expect(engine.publishedSceneRecords.last?.assetIds == ["asset-1", "asset-2"])
        #expect(engine.displayedSceneRecords.isEmpty)

        let didCommit = engine.commit(transition)

        #expect(didCommit)
        // The atomic publish is still a hidden phase; only the first visible tick of the full scene-root writes the
        // displayed ledger.
        #expect(engine.displayedSceneRecords.isEmpty)
        #expect(engine.currentScene?.photoSlots.map(\.asset.id) == ["asset-1", "asset-2"])
    }

    @Test
    func `a loading only scene enters the history ledger immediately on publish without waiting for a display commit`()
    {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let smartFillScene = makeSmartFillScene(
            id: "prototype-loading-only-smartfill",
            assets: [
                makeAsset(id: "asset-1"),
                makeAsset(id: "asset-2"),
                makeAsset(id: "asset-3")
            ],
            sceneType: .triple
        )

        let transition = engine.requestNext(scene: smartFillScene, source: .manualNext)

        #expect(engine.publishedSceneRecords.map(\.transactionId) == [transition.transaction.id])
        #expect(engine.publishedSceneRecords.last?.assetIds == ["asset-1", "asset-2", "asset-3"])
        #expect(engine.publishedSceneRecords.last?.sceneId == transition.scene.id)
        #expect(engine.displayedSceneRecords.isEmpty)
        #expect(engine.scenes.compactMap(\.primaryAssetId) == ["asset-0"])
    }

    @Test
    func `manual previous publishes a history scene without advancing the forward cursor`() throws {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let firstNext = engine.requestNext(candidate: makeAsset(id: "asset-1"))
        let didCommitFirstNext = engine.commit(firstNext)
        #expect(didCommitFirstNext)
        let secondNext = engine.requestNext(candidate: makeAsset(id: "asset-2"))
        let didCommitSecondNext = engine.commit(secondNext)
        #expect(didCommitSecondNext)

        let requestedPrevious = engine.requestPrevious()
        let previous = try #require(requestedPrevious)

        #expect(previous.transaction.source == .manualPrevious)
        #expect(previous.transaction.publishedAssetIds == ["asset-1"])
        #expect(previous.transaction.consumedAssetIds.isEmpty)
        #expect(previous.transaction.advancesForwardCursor == false)
        #expect(engine.publishedSceneRecords.last?.transactionId == previous.transaction.id)

        let didCommitPrevious = engine.commit(previous)
        #expect(didCommitPrevious)
        #expect(engine.currentScene?.primaryAssetId == "asset-1")
        #expect(engine.displayedSceneRecords.isEmpty)
    }

    @Test
    func `autoplay next publishes its transaction without carrying a commit side readiness policy`() {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)

        let transition = engine.requestNext(candidate: makeAsset(id: "asset-1"), source: .autoplay)

        #expect(transition.transaction.source == .autoplay)
        #expect(transition.transaction.publishedAssetIds == ["asset-1"])
        #expect(transition.transaction.consumedAssetIds == ["asset-1"])
        #expect(transition.transaction.advancesForwardCursor)
        #expect(engine.publishedSceneRecords.last?.transactionId == transition.transaction.id)
    }

    @Test
    func `a stale transaction cannot write to the displayed ledger or pollute the current scene`() {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let currentSceneId = engine.currentScene?.id
        let staleTransition = engine.requestNext(candidate: makeAsset(id: "asset-1"), source: .manualNext)

        engine.invalidate(reason: .serverChanged)
        let didCommitStale = engine.commit(staleTransition)

        #expect(didCommitStale == false)
        #expect(engine.currentScene?.id == currentSceneId)
        #expect(engine.publishedSceneRecords.map(\.transactionId) == [staleTransition.transaction.id])
        #expect(engine.displayedSceneRecords.isEmpty)
    }
}
