import Foundation
import Testing
@testable import immichSlides

extension SlideShowViewModelNavigationSemanticsTests {
    @Test
    func `SmartFill manual next consumes the prepared next scene and refreshes the ring before subsequent nexts`()
        async throws
    {
        let vm = makeSmartFillViewModel()

        for expectedAssetId in ["asset-1", "asset-2"] {
            let didPrepareNext = await waitUntilForTesting {
                vm.preparedSmartFillNextAssetIdsForTesting != nil
            }
            #expect(didPrepareNext)

            vm.requestNextScene()
            let token = vm.targetTransitionToken
            let targetIndex = vm.targetIndex

            await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
            completeCurrentScenePresentation(vm)

            #expect(vm.safeCurrentScene?.primaryAssetId == expectedAssetId)
            let summary = try #require(
                vm.currentSmartFillRuntimeQADebugSummary(
                    controlBarVisible: true,
                    exifOverlayVisible: false
                ))
            #expect(summary.contains("preparedHit=true"))
            await Task.yield()
        }
    }

    @Test(arguments: [PlaybackDisplayMode.singlePhoto, .smartFill])
    func `the playback history ledger lets previous cross the engine's retained scene window`(
        displayMode: PlaybackDisplayMode
    ) async throws {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        var settings = PlaybackSettings()
        settings.displayMode = displayMode
        settings.autoPlayEnabled = false
        vm.applyPlaybackSettings(settings)
        if displayMode == .smartFill {
            vm.updateSmartFillSurfaceForTesting(
                PlaybackSmartFillSurface(
                    pixelSize: PlaybackPlanningPixelSize(width: 1179, height: 2556),
                    profile: .iPhone, orientation: .portrait))
        }
        let assets = (0..<210).map { makeAsset(id: "asset-\($0)", width: 1800, height: 2000) }
        markReady(assets, in: vm.downloadManager)
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            markReady(assetId: assetId, size: size, in: vm.downloadManager)
        }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.loadMoreAssetsHookForTesting = { _ in [] }
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)
        var seenScenes = [try #require(vm.safeCurrentScene)]

        func expectRecipe(_ restored: PlaybackScene, matches original: PlaybackScene) {
            #expect(restored.assetIds == original.assetIds)
            #expect(restored.photoSlots.map(\.planning) == original.photoSlots.map(\.planning))
            // Navigation legitimately records new publication timing; the complete planning readback must persist.
            #expect(
                restored.smartFillReadback?.recordingPublishTiming(actionTimestamp: 0, scenePublishTimestamp: 0)
                    == original.smartFillReadback?.recordingPublishTiming(actionTimestamp: 0, scenePublishTimestamp: 0))
        }

        for expectedIndex in 1...60 {
            if displayMode == .smartFill {
                let didPrepare = await waitUntilForTesting { vm.preparedSmartFillNextAssetIdsForTesting != nil }
                try #require(didPrepare, "The real planner must supply the next multi-slot recipe")
            }
            vm.requestNextScene()
            let token = vm.targetTransitionToken
            let targetIndex = vm.targetIndex

            await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
            completeCurrentScenePresentation(vm)

            let scene = try #require(vm.safeCurrentScene)
            if displayMode == .smartFill {
                try #require(scene.photoSlots.count > 1, "SmartFill coverage must use multi-slot scenes")
            } else {
                #expect(scene.primaryAssetId == "asset-\(expectedIndex)")
            }
            seenScenes.append(scene)
        }

        #expect(vm.playbackScenes.count < seenScenes.count, "Previous must cross a trimmed engine window")

        var previousAssetIds: [String] = []
        for step in 1...55 {
            let beforeAssetId = try #require(vm.safeCurrentScene?.primaryAssetId)

            vm.requestPreviousScene()
            let token = vm.targetTransitionToken
            let targetIndex = vm.targetIndex
            await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
            completeCurrentScenePresentation(vm)

            let afterAssetId = try #require(vm.safeCurrentScene?.primaryAssetId)
            #expect(afterAssetId != beforeAssetId, "previous #\(step) should not stay on the same photo")
            expectRecipe(try #require(vm.safeCurrentScene), matches: seenScenes[60 - step])
            previousAssetIds.append(afterAssetId)
        }

        #expect(previousAssetIds.last == seenScenes[5].primaryAssetId)

        vm.requestNextScene()
        await vm.synchronizePlaybackReadbackForTesting(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)
        completeCurrentScenePresentation(vm)

        expectRecipe(try #require(vm.safeCurrentScene), matches: seenScenes[6])
    }

    @Test
    func `previous availability follows the ledger boundary`() async throws {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        let assets = (0..<4).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
        markReady(assets, in: vm.downloadManager)
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            markReady(assetId: assetId, size: size, in: vm.downloadManager)
        }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)

        #expect(vm.canRequestPreviousScene == false)

        vm.requestNextScene()
        await vm.synchronizePlaybackReadbackForTesting(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)
        completeCurrentScenePresentation(vm)

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")
        #expect(vm.canRequestPreviousScene)

        vm.requestPreviousScene()
        await vm.synchronizePlaybackReadbackForTesting(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)
        completeCurrentScenePresentation(vm)

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-0")
        #expect(vm.canRequestPreviousScene == false)
    }

    @Test
    func `two nexts then two previouses return to the first scene, and previous at the start does not change assets`()
        async throws
    {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        let assets = (0..<4).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
        markReady(assets, in: vm.downloadManager)
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            markReady(assetId: assetId, size: size, in: vm.downloadManager)
        }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.isAutoPlay = false
        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)

        func settleManualRequest() async {
            await vm.synchronizePlaybackReadbackForTesting(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)
            completeCurrentScenePresentation(vm)
        }

        let firstSceneId = try #require(vm.safeCurrentScene?.id)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-0")
        #expect(vm.canRequestPreviousScene == false)
        try expectHistory(vm, assetIds: ["asset-0"], cursor: 0)

        vm.requestPreviousScene()
        await settleManualRequest()
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-0")
        #expect(vm.safeCurrentScene?.id == firstSceneId)
        #expect(vm.canRequestPreviousScene == false)

        vm.qaPlaybackSequenceEvidenceEnabledForTesting = true
        var displayedSceneLines: [String] = []
        vm.qaPlaybackSequenceOSLogEmitterForTesting = { line in
            if line.hasPrefix("qa_playback_sequence ") {
                displayedSceneLines.append(line)
            }
        }
        vm.requestNextScene()
        #expect(vm.smartFillCandidateCursorIndexForTesting == 2)
        try expectHistory(vm, assetIds: ["asset-0"], cursor: 0)
        let hiddenLayer = try #require(vm.sceneRenderSnapshot.layers.last { $0.role == .incoming })
        #expect(hiddenLayer.opacity == 0)
        let hiddenScene = try #require(vm.scene(for: hiddenLayer))
        for slot in hiddenScene.photoSlots {
            vm.rendererDecoded(
                SceneRendererIdentity(
                    generation: hiddenLayer.identity.generation,
                    attemptID: vm.scenePresentationRendererAttemptID(for: hiddenLayer),
                    sceneID: hiddenLayer.identity.sceneID,
                    slotID: slot.id,
                    assetID: slot.asset.id
                )
            )
        }
        #expect(vm.isScenePresentationBarrierComplete(for: hiddenLayer))
        let decodedLayer = try #require(vm.sceneRenderSnapshot.layers.first { $0.identity == hiddenLayer.identity })
        #expect(decodedLayer.opacity == 0)
        try expectHistory(vm, assetIds: ["asset-0"], cursor: 0)
        await settleManualRequest()
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")
        try expectHistory(vm, assetIds: ["asset-0", "asset-1"], cursor: 1)
        #expect(displayedSceneLines.count == 1)
        vm.incomingBecameVisible(vm.scenePresentationLayerIdentity(for: hiddenLayer))
        #expect(displayedSceneLines.count == 1)
        try expectHistory(vm, assetIds: ["asset-0", "asset-1"], cursor: 1)

        vm.requestNextScene()
        await settleManualRequest()
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-2")
        try expectHistory(vm, assetIds: ["asset-0", "asset-1", "asset-2"], cursor: 2)

        vm.requestPreviousScene()
        await settleManualRequest()
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")
        try expectHistory(vm, assetIds: ["asset-0", "asset-1", "asset-2"], cursor: 1)
        #expect(vm.pendingPlaybackHistoryLedgerCommitCountForTesting == 0)

        vm.requestPreviousScene()
        await settleManualRequest()
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-0")
        #expect(vm.safeCurrentScene?.id == firstSceneId)
        #expect(vm.canRequestPreviousScene == false)

        vm.requestPreviousScene()
        await settleManualRequest()
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-0")
        #expect(vm.safeCurrentScene?.id == firstSceneId)
        #expect(vm.canRequestPreviousScene == false)
    }

    @Test
    func `a manual hold keeps the prerender barrier attempt it began for its target`() {
        let vm = makeSmartFillViewModel()
        let attemptsBefore = vm.scenePresentationBarrierAttemptCountForTesting

        vm.requestNextScene()

        #expect(vm.sceneRenderSnapshot.phase == .grace)
        #expect(vm.scenePresentationBarrierAttemptCountForTesting == attemptsBefore + 1)
    }

    @Test
    func `previous with an unseen manual pending target cancels it and restores the ledger's current scene`()
        async throws
    {
        let vm = makeSmartFillViewModel()

        vm.requestNextScene()
        await vm.synchronizePlaybackReadbackForTesting(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)
        completeCurrentScenePresentation(vm)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")

        vm.downloadManager.assetStates["asset-2"] = .notStarted
        vm.downloadManager.assetPreviewStates["asset-2"] = .notStarted
        vm.downloadManager.assetURLs["asset-2"] = nil
        vm.requestNextScene()
        await vm.synchronizePlaybackReadbackForTesting(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)
        #expect(vm.sceneRenderSnapshot.phase == .grace)
        #expect(vm.visibleOverlayScene?.primaryAssetId == "asset-1")
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-2")
        #expect(vm.smartFillCandidateCursorIndexForTesting == 3)
        try expectHistory(vm, assetIds: ["asset-0", "asset-1"], cursor: 1)

        vm.requestPreviousScene()
        await vm.synchronizePlaybackReadbackForTesting(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")
        #expect(vm.smartFillCandidateCursorIndexForTesting == 3)
        try expectHistory(vm, assetIds: ["asset-0", "asset-1"], cursor: 1)
        #expect(vm.sceneRenderSnapshot.phase != .loading)
        let restoredLayer = try #require(
            vm.sceneRenderSnapshot.layers.first {
                vm.scene(for: $0)?.primaryAssetId == "asset-1"
            }
        )
        #expect(restoredLayer.isPresentationReady)
        #expect(restoredLayer.opacity == 1)
    }

    @Test
    func `cancelling an unseen manual pending target discards its unconsumed history transaction`() async {
        let vm = makeSmartFillViewModel()

        vm.downloadManager.assetStates["asset-1"] = .notStarted
        vm.downloadManager.assetPreviewStates["asset-1"] = .notStarted
        vm.downloadManager.assetURLs["asset-1"] = nil
        vm.requestNextScene()
        await vm.synchronizePlaybackReadbackForTesting(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)

        #expect(vm.pendingPlaybackHistoryLedgerCommitCountForTesting == 1)
        vm.requestPreviousScene()

        #expect(vm.pendingPlaybackHistoryLedgerCommitCountForTesting == 0)
    }

    @Test
    func
        `cancelling a manual pending target while paused rebuilds the barrier for the restored automatic grace target`()
        async throws
    {
        let vm = makeSmartFillViewModel()
        vm.isAutoPlay = true
        let didPrepareNext = await waitUntilForTesting {
            vm.preparedSmartFillNextAssetIdsForTesting != nil
        }
        #expect(didPrepareNext)
        let automaticPrimaryAssetID = try #require(vm.preparedSmartFillNextAssetIdsForTesting?.first)

        var didBlockAutomaticLoad = false
        var resumeAutomaticLoad: CheckedContinuation<Void, Never>?
        vm.indexChangePhotoLoadHookForTesting = { assetID, size in
            if assetID == automaticPrimaryAssetID,
                size == .fullsize,
                !didBlockAutomaticLoad
            {
                didBlockAutomaticLoad = true
                await withCheckedContinuation { continuation in
                    resumeAutomaticLoad = continuation
                }
            }
            markReady(assetId: assetID, size: size, in: vm.downloadManager)
        }

        _ = vm.fireScheduledScenePresentationWakeUpForTesting()
        let automaticToken = vm.targetTransitionToken
        let automaticTargetIndex = vm.targetIndex
        let automaticLoadTask = Task {
            await vm.synchronizePlaybackReadbackForTesting(token: automaticToken, targetIndex: automaticTargetIndex)
        }
        let didStartAutomaticLoad = await waitUntilForTesting {
            didBlockAutomaticLoad && resumeAutomaticLoad != nil
        }
        try #require(didStartAutomaticLoad)
        let restoredBarrier = try #require(vm.activeScenePresentationBarrierForTesting)

        vm.toggleAutoPlayFromUserInteraction()
        vm.requestNextScene()
        await vm.synchronizePlaybackReadbackForTesting(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)
        vm.requestPreviousScene()

        #expect(vm.activeScenePresentationBarrierForTesting == restoredBarrier)

        resumeAutomaticLoad?.resume()
        await automaticLoadTask.value
    }

    @Test
    func `previous can still cancel a pending manual next target that follows the first seen scene`() async {
        let vm = makeSmartFillViewModel()

        vm.downloadManager.assetStates["asset-1"] = .notStarted
        vm.downloadManager.assetPreviewStates["asset-1"] = .notStarted
        vm.downloadManager.assetURLs["asset-1"] = nil
        vm.requestNextScene()
        await vm.synchronizePlaybackReadbackForTesting(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)
        #expect(vm.sceneRenderSnapshot.phase == .grace)
        #expect(vm.visibleOverlayScene?.primaryAssetId == "asset-0")
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")
        #expect(vm.canRequestPreviousScene)

        vm.requestPreviousScene()
        await vm.synchronizePlaybackReadbackForTesting(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-0")
    }

    @Test
    func `the in-memory playback history ledger drops its oldest entry once it reaches the limit`() {
        var ledger = PlaybackHistoryLedger(retainedEntryLimit: 3)
        ledger.reset(with: PlaybackScene(primaryAsset: makeAsset(id: "asset-0", width: 6000, height: 4000)))

        for index in 1...4 {
            ledger.append(PlaybackScene(primaryAsset: makeAsset(id: "asset-\(index)", width: 6000, height: 4000)))
        }

        #expect(ledger.retainedEntryLimit == 3)
        #expect(PlaybackHistoryLedgerLimits.retainedEntryLimit == 1_000)
        #expect(ledger.entries.map { $0.scene.primaryAssetId } == ["asset-2", "asset-3", "asset-4"])
        #expect(ledger.cursor == 2)
        #expect(ledger.previousTarget?.entry.scene.primaryAssetId == "asset-3")
    }

    @Test
    func `the model-level memory estimate for 1000 playback history entries stays lightweight`() {
        var ledger = PlaybackHistoryLedger(retainedEntryLimit: PlaybackHistoryLedgerLimits.retainedEntryLimit)
        ledger.reset(with: makeEstimatedHistoryScene(index: 0, slotCount: 1))
        for index in 1..<PlaybackHistoryLedgerLimits.retainedEntryLimit {
            ledger.append(makeEstimatedHistoryScene(index: index, slotCount: index.isMultiple(of: 2) ? 2 : 1))
        }

        let estimate = estimatePlaybackHistoryLedgerMemory(ledger)
        print(
            """
            PLAYBACK_HISTORY_LEDGER_MEMORY_ESTIMATE entries=\(estimate.entryCount) rawBytes=\(estimate.rawBytes) rawMiB=\(formatMiB(estimate.rawBytes)) conservativeBytes=\(estimate.conservativeBytes) conservativeMiB=\(formatMiB(estimate.conservativeBytes))
            """
        )

        #expect(estimate.entryCount == PlaybackHistoryLedgerLimits.retainedEntryLimit)
        #expect(estimate.rawBytes < rawMemoryBudgetBytes)
        #expect(estimate.conservativeBytes < conservativeMemoryBudgetBytes)
    }
}
