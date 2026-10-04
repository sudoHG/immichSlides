import Foundation
import Testing
@testable import immichSlides

extension SlideShowViewModelNavigationSemanticsTests {
    @Test
    func
        `prepared request capture only copies the raw planning snapshot and does not build a SmartFill candidate summary`()
        throws
    {
        let vm = makeSmartFillViewModel()
        vm.resetSmartFillCandidateSummaryBuildCountForTesting()

        let request = try #require(vm.capturePreparedSmartFillPlanRequestForTesting(startingAt: 1))

        #expect(vm.smartFillCandidateSummaryBuildCountForTesting == 0)
        #expect(request.rawAssetSnapshots.count > 1)
        #expect(request.rawAssetSnapshots.first?.assetId == "asset-1")
        #expect(request.rawAssetSnapshots.first?.reference == nil)
        #expect(request.rawAssetSnapshots.first?.sourceImageSummary == nil)
        #expect(request.protectionFingerprint == request.protectionSnapshot.smartFillReplanFingerprint)
    }

    @Test
    func `a late prepared plan result is discarded by request freshness and cannot overwrite the newer prepared ring`()
        throws
    {
        let vm = makeSmartFillViewModel()
        let requestA = try #require(vm.capturePreparedSmartFillPlanRequestForTesting(startingAt: 1))
        let resultA = try #require(SmartFillPreparedPlanBuilder.makeResult(for: requestA))

        let replacementAssets = (0..<6).map { makeAsset(id: "replacement-asset-\($0)", width: 6000, height: 4000) }
        markReady(replacementAssets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(replacementAssets)

        let requestB = try #require(vm.capturePreparedSmartFillPlanRequestForTesting(startingAt: 1))
        let resultB = try #require(SmartFillPreparedPlanBuilder.makeResult(for: requestB))

        #expect(vm.applyPreparedSmartFillPlanResultForTesting(resultA, request: requestA) == .stale)
        #expect(vm.applyPreparedSmartFillPlanResultForTesting(resultB, request: requestB) == .applied)
        #expect(vm.preparedSmartFillNextAssetIdsForTesting == resultB.selectedAssetIds)
    }

    @Test
    func `the background prepared plan builder matches the legacy MainActor SmartFill planner's selection`() throws {
        let vm = makeSmartFillViewModel()
        let richAssets = [
            makeRichAsset(id: "rich-landscape-face", width: 6000, height: 4000),
            makeRichAsset(id: "rich-portrait-face", width: 3024, height: 4032),
            makeRichAsset(id: "rich-wide-exif", width: 5200, height: 2600),
            makeRichAsset(id: "rich-tall-exif", width: 2400, height: 4200),
            makeRichAsset(id: "rich-square-face", width: 3600, height: 3600),
            makeRichAsset(id: "rich-later-landscape", width: 4800, height: 3200)
        ]
        markReady(richAssets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(richAssets)

        let request = try #require(vm.capturePreparedSmartFillPlanRequestForTesting(startingAt: 1))
        let preparedResult = try #require(SmartFillPreparedPlanBuilder.makeResult(for: request))
        let mainActorPlan = try #require(vm.makeSmartFillScenePlanComparisonForTesting(startingAt: 1))

        #expect(mainActorPlan.selectedAssetIds == preparedResult.selectedAssetIds)
        #expect(mainActorPlan.slotRoles == preparedResult.readback.slotRoles)
        #expect(mainActorPlan.layoutVariant == preparedResult.readback.layoutVariant)
        #expect(mainActorPlan.ratioPreset == preparedResult.readback.ratioPreset)
        #expect(mainActorPlan.fallbackCategory == preparedResult.readback.fallbackCategory)
        #expect(mainActorPlan.nextCandidateCursorOffset == preparedResult.nextCandidateCursorOffset)
    }

    @Test
    func
        `SmartFill autoplay skips the tick on a prepared miss instead of falling back to the MainActor planner synchronously`()
    {
        let vm = makeSmartFillViewModel()
        vm.isAutoPlay = true
        markReady(vm.assets, in: vm.downloadManager)
        vm.clearPreparedSmartFillRingForTesting()
        vm.resetSmartFillCandidateSummaryBuildCountForTesting()
        let originalToken = vm.targetTransitionToken

        _ = vm.fireScheduledScenePresentationWakeUpForTesting()

        #expect(vm.currentIndex == 0)
        #expect(vm.targetIndex == 0)
        #expect(vm.targetTransitionToken == originalToken)
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0"])
        #expect(vm.smartFillCandidateSummaryBuildCountForTesting == 0)
    }

    @Test
    func
        `after a SmartFill autoplay prepared miss, playback advances on the next tick once the background result is ready`()
        async
    {
        let vm = makeSmartFillViewModel()
        vm.isAutoPlay = true
        markReady(vm.assets, in: vm.downloadManager)
        vm.clearPreparedSmartFillRingForTesting()

        _ = vm.fireScheduledScenePresentationWakeUpForTesting()
        #expect(vm.currentIndex == 0)

        let didPrepareNext = await waitUntilForTesting {
            vm.preparedSmartFillNextAssetIdsForTesting != nil
        }
        #expect(didPrepareNext)

        _ = vm.fireScheduledScenePresentationWakeUpForTesting()
        let token = vm.targetTransitionToken
        let targetIndex = vm.targetIndex
        await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)

        #expect(vm.currentIndex == targetIndex)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")
    }

    @Test
    func
        `after a hidden SmartFill autoplay target exhausts retries, it requests the next target without the requestScene MainActor planner`()
        async
    {
        let vm = makeSmartFillViewModel()
        vm.isAutoPlay = true
        markReady(vm.assets, in: vm.downloadManager)
        vm.clearPreparedSmartFillRingForTesting()
        vm.resetSmartFillCandidateSummaryBuildCountForTesting()
        vm.resetSmartFillMainActorPlannerCallCountsForTesting()
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }

        _ = vm.fireScheduledScenePresentationWakeUpForTesting()
        let didPublishFailedTarget = await waitUntilForTesting {
            vm.safeCurrentScene?.primaryAssetId == "asset-1"
        }
        #expect(didPublishFailedTarget)
        let failedLayer = vm.sceneRenderSnapshot.layers.last { layer in
            vm.scene(for: layer)?.primaryAssetId == "asset-1"
        }
        #expect(failedLayer != nil)
        if let failedLayer {
            failSceneRendererThroughRetryBudget(layer: failedLayer, viewModel: vm)
        }

        let didRequestNextTarget = await waitUntilForTesting {
            vm.safeCurrentScene?.primaryAssetId == "asset-2"
        }
        #expect(didRequestNextTarget)
        #expect(vm.scenePresentationContractProbeLabel(for: vm.sceneRenderSnapshot).contains("historyCount=1"))
        #expect(vm.smartFillCandidateSummaryBuildCountForTesting == 0)
        #expect(vm.smartFillMainActorPlannerCallCountForTesting(.requestScene) == 0)
    }

