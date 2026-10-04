//
//  PlaybackSessionEngineTests.swift
//  immichSlidesTests
//

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct PlaybackSessionEngineTests {

    @Test
    func `the shared scene reducer directly drives the single product snapshot`() {
        var engine = PlaybackSessionEngine()
        let target = PlaybackSessionEngine.ScenePresentationTarget(
            identity: .init(generation: UUID(), sceneID: "product-scene", assetID: "product-asset"),
            configuredInterval: 5
        )

        engine.reduceScenePresentation(.start(target: target, readiness: .ready), at: 0)
        let snapshot = engine.sceneRenderSnapshot(at: 0)

        #expect(snapshot.phase == .incomingFromLoading)
        #expect(snapshot.layers.map(\.identity) == [target.identity])
        #expect(snapshot.layers.map(\.role) == [.incoming])
        #expect(engine.currentScene == nil)
    }

    @Test
    func `the same asset can repeat but each committed display gets a distinct sceneId`() {
        var engine = PlaybackSessionEngine()
        let asset = makeAsset(id: "asset-a")

        engine.reset(with: [asset], reason: .sourceChanged)
        let firstSceneId = engine.currentScene?.id

        let transition = engine.requestNext(candidate: asset)
        let committed = engine.commit(transition)

        #expect(committed)
        #expect(engine.currentScene?.primaryAssetId == "asset-a")
        #expect(engine.currentScene?.id != firstSceneId)
    }

    @Test
    func `previous uses the retained immutable history and does not wrap past the oldest boundary`() {
        var engine = PlaybackSessionEngine(retainedRenderSceneLimit: 20)
        let first = makeAsset(id: "asset-0")
        engine.reset(with: [first], reason: .sourceChanged)

        for index in 1...3 {
            let transition = engine.requestNext(candidate: makeAsset(id: "asset-\(index)"))
            let didCommit = engine.commit(transition)
            #expect(didCommit)
        }

        #expect(engine.currentScene?.primaryAssetId == "asset-3")
        let previousToSecond = engine.requestPrevious()
        #expect(previousToSecond != nil)
        let didCommitPreviousToSecond = engine.commit(previousToSecond)
        #expect(didCommitPreviousToSecond)
        #expect(engine.currentScene?.primaryAssetId == "asset-2")
        let previousToFirst = engine.requestPrevious()
        #expect(previousToFirst != nil)
        let didCommitPreviousToFirst = engine.commit(previousToFirst)
        #expect(didCommitPreviousToFirst)
        #expect(engine.currentScene?.primaryAssetId == "asset-1")
        let previousToOldest = engine.requestPrevious()
        #expect(previousToOldest != nil)
        let didCommitPreviousToOldest = engine.commit(previousToOldest)
        #expect(didCommitPreviousToOldest)
        #expect(engine.currentScene?.primaryAssetId == "asset-0")

        let boundarySceneId = engine.currentScene?.id
        let boundaryNavID = engine.navigationToken
        let boundaryTransition = engine.requestPrevious()

        #expect(boundaryTransition == nil)
        #expect(engine.pendingTransition == nil)
        #expect(engine.navigationToken == boundaryNavID)
        #expect(engine.currentScene?.id == boundarySceneId)
    }

    @Test
    func `next from the middle of history uses a frozen future and a tail request commits only after validation`() {
        var engine = PlaybackSessionEngine(retainedRenderSceneLimit: 20)
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let firstTransition = engine.requestNext(candidate: makeAsset(id: "asset-1"))
        let didCommitFirst = engine.commit(firstTransition)
        #expect(didCommitFirst)
        let secondTransition = engine.requestNext(candidate: makeAsset(id: "asset-2"))
        let didCommitSecond = engine.commit(secondTransition)
        #expect(didCommitSecond)
        let previousTransition = engine.requestPrevious()
        #expect(previousTransition != nil)
        let didCommitPrevious = engine.commit(previousTransition)
        #expect(didCommitPrevious)

        let middleSceneId = engine.currentScene?.id
        let frozenFuture = engine.requestNext(candidate: makeAsset(id: "ignored-new"))

        #expect(engine.currentScene?.id == middleSceneId)
        #expect(frozenFuture.scene.primaryAssetId == "asset-2")
        let didCommitFrozenFuture = engine.commit(frozenFuture)
        #expect(didCommitFrozenFuture)
        #expect(engine.currentScene?.primaryAssetId == "asset-2")

        let tailTransition = engine.requestNext(candidate: makeAsset(id: "asset-3"))
        #expect(engine.currentScene?.primaryAssetId == "asset-2")
        let didCommitTail = engine.commit(tailTransition)
        #expect(didCommitTail)
        #expect(engine.currentScene?.primaryAssetId == "asset-3")
    }

    @Test
    func `previous and next history preserve the same scene's planning snapshot`() throws {
        var engine = PlaybackSessionEngine(retainedRenderSceneLimit: 20)
        engine.reset(with: [makeAsset(id: "asset-0", width: 100, height: 200)], reason: .sourceChanged)
        let firstPlanning = try #require(engine.currentScene?.photoSlots.first?.planning)

        let nextTransition = engine.requestNext(candidate: makeAsset(id: "asset-1", width: 300, height: 400))
        let planningWhilePending = try #require(engine.currentScene?.photoSlots.first?.planning)
        #expect(planningWhilePending == firstPlanning)
        let didCommitNext = engine.commit(nextTransition)
        #expect(didCommitNext)

        let requestedPreviousTransition = engine.requestPrevious()
        let previousTransition = try #require(requestedPreviousTransition)
        #expect(previousTransition.scene.photoSlots.first?.planning == firstPlanning)
        let didCommitPrevious = engine.commit(previousTransition)
        #expect(didCommitPrevious)
        #expect(engine.currentScene?.photoSlots.first?.planning == firstPlanning)
    }

    @Test
    func `updating the future protection snapshot leaves the current and history scenes unchanged`() throws {
        var engine = PlaybackSessionEngine(retainedRenderSceneLimit: 20)
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let firstScene = try #require(engine.currentScene)

        let secondTransition = engine.requestNext(candidate: makeAsset(id: "asset-1"))
        let didCommitSecond = engine.commit(secondTransition)
        #expect(didCommitSecond)
        let secondSceneBeforeProtection = try #require(engine.currentScene)

        let protection = makeControlBarProtection()
        engine.updateFutureProtectionSnapshot(protection)

        #expect(engine.currentScene?.id == secondSceneBeforeProtection.id)
        #expect(engine.currentScene?.protectionSnapshot == secondSceneBeforeProtection.protectionSnapshot)

        let requestedPreviousTransition = engine.requestPrevious()
        let previousTransition = try #require(requestedPreviousTransition)
        #expect(previousTransition.scene.id == firstScene.id)
        #expect(previousTransition.scene.protectionSnapshot == firstScene.protectionSnapshot)
    }

    @Test
    func `protection snapshots in previous and next history do not drift with the future snapshot`() throws {
        var engine = PlaybackSessionEngine(retainedRenderSceneLimit: 20)
        let initialProtection = makeFutureOverlayProtection()
        engine.updateFutureProtectionSnapshot(initialProtection)
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let firstProtection = try #require(engine.currentScene?.protectionSnapshot)

        let secondTransition = engine.requestNext(candidate: makeAsset(id: "asset-1"))
        let didCommitSecond = engine.commit(secondTransition)
        #expect(didCommitSecond)

        engine.updateFutureProtectionSnapshot(makeControlBarProtection())
        let requestedPreviousTransition = engine.requestPrevious()
        let previousTransition = try #require(requestedPreviousTransition)
        #expect(previousTransition.scene.protectionSnapshot == firstProtection)
        let didCommitPrevious = engine.commit(previousTransition)
        #expect(didCommitPrevious)
        #expect(engine.currentScene?.protectionSnapshot == firstProtection)
    }

    @Test
    func `updating with the same protection snapshot keeps a pending future transition`() throws {
        var engine = PlaybackSessionEngine(retainedRenderSceneLimit: 20)
        let protection = makeControlBarProtection()
        engine.updateFutureProtectionSnapshot(protection)
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)

        let transition = engine.requestNext(candidate: makeAsset(id: "asset-1"))
        let navigationToken = engine.navigationToken

        engine.updateFutureProtectionSnapshot(protection)

        #expect(engine.navigationToken == navigationToken)
        #expect(engine.pendingTransition?.scene.id == transition.scene.id)
        let didCommit = engine.commit(transition)
        #expect(didCommit)
        #expect(engine.currentScene?.protectionSnapshot == protection)
    }

    @Test
    func
        `a protection snapshot change discards an unseen pending future transition and rebuilds it with the new snapshot`()
        throws
    {
        var engine = PlaybackSessionEngine(retainedRenderSceneLimit: 20)
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let oldTransition = engine.requestNext(candidate: makeAsset(id: "asset-1"))
        let oldNavigationToken = engine.navigationToken
        let oldSessionId = engine.playbackSessionId

        let protection = makeControlBarProtection()
        engine.updateFutureProtectionSnapshot(protection)

        #expect(engine.playbackSessionId == oldSessionId)
        #expect(engine.navigationToken != oldNavigationToken)
        #expect(engine.pendingTransition == nil)
        #expect(engine.invalidationReason == .sourceChanged)
        let didCommitOld = engine.commit(oldTransition)
        #expect(didCommitOld == false)

        let newTransition = engine.requestNext(candidate: makeAsset(id: "asset-1"))
        #expect(newTransition.scene.protectionSnapshot == protection)
        let didCommitNew = engine.commit(newTransition)
        #expect(didCommitNew)
        #expect(engine.currentScene?.protectionSnapshot == protection)
    }

    @Test
    func `a protection snapshot change adds no invalidation reason and does not reset the playback session`() {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .filterChanged)
        let sessionId = engine.playbackSessionId
        let invalidationReason = engine.invalidationReason

        engine.updateFutureProtectionSnapshot(makeControlBarProtection())

        #expect(engine.playbackSessionId == sessionId)
        #expect(engine.invalidationReason == invalidationReason)
        engine.invalidate(reason: .serverChanged)
        #expect(engine.invalidationReason == .serverChanged)
        engine.reset(with: [makeAsset(id: "asset-1")], reason: .poolReloaded)
        #expect(engine.playbackSessionId != sessionId)
        #expect(engine.invalidationReason == .poolReloaded)
    }

    @Test
    func `after generating more than 25 scenes the most recent 20 retained scenes stay stable`() {
        var engine = PlaybackSessionEngine(retainedRenderSceneLimit: 20)
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)

        for index in 1...25 {
            let transition = engine.requestNext(candidate: makeAsset(id: "asset-\(index)"))
            let didCommit = engine.commit(transition)
            #expect(didCommit)
        }

        #expect(engine.scenes.count == 20)
        #expect(engine.scenes.compactMap(\.primaryAssetId) == (6...25).map { "asset-\($0)" })
        let retainedSequences = engine.scenes.map(\.sequence)
        #expect(retainedSequences == retainedSequences.sorted())
        #expect(Set(retainedSequences).count == retainedSequences.count)

        let retainedSceneIds = engine.scenes.map(\.id)
        let previousTransition = engine.requestPrevious()
        #expect(previousTransition != nil)
        let didCommitPrevious = engine.commit(previousTransition)
        #expect(didCommitPrevious)
        let nextTransition = engine.requestNext(candidate: makeAsset(id: "ignored"))
        let didCommitNext = engine.commit(nextTransition)
        #expect(didCommitNext)
        #expect(engine.scenes.map(\.id) == retainedSceneIds)
        #expect(engine.scenes.map(\.sequence) == retainedSequences)
    }

    @Test
    func `trimming history keeps the remaining scenes' planning summaries stable`() throws {
        var engine = PlaybackSessionEngine(retainedRenderSceneLimit: 3)
        engine.reset(with: [makeAsset(id: "asset-0", width: 100, height: 200)], reason: .sourceChanged)

        for index in 1...5 {
            let transition = engine.requestNext(
                candidate: makeAsset(
                    id: "asset-\(index)",
                    width: 100 + index,
                    height: 200 + index
                ))
            let didCommit = engine.commit(transition)
            #expect(didCommit)
        }

        let summaries = engine.scenes.map { scene in
            scene.photoSlots.first?.planning.qaDebugSummary
        }

        #expect(engine.scenes.compactMap(\.primaryAssetId) == ["asset-3", "asset-4", "asset-5"])
        #expect(
            summaries == [
                "version=legacy-scaledToFit-v1;display=full;crop=full;quality=legacy-not-evaluated;face=not-applied;metadata=asset-dimensions;fallback=legacy-scaled-to-fit",
                "version=legacy-scaledToFit-v1;display=full;crop=full;quality=legacy-not-evaluated;face=not-applied;metadata=asset-dimensions;fallback=legacy-scaled-to-fit",
                "version=legacy-scaledToFit-v1;display=full;crop=full;quality=legacy-not-evaluated;face=not-applied;metadata=asset-dimensions;fallback=legacy-scaled-to-fit"
            ])
    }

    @Test
    func `a request does not mutate the current display and a stale or cancelled commit is a no-op`() {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)

        let currentSceneId = engine.currentScene?.id
        let staleTransition = engine.requestNext(candidate: makeAsset(id: "asset-1"))

        #expect(engine.currentScene?.id == currentSceneId)
        engine.invalidate(reason: .serverChanged)

        let didCommitStale = engine.commit(staleTransition)
        #expect(didCommitStale == false)
        #expect(engine.currentScene?.id == currentSceneId)
    }

    @Test
    func `reset creates a new session and an old load result cannot pollute it`() {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "old-0")], reason: .sourceChanged)
        let oldSessionId = engine.playbackSessionId
        let oldTransition = engine.requestNext(candidate: makeAsset(id: "old-1"))

        engine.reset(with: [makeAsset(id: "new-0")], reason: .filterChanged)

        #expect(engine.playbackSessionId != oldSessionId)
        #expect(engine.currentScene?.primaryAssetId == "new-0")
        let didCommitOld = engine.commit(oldTransition)
        #expect(didCommitOld == false)
        #expect(engine.scenes.compactMap(\.primaryAssetId) == ["new-0"])
    }

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
        #expect(snapshot.pendingTargetIsReady == false)
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

        #expect(engine.scenePublicationRecords.map(\.transactionId) == [transition.transaction.id])
        #expect(engine.scenePublicationRecords.last?.assetIds == ["asset-1", "asset-2", "asset-3"])
        #expect(engine.scenePublicationRecords.last?.sceneId == transition.scene.id)
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

    @Test
    func
        `a prebuilt SmartFill scene keeps its slots and is stamped with the current session identity as a pending transition`()
        throws
    {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let sessionId = engine.playbackSessionId

        let smartFillScene = makeSmartFillScene(
            id: "prototype-smartfill",
            assets: [
                makeAsset(id: "asset-1"),
                makeAsset(id: "asset-2")
            ]
        )

        let transition = engine.requestNext(scene: smartFillScene)

        #expect(engine.currentScene?.primaryAssetId == "asset-0")
        #expect(transition.scene.playbackSessionId == sessionId)
        #expect(transition.scene.sequence == 2)
        #expect(transition.scene.photoSlots.map(\.asset.id) == ["asset-1", "asset-2"])
        #expect(
            transition.scene.photoSlots.map { $0.planning.qualityDecision } == [.smartFillAccepted, .smartFillAccepted])
        #expect(transition.scene.smartFillReadback?.sceneType == .double)
        #expect(transition.scene.protectionSnapshot == PlaybackProtectionSnapshot.empty)

        let didCommit = engine.commit(transition)

        #expect(didCommit)
        #expect(engine.currentScene?.photoSlots.map(\.asset.id) == ["asset-1", "asset-2"])
    }

    @Test
    func `resetting with an initial SmartFill scene makes it the current display directly and keeps its readback`()
        throws
    {
        var engine = PlaybackSessionEngine()
        let initialScene = makeSmartFillScene(
            id: "initial-smartfill",
            assets: [
                makeAsset(id: "asset-0"),
                makeAsset(id: "asset-1"),
                makeAsset(id: "asset-2")
            ],
            sceneType: .triple
        )

        engine.reset(with: [makeAsset(id: "legacy-ignored")], initialScene: initialScene, reason: .poolReloaded)

        let currentScene = try #require(engine.currentScene)
        #expect(currentScene.playbackSessionId == engine.playbackSessionId)
        #expect(currentScene.sequence == 1)
        #expect(currentScene.photoSlots.map(\.asset.id) == ["asset-0", "asset-1", "asset-2"])
        #expect(currentScene.smartFillReadback?.sceneType == .triple)
        #expect(currentScene.smartFillReadback?.slotRoles == [.primary, .secondary, .tertiary])
    }

    @Test
    func `consuming the prepared next uses the prebuilt scene and refreshes the previous, current and next ring`()
        throws
    {
        var engine = PlaybackSessionEngine(retainedRenderSceneLimit: 20)
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let currentScene = try #require(engine.currentScene)
        let nextScene = makeSmartFillScene(
            id: "prepared-next",
            assets: [
                makeAsset(id: "asset-1"),
                makeAsset(id: "asset-2")
            ]
        )
        let fingerprint = makePreparedFingerprint()

        engine.prepareSceneRing(
            fingerprint: fingerprint,
            sourceCursor: 1,
            previous: nil,
            current: currentScene,
            next: nextScene
        )
        let requestedNext = engine.consumePreparedNext(source: .manualNext)
        let transition = try #require(requestedNext)

        #expect(transition.transaction.preparedHit)
        #expect(transition.scene.photoSlots.map(\.asset.id) == ["asset-1", "asset-2"])
        #expect(engine.preparedSceneRing?.fingerprint == fingerprint)
        #expect(engine.preparedSceneRing?.sourceCursor == 1)
        #expect(engine.preparedSceneRing?.previous?.scene.id == currentScene.id)
        #expect(engine.preparedSceneRing?.current?.scene.id == transition.scene.id)
        #expect(engine.preparedSceneRing?.next == nil)
        #expect(engine.publishedSceneRecords.last?.transactionId == transition.transaction.id)
        #expect(engine.publishedSceneRecords.last?.preparedHit == true)

        let didCommit = engine.commit(transition)

        #expect(didCommit)
        #expect(engine.currentScene?.photoSlots.map(\.asset.id) == ["asset-1", "asset-2"])
        #expect(engine.displayedSceneRecords.isEmpty)
    }

    @Test
    func `consuming the prepared previous uses retained history and shifts the old current into next`() throws {
        var engine = PlaybackSessionEngine(retainedRenderSceneLimit: 20)
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let firstNext = engine.requestNext(candidate: makeAsset(id: "asset-1"))
        let didCommitFirstNext = engine.commit(firstNext)
        #expect(didCommitFirstNext)
        let secondNext = engine.requestNext(candidate: makeAsset(id: "asset-2"))
        let didCommitSecondNext = engine.commit(secondNext)
        #expect(didCommitSecondNext)
        let previousScene = engine.scenes[1]
        let currentScene = try #require(engine.currentScene)
        let nextScene = makeSmartFillScene(
            id: "prepared-future",
            assets: [
                makeAsset(id: "asset-3"),
                makeAsset(id: "asset-4")
            ]
        )
        let fingerprint = makePreparedFingerprint()

        engine.prepareSceneRing(
            fingerprint: fingerprint,
            sourceCursor: 3,
            previous: previousScene,
            current: currentScene,
            next: nextScene
        )
        let requestedPrevious = engine.consumePreparedPrevious(source: .manualPrevious)
        let transition = try #require(requestedPrevious)

        #expect(transition.transaction.preparedHit)
        #expect(transition.scene.id == previousScene.id)
        #expect(engine.preparedSceneRing?.previous == nil)
        #expect(engine.preparedSceneRing?.current?.scene.id == previousScene.id)
        #expect(engine.preparedSceneRing?.next?.scene.id == currentScene.id)
        #expect(transition.transaction.consumedAssetIds.isEmpty)
        #expect(engine.publishedSceneRecords.last?.preparedHit == true)

        let didCommit = engine.commit(transition)

        #expect(didCommit)
        #expect(engine.currentScene?.primaryAssetId == "asset-1")
        #expect(engine.displayedSceneRecords.isEmpty)
    }

    @Test
    func `the prepared ring fingerprint ignores 1px jitter but detects meaningful size and overlay changes`() throws {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let currentScene = try #require(engine.currentScene)
        let baseFingerprint = makePreparedFingerprint(width: 1024, height: 768)
        let onePixelJitter = makePreparedFingerprint(width: 1025, height: 768)
        let meaningfulResize = makePreparedFingerprint(width: 1194, height: 768)
        let orientationChanged = makePreparedFingerprint(orientation: "portrait", width: 1024, height: 768)
        let safeAreaChanged = makePreparedFingerprint(width: 1024, height: 768, safeAreaClass: "compact")
        let controlBarChanged = makePreparedFingerprint(width: 1024, height: 768, controlBarClass: "visible")
        let exifChanged = makePreparedFingerprint(width: 1024, height: 768, exifOverlayClass: "hidden")
        let assetPoolChanged = makePreparedFingerprint(width: 1024, height: 768, assetPoolIdentity: "pool-b")
        let playbackSourceChanged = makePreparedFingerprint(width: 1024, height: 768, playbackSourceIdentity: "album-b")

        engine.prepareSceneRing(
            fingerprint: baseFingerprint,
            sourceCursor: 1,
            previous: nil,
            current: currentScene,
            next: makeSmartFillScene(id: "prepared-next", assets: [makeAsset(id: "asset-1"), makeAsset(id: "asset-2")])
        )

        #expect(engine.shouldInvalidatePreparedSceneRing(for: onePixelJitter) == false)
        #expect(engine.shouldInvalidatePreparedSceneRing(for: meaningfulResize))
        #expect(engine.shouldInvalidatePreparedSceneRing(for: orientationChanged))
        #expect(engine.shouldInvalidatePreparedSceneRing(for: safeAreaChanged))
        #expect(engine.shouldInvalidatePreparedSceneRing(for: controlBarChanged))
        #expect(engine.shouldInvalidatePreparedSceneRing(for: exifChanged))
        #expect(engine.shouldInvalidatePreparedSceneRing(for: assetPoolChanged))
        #expect(engine.shouldInvalidatePreparedSceneRing(for: playbackSourceChanged))
    }

    @Test
    func `a stale prepared scene cannot commit back to the current scene after ring invalidation`() throws {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let currentScene = try #require(engine.currentScene)
        let baseFingerprint = makePreparedFingerprint(width: 1024, height: 768)
        let changedFingerprint = makePreparedFingerprint(width: 1194, height: 768)

        engine.prepareSceneRing(
            fingerprint: baseFingerprint,
            sourceCursor: 1,
            previous: nil,
            current: currentScene,
            next: makeSmartFillScene(id: "prepared-next", assets: [makeAsset(id: "asset-1"), makeAsset(id: "asset-2")])
        )
        let requestedNext = engine.consumePreparedNext(source: .manualNext)
        let transition = try #require(requestedNext)

        let didInvalidate = engine.invalidatePreparedSceneRing(ifNeededFor: changedFingerprint)
        let didCommitStale = engine.commit(transition)

        #expect(didInvalidate)
        #expect(didCommitStale == false)
        #expect(engine.currentScene?.id == currentScene.id)
        #expect(engine.displayedSceneRecords.isEmpty)
    }

    @Test
    func `autoplay requesting next at the deadline changes the current identity to the next scene`() throws {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let initialIdentity = try settleInitialScenePresentation(&engine, at: 0)

        let transition = engine.requestNext(candidate: makeAsset(id: "asset-1"), source: .autoplay)
        let startedResult = engine.beginScenePresentation(
            for: transition,
            configuredInterval: 5,
            requestSource: .automatic,
            isAutomaticStableDeadline: true,
            at: 5
        )
        let started = try #require(startedResult)

        #expect(initialIdentity.assetID == "asset-0")
        #expect(started.identity.assetID == "asset-1")
        #expect(started.identity != initialIdentity)
        #expect(engine.currentScene?.id == started.identity.sceneID)
        #expect(engine.currentScene?.primaryAssetId == "asset-1")
    }

    @Test
    func `advancing the clock from 0 to 50 while paused does not change the identity`() throws {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let pausedIdentity = try settleInitialScenePresentation(&engine, at: 0)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 0)

        let wakeEffects = engine.reduceScenePresentation(
            .wakeUp(generation: pausedIdentity.generation, deadline: 5),
            at: 50
        )
        let snapshot = engine.sceneRenderSnapshot(at: 50)

        #expect(engine.scenePresentationState.currentTarget?.identity == pausedIdentity)
        #expect(engine.currentScene?.id == pausedIdentity.sceneID)
        #expect(engine.currentScene?.primaryAssetId == "asset-0")
        #expect(snapshot.currentTarget?.identity == pausedIdentity)
        #expect(snapshot.layers.map(\.identity) == [pausedIdentity])
        #expect(
            !wakeEffects.contains { effect in
                if case .plan = effect { return true }
                return false
            })
    }

    @Test
    func
        `resuming from pause does not jump straight to the next scene and the paused duration does not count toward the deadline`()
        throws
    {
        var engine = PlaybackSessionEngine()
        engine.reset(with: [makeAsset(id: "asset-0")], reason: .sourceChanged)
        let pausedIdentity = try settleInitialScenePresentation(&engine, at: 0)
        engine.reduceScenePresentation(.suspend(.userPaused), at: 0)

        let resumeEffects = engine.reduceScenePresentation(.resume(.userPaused), at: 50)
        let restoredDeadlines = resumeEffects.compactMap { effect -> TimeInterval? in
            guard case let .scheduleWakeUp(_, deadline) = effect else { return nil }
            return deadline
        }
        let immediateWakeEffects = engine.reduceScenePresentation(
            .wakeUp(generation: pausedIdentity.generation, deadline: 50),
            at: 50
        )

        #expect(engine.scenePresentationState.currentTarget?.identity == pausedIdentity)
        #expect(engine.currentScene?.primaryAssetId == "asset-0")
        #expect(restoredDeadlines == [55])
        #expect(
            !resumeEffects.contains { effect in
                if case .plan = effect { return true }
                return false
            })
        #expect(
            !immediateWakeEffects.contains { effect in
                if case .plan = effect { return true }
                return false
            })
    }

    /// Settles right after the first scene is Ready; later steps only assert the auto play identity.
    private func settleInitialScenePresentation(
        _ engine: inout PlaybackSessionEngine,
        configuredInterval: TimeInterval = 5,
        at time: TimeInterval = 0
    ) throws -> PlaybackSessionEngine.ScenePresentationIdentity {
        let startedResult = engine.startScenePresentation(configuredInterval: configuredInterval, at: time)
        let started = try #require(startedResult)
        engine.reduceScenePresentation(.targetReady(started.identity), at: time)
        engine.reduceScenePresentation(.transitionCompleted, at: time)
        return started.identity
    }

    private func makeAsset(
        id: String,
        width: Int? = nil,
        height: Int? = nil,
        exifInfo: ExifInfo? = nil
    ) -> Asset {
        Asset(
            id: id,
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: exifInfo,
            people: nil,
            tags: nil,
            livePhotoVideoID: nil,
            width: width,
            height: height
        )
    }

    private func makeSmartFillScene(
        id: String,
        assets: [Asset],
        sceneType: PlaybackSmartFillSceneType = .double
    ) -> PlaybackScene {
        let policyId = "unit-smartfill-policy"
        let roles: [PlaybackSmartFillSlotRole] = [.primary, .secondary, .tertiary]
        let slots = zip(assets.indices, assets).map { index, asset in
            PhotoSlot(
                id: "slot-\(roles[index].rawValue)-\(asset.id)",
                asset: asset,
                planning: PlaybackPlanningSnapshot.smartFill(
                    slot: PlaybackSmartFillSlot(
                        role: roles[index],
                        candidateReference: "candidate-\(index)",
                        frameInScene: PlaybackPlanningRect(
                            x: index == 0 ? 0 : 0.5,
                            y: index == 2 ? 0.5 : 0,
                            width: index == 0 ? 0.5 : 0.5,
                            height: assets.count == 3 && index > 0 ? 0.5 : 1
                        ),
                        cropRectInSource: .fullUnitRect,
                        sourceImageSummary: PlaybackPlanningSourceImageSummary(
                            assetPixelSize: PlaybackPlanningPixelSize(width: 2400, height: 1600),
                            exifPixelSize: nil,
                            orientation: "available"
                        ),
                        rejectRisks: []
                    ),
                    plannerResult: PlaybackSmartFillPlannerResult(
                        sceneType: sceneType,
                        layoutPolicyId: policyId,
                        surfaceKey: "unit-surface",
                        layoutVariant: sceneType == .triple ? .leftPrimaryRightStack : .horizontalEqual,
                        ratioPreset: "unit",
                        slots: [],
                        fallbackReason: nil,
                        rejectReasonsTried: [],
                        qualityDecision: .smartFillAccepted,
                        faceProtectionSummary: .notApplied,
                        protectionSummary: .accepted,
                        readabilitySummary: PlaybackSmartFillReadabilitySummary(
                            minimumSecondaryArea: 0.2,
                            smallestSecondaryArea: 0.25,
                            accepted: true
                        ),
                        candidateWindowUsed: 12,
                        evaluationCount: assets.count,
                        rotationStartLayoutVariant: sceneType == .triple ? .leftPrimaryRightStack : .horizontalEqual,
                        rotationStartRatioPreset: "unit",
                        acceptedLayoutVariant: sceneType == .triple ? .leftPrimaryRightStack : .horizontalEqual,
                        acceptedRatioPreset: "unit",
                        rotationKeyHashPrefix: "unit0000",
                        reasonCodes: ["scene:\(sceneType.rawValue)", "policy:\(policyId)"],
                        qaDebugSummary:
                            "version=smart-fill-planner-v2;sceneType=\(sceneType.rawValue);surfaceKey=unit-surface;policy=\(policyId);slotCount=\(assets.count);fallback=none;rejects=none",
                        currentAssetDisposition: .primarySlot,
                        currentAssetAbsentReason: .none,
                        currentAssetFaceProtectionPassed: true,
                        currentAssetSubjectProtectionPassed: true,
                        currentAssetVisibleQualityClass: .acceptable
                    )
                )
            )
        }

        return PlaybackScene(
            id: id,
            photoSlots: slots,
            smartFillReadback: PlaybackSmartFillSceneReadback(
                version: "smart-fill-scene-v2",
                sceneType: sceneType,
                layoutPolicyId: policyId,
                surfaceKey: "unit-surface",
                layoutVariant: sceneType == .triple ? .leftPrimaryRightStack : .horizontalEqual,
                ratioPreset: "unit",
                slotRoles: Array(roles.prefix(assets.count)),
                fallbackReason: nil,
                candidateWindowUsed: 12,
                evaluationCount: assets.count,
                rotationStartLayoutVariant: sceneType == .triple ? .leftPrimaryRightStack : .horizontalEqual,
                rotationStartRatioPreset: "unit",
                acceptedLayoutVariant: sceneType == .triple ? .leftPrimaryRightStack : .horizontalEqual,
                acceptedRatioPreset: "unit",
                rotationKeyHashPrefix: "unit0000",
                reasonCodes: ["scene:\(sceneType.rawValue)", "policy:\(policyId)"],
                qaDebugSummary:
                    "version=smart-fill-planner-v2;sceneType=\(sceneType.rawValue);surfaceKey=unit-surface;policy=\(policyId);slotCount=\(assets.count);fallback=none"
            )
        )
    }

    private func makePreparedFingerprint(
        deviceProfile: String = "iPad",
        orientation: String = "landscape",
        width: Double = 1024,
        height: Double = 768,
        safeAreaClass: String = "regular",
        controlBarClass: String = "hidden",
        exifOverlayClass: String = "visible",
        assetPoolIdentity: String = "pool-a",
        playbackSourceIdentity: String = "album-a"
    ) -> PlaybackPreparedSceneFingerprint {
        PlaybackPreparedSceneFingerprint(
            deviceProfile: deviceProfile,
            orientation: orientation,
            pointWidth: width,
            pointHeight: height,
            safeAreaClass: safeAreaClass,
            controlBarClass: controlBarClass,
            exifOverlayClass: exifOverlayClass,
            assetPoolIdentity: assetPoolIdentity,
            playbackSourceIdentity: playbackSourceIdentity
        )
    }

    private func makeControlBarProtection() -> PlaybackProtectionSnapshot {
        PlaybackProtectionSnapshot(regions: [
            PlaybackProtectionRegion.controlBar(
                rect: PlaybackProtectionRect(x: 0, y: 0.9, width: 1, height: 0.1),
                activeConditionSummary: "visible"
            )!
        ])
    }

    private func makeFutureOverlayProtection() -> PlaybackProtectionSnapshot {
        PlaybackProtectionSnapshot(regions: [
            PlaybackProtectionRegion.futureOverlay(
                rect: PlaybackProtectionRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                activeConditionSummary: "preview"
            )!
        ])
    }
}
