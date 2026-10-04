import Foundation
import Testing
@testable import immichSlides

extension PlaybackSessionEngineTests {
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
}
