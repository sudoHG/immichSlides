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
        #expect(request.rawAssetSnapshots.map(\.assetId) == (1..<6).map { "asset-\($0)" })
        #expect(request.playbackSessionSeed == "generation-0")
        #expect(request.sceneOrdinal == 1)
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

        let changedProtection = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.controlBar(
                    rect: PlaybackProtectionRect(x: 0, y: 0.8, width: 1, height: 0.2),
                    activeConditionSummary: "visible=true"))
        ])
        let changes: [(String, (SlideShowViewModel) -> Void)] = [
            (
                "source",
                { model in
                    let assets = model.assets
                    model.preparePlaybackSourceForPresentation(
                        to: .filtered(FilterSelection(albumIds: ["album-other"])))
                    model.replacePlaybackAssetsForTesting(assets)
                }
            ),
            ("cursor", { $0.requestNextScene() }),
            (
                "surface",
                { model in
                    model.updateSmartFillSurfaceForTesting(
                        PlaybackSmartFillSurface(
                            pixelSize: PlaybackPlanningPixelSize(width: 1170, height: 2532),
                            profile: .iPhone, orientation: .portrait))
                }
            ),
            (
                "protection",
                { model in
                    model.updateSmartFillSurface(
                        PlaybackSmartFillSurface(
                            pixelSize: self.iPadLandscapePlanningPixelSize, profile: .iPad, orientation: .landscape),
                        protectionSnapshot: changedProtection)
                }
            ),
            (
                "display mode",
                { model in
                    model.applyPlaybackSettings(PlaybackSettings(autoPlayEnabled: false, displayMode: .singlePhoto))
                }
            )
        ]
        for (name, change) in changes {
            let model = makeSmartFillViewModel()
            let oldRequest = try #require(model.capturePreparedSmartFillPlanRequestForTesting(startingAt: 1))
            let oldResult = try #require(SmartFillPreparedPlanBuilder.makeResult(for: oldRequest))
            change(model)
            let sceneBeforeDelivery = model.safeCurrentScene
            #expect(
                model.applyPreparedSmartFillPlanResultForTesting(oldResult, request: oldRequest) == .stale,
                "\(name) must reject the old proposal")
            #expect(model.safeCurrentScene?.id == sceneBeforeDelivery?.id)
            #expect(model.safeCurrentScene?.assetIds == sceneBeforeDelivery?.assetIds)
        }

        let waiting = makeSmartFillViewModel()
        waiting.isAutoPlay = true
        markReady(waiting.assets, in: waiting.downloadManager)
        waiting.clearPreparedSmartFillRingForTesting()
        let lookaheadRequest = try #require(waiting.capturePreparedSmartFillPlanRequestForTesting(startingAt: 1))
        let lookaheadResult = try #require(SmartFillPreparedPlanBuilder.makeResult(for: lookaheadRequest))
        _ = waiting.fireScheduledScenePresentationWakeUpForTesting()
        #expect(waiting.currentIndex == 0)
        // Lookahead uses this same delivery entry without a start-time navigation tag.
        #expect(
            waiting.applyPreparedSmartFillPlanResultForTesting(lookaheadResult, request: lookaheadRequest) == .applied)
        #expect(waiting.safeCurrentScene?.primaryAssetId == "asset-1")
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

        // Fixed fixture expectations keep a shared conversion bug from making both paths agree incorrectly.
        let expectedAssetIds = ["rich-portrait-face", "rich-tall-exif"]
        let expectedFrames = [
            PlaybackPlanningRect(x: 0, y: 0, width: 0.5675698379401841, height: 1),
            PlaybackPlanningRect(x: 0.5675698379401841, y: 0, width: 0.4324301620598159, height: 1)
        ]
        let expectedCrops = [
            PlaybackPlanningRect(x: 0, y: 0, width: 1, height: 0.9905837806362195),
            PlaybackPlanningRect(x: 0, y: 0, width: 1, height: 0.990592943997374)
        ]
        let expectedReadback = PlaybackSmartFillSceneReadback(
            version: "smart-fill-scene-v2",
            sceneType: .double,
            layoutPolicyId: "ipad-landscape-pr49-v1",
            surfaceKey: "iPad-landscape-regular-regular-safeA",
            layoutVariant: .leftPrimaryRightSecondary,
            ratioPreset: "constructive-57/43",
            slotRoles: [.primary, .secondary],
            fallbackReason: nil,
            fallbackCategory: .none,
            candidateWindowUsed: 24,
            evaluationCount: 2,
            rotationStartLayoutVariant: .rightPrimaryLeftSecondary,
            rotationStartRatioPreset: "65/35",
            acceptedLayoutVariant: .leftPrimaryRightSecondary,
            acceptedRatioPreset: "constructive-57/43",
            rotationKeyHashPrefix: "b059ad445e9a",
            rejectedLayoutReasonTopList: [.cropRetentionTooLow, .verticalDoubleDisallowedOnSurface],
            reasonCodes: [
                "scene:double", "policy:ipad-landscape-pr49-v1", "surface:iPad-landscape-regular-regular-safeA",
                "layout:left-primary-right-secondary", "ratio:constructive-57/43", "candidateWindow:24",
                "fallbackCategory:none", "reject:vertical-double-disallowed-on-surface", "reject:crop-retention-too-low"
            ],
            actionTimestamp: nil,
            scenePublishTimestamp: nil,
            actionToSceneLatencyMilliseconds: nil,
            qaDebugSummary: [
                "version=smart-fill-planner-v2", "sceneType=double",
                "surfaceKey=iPad-landscape-regular-regular-safeA",
                "surfaceFingerprint=iPad-landscape-regular-regular-safeA|size:85x64|aspect:27",
                "policy=ipad-landscape-pr49-v1", "layoutVariant=left-primary-right-secondary",
                "ratioPreset=constructive-57/43",
                "photoCanvasId=surface:iPad-landscape-regular-regular-safeA|size:85x64|aspect:27|safeArea:safeA|hardObstruction:none|px:2732x2048|pt:2732.000x2048.000|scale:1.000|unit:0.000,0.000,1.000,1.000",
                "photoCanvasPointSize=2732.000x2048.000", "photoCanvasPixelSize=2732x2048",
                "canvasCoverage=1.000", "emptyCanvasRatio=0.000", "maxContinuousEmptyAxisRatio=0.000",
                "gapPixelCount=0", "overlapPixelCount=0", "slotCount=2", "slotRoles=primary,secondary",
                "slotRefs=asset_f3ea688f448b5754,asset_267ece7a44aba2a4",
                "currentAssetDisposition=primary-slot", "currentAssetAbsentReason=none",
                "currentAssetSlotAreaRatio=0.568", "currentAssetCropRetention=0.991",
                "currentAssetProtectedRegionCoverage=1.000", "currentAssetFaceProtectionPassed=true",
                "currentAssetSubjectProtectionPassed=true", "currentAssetVisibleQualityClass=acceptable",
                "cropRetentionThresholdUsed=0.600", "ledgerSceneAssets=asset_f3ea688f448b5754,asset_267ece7a44aba2a4",
                "acceptedSceneSearchTier=double", "candidateWindowRequested=72",
                "candidateWindowExpansionTrace=24:accepted",
                "slotFrames=x0.000y0.000w0.568h1.000,x0.568y0.000w0.432h1.000",
                "slotCropRects=x0.000y0.000w1.000h0.991,x0.000y0.000w1.000h0.991", "cropRetention=0.991,0.991",
                "protectionContained=true,true", "protectionStatus=accepted", "protectionHardOverlapCount=0",
                "softOverlayOverlapWarningCount=0", "controlBarSubjectOverlapWarningCount=0",
                "controlBarHardRejected=false",
                "exifOverlayOverlapWarningCount=0", "exifOverlayHardRejected=false", "protectionOverlapDetails=none",
                "fallbackCategory=none", "candidateWindowUsed=24", "evaluationCount=2",
                "rotationStartLayoutVariant=right-primary-left-secondary", "rotationStartRatioPreset=65/35",
                "acceptedLayoutVariant=left-primary-right-secondary", "acceptedRatioPreset=constructive-57/43",
                "rotationKeyHashPrefix=b059ad445e9a", "fallback=none",
                "rejects=vertical-double-disallowed-on-surface,crop-retention-too-low",
                "rejectedLayoutReasonTopList=crop-retention-too-low,vertical-double-disallowed-on-surface",
                "rejectedLayoutDiagnostics=reason:crop-retention-too-low|layout:single|ratio:full|role:primary|slotIndex:0|imageAspect:0.750|slotAspect:1.334|cropRetention:0.562|threshold:0.600|thresholdDelta:-0.038|secondaryArea:1.000|minimumSecondaryArea:0.180"
            ].joined(separator: ";")
        )
        #expect(mainActorPlan.selectedAssetIds == expectedAssetIds)
        #expect(preparedResult.selectedAssetIds == expectedAssetIds)
        #expect(mainActorPlan.slotPlanning.map(\.displayFrame) == expectedFrames)
        #expect(preparedResult.slots.map(\.frameInScene) == expectedFrames)
        #expect(mainActorPlan.slotPlanning.map(\.cropRect) == expectedCrops)
        #expect(preparedResult.slots.map(\.cropRectInSource) == expectedCrops)
        #expect(mainActorPlan.readback == expectedReadback)
        #expect(preparedResult.readback == expectedReadback)
        #expect(mainActorPlan.nextCandidateCursorOffset == 1)
        #expect(preparedResult.nextCandidateCursorOffset == 1)
        #expect(preparedResult.sourceCursor == 1)
        #expect(preparedResult.displayedAssetIds == Set(expectedAssetIds))
        #expect(vm.smartFillCandidateCursorIndexForTesting == 1)
    }

    @Test
    func
        `SmartFill autoplay skips the tick on a prepared miss instead of falling back to the MainActor planner synchronously`()
        async
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

        // A fresh proposal still installs if the user pauses while the prepared miss is computing.
        vm.toggleAutoPlayFromUserInteraction()
        let didDeliverWhilePaused = await waitUntilForTesting {
            vm.preparedSmartFillNextAssetIdsForTesting != nil
        }
        #expect(didDeliverWhilePaused)
        #expect(vm.preparedSmartFillNextAssetIdsForTesting == ["asset-1"])
        #expect(vm.currentIndex == 0)
        #expect(vm.targetIndex == 0)
        #expect(vm.targetTransitionToken == originalToken)
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
        vm.clearPreparedSmartFillRingForTesting()
        if let failedLayer {
            failSceneRendererThroughRetryBudget(layer: failedLayer, viewModel: vm)
        }
        vm.suspendScenePresentationForBackground()

        let didRequestNextTarget = await waitUntilForTesting {
            vm.safeCurrentScene?.primaryAssetId == "asset-2"
        }
        #expect(didRequestNextTarget)
        vm.resumeScenePresentationFromBackground()
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-2")
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
