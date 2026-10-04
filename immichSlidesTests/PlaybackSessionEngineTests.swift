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
}