    @Test
    func `after a failed SmartFill autoplay target is replaced, the old renderer callback cannot commit to history`()
        async
    {
        let vm = makeSmartFillViewModel()
        vm.isAutoPlay = true
        markReady(vm.assets, in: vm.downloadManager)
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        let didPrepareFailedNext = await waitUntilForTesting {
            vm.preparedSmartFillNextAssetIdsForTesting?.first == "asset-1"
        }
        #expect(didPrepareFailedNext)
        vm.resetSmartFillMainActorPlannerCallCountsForTesting()

        _ = vm.fireScheduledScenePresentationWakeUpForTesting()
        let failedLayer = vm.sceneRenderSnapshot.layers.last { layer in
            vm.scene(for: layer)?.primaryAssetId == "asset-1"
        }
        #expect(failedLayer != nil)
        guard let failedLayer,
            let failedScene = vm.scene(for: failedLayer),
            let failedSlot = failedScene.photoSlots.first
        else {
            return
        }
        let staleRendererIdentity = SceneRendererIdentity(
            generation: failedLayer.identity.generation,
            attemptID: vm.scenePresentationRendererAttemptID(for: failedLayer),
            sceneID: failedLayer.identity.sceneID,
            slotID: failedSlot.id,
            assetID: failedSlot.asset.id
        )
        failSceneRendererThroughRetryBudget(layer: failedLayer, viewModel: vm)

        let didReplaceFailedTarget = await waitUntilForTesting {
            vm.safeCurrentScene?.primaryAssetId == "asset-2"
        }
        #expect(didReplaceFailedTarget)
        let historyBeforeStaleCallback = vm.scenePresentationContractProbeLabel(for: vm.sceneRenderSnapshot)
        vm.rendererDecoded(staleRendererIdentity)

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-2")
        #expect(historyBeforeStaleCallback.contains("historyCount=1"))
        #expect(vm.scenePresentationContractProbeLabel(for: vm.sceneRenderSnapshot).contains("historyCount=1"))
        #expect(vm.smartFillMainActorPlannerCallCountForTesting(.requestScene) == 0)
    }

    @Test
    func `the SmartFill MainActor planner call-site hook distinguishes a manual miss from an autoplay miss`() {
        let manualVM = makeSmartFillViewModel()
        manualVM.clearPreparedSmartFillRingForTesting()
        manualVM.resetSmartFillMainActorPlannerCallCountsForTesting()

        manualVM.requestNextScene()

        #expect(manualVM.smartFillMainActorPlannerCallCountForTesting(.manualNext) == 1)

        let autoplayVM = makeSmartFillViewModel()
        autoplayVM.isAutoPlay = true
        markReady(autoplayVM.assets, in: autoplayVM.downloadManager)
        autoplayVM.clearPreparedSmartFillRingForTesting()
        autoplayVM.resetSmartFillMainActorPlannerCallCountsForTesting()

        _ = autoplayVM.fireScheduledScenePresentationWakeUpForTesting()

        #expect(autoplayVM.smartFillMainActorPlannerCallCountForTesting(.autoplayNext) == 0)
    }
}
