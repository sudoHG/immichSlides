//
//  SlideShowViewModelNavigationSemanticsTests.swift
//  immichSlidesTests
//
//  Covers scene transaction readiness semantics for manual navigation and auto play.
//

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.serialized, .sharedRuntimeIsolation)
struct SlideShowViewModelNavigationSemanticsTests {
    private let rawMemoryBudgetBytes: Int = 8 * 1024 * 1024
    private let conservativeMemoryBudgetBytes: Int = 16 * 1024 * 1024
    private let iPadLandscapePlanningPixelSize = PlaybackPlanningPixelSize(width: 2732, height: 2048)
    private let iPhonePortraitPlanningPixelSize = PlaybackPlanningPixelSize(width: 1179, height: 2556)
    private let latencyToleranceMilliseconds: Double = 0.001
    private let conservativeMemoryHeadroomFactor: Int = 2
    // Estimated storage headers exclude payload bytes and reserved capacity.
    private let estimatedStringStorageOverheadBytes: Int = 32
    private let estimatedArrayStorageOverheadBytes: Int = 32
    private let bytesPerMiB: Double = 1_048_576.0

    init() {
        // Each test starts from the default display policy, so single-photo mode left by other settings tests
        // does not leak in.

        PlaybackSettingsStore().clear()
        FilterSelectionStore().clear()
    }

    @Test
    func `SmartFill manual next publishes the scene before waiting for the pending slot fullsize`() async throws {
        let vm = makeSmartFillViewModel()

        var blockedLoads: [String] = []
        var didEnterLoad = false
        var finishLoad: CheckedContinuation<Void, Never>?
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            if assetId == "asset-1", size == .fullsize, finishLoad == nil {
                blockedLoads.append("\(assetId):\(size.rawValue)")
                didEnterLoad = true
                await withCheckedContinuation { pending in
                    finishLoad = pending
                }
            }
            markReady(assetId: assetId, size: size, in: vm.downloadManager)
        }

        vm.requestNextScene()
        let token = vm.targetTransitionToken
        let targetIndex = vm.targetIndex

        let transitionTask = Task {
            await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
        }
        let didStartLoad = await waitUntilForTesting { didEnterLoad && finishLoad != nil }

        try #require(didStartLoad)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")
        #expect(vm.currentIndex == targetIndex)

        finishLoad?.resume()
        await transitionTask.value

        #expect(blockedLoads == ["asset-1:fullsize"])
    }

    @Test
    func `SmartFill manual next latency manifest times from scene publish and survives a late load`() async throws {
        let vm = makeSmartFillViewModel()
        var now = 100.0
        vm.playbackManifestTimestampProviderForTesting = { now }

        var didEnterLoad = false
        var finishLoad: CheckedContinuation<Void, Never>?
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            if assetId == "asset-1", size == .fullsize, finishLoad == nil {
                didEnterLoad = true
                await withCheckedContinuation { pending in
                    finishLoad = pending
                }
            }
            markReady(assetId: assetId, size: size, in: vm.downloadManager)
        }

        vm.requestNextScene()
        let token = vm.targetTransitionToken
        let targetIndex = vm.targetIndex

        // The request itself publishes atomically; the old transition handler no longer owns the commit moment.
        now = 100.025
        let transitionTask = Task {
            await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
        }
        let didStartLoad = await waitUntilForTesting { didEnterLoad && finishLoad != nil }

        try #require(didStartLoad)
        let publishedReadback = vm.safeCurrentScene?.smartFillReadback
        assertLatency(
            publishedReadback,
            actionTimestamp: 100.0,
            scenePublishTimestamp: 100.0,
            latencyMilliseconds: 0.0
        )

        now = 999.0
        finishLoad?.resume()
        await transitionTask.value

        let finalReadback = vm.safeCurrentScene?.smartFillReadback
        assertLatency(
            finalReadback,
            actionTimestamp: 100.0,
            scenePublishTimestamp: 100.0,
            latencyMilliseconds: 0.0
        )
    }

    @Test
    func `a late load for a SmartFill manual next cannot roll back the newer scene`() async throws {
        let vm = makeSmartFillViewModel()

        var didEnterFirstLoad = false
        var finishFirstLoad: CheckedContinuation<Void, Never>?
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            if assetId == "asset-1", size == .fullsize, finishFirstLoad == nil {
                didEnterFirstLoad = true
                await withCheckedContinuation { pending in
                    finishFirstLoad = pending
                }
            }
            markReady(assetId: assetId, size: size, in: vm.downloadManager)
        }

        vm.requestNextScene()
        let firstToken = vm.targetTransitionToken
        let firstTargetIndex = vm.targetIndex
        let firstTransitionTask = Task {
            await vm.synchronizePlaybackReadbackForTesting(token: firstToken, targetIndex: firstTargetIndex)
        }
        let didStartFirstLoad = await waitUntilForTesting { didEnterFirstLoad && finishFirstLoad != nil }

        try #require(didStartFirstLoad)
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-1"])

        vm.requestNextScene()
        let secondToken = vm.targetTransitionToken
        let secondTargetIndex = vm.targetIndex
        await vm.synchronizePlaybackReadbackForTesting(token: secondToken, targetIndex: secondTargetIndex)

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-2")
        #expect(vm.currentIndex == secondTargetIndex)

        finishFirstLoad?.resume()
        await firstTransitionTask.value

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-2")
        #expect(vm.currentIndex == secondTargetIndex)
    }

    @Test
    func
        `EXIF overlay owner during a transition animation stays on the committed current scene and is not hidden by the transition state`()
        async throws
    {
        let vm = makeSmartFillViewModel()

        vm.requestNextScene()
        let token = vm.targetTransitionToken
        let targetIndex = vm.targetIndex

        await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)

        let overlayState = try #require(vm.visibleOverlayState)
        // The seen scene stays on screen, and keeps the visible EXIF, while the pending target decodes behind it.
        #expect(vm.sceneRenderSnapshot.phase == .grace)
        #expect(vm.sceneRenderSnapshot.layers.map(\.role) == [.stable, .incoming])
        #expect(vm.visibleOverlayScene?.primaryAssetId == "asset-0")
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")
        #expect(overlayState.ownerSceneId == vm.safeCurrentScene?.id)
        #expect(overlayState.ownerPrimaryAssetId == "asset-1")
        #expect(vm.overlayAssetIdProbeLabel == "asset-1")

        completeCurrentScenePresentation(vm)

        #expect(vm.sceneRenderSnapshot.layers.map(\.role) == [.stable])
        #expect(vm.visibleOverlayState?.ownerPrimaryAssetId == "asset-1")
        #expect(vm.overlayAssetIdProbeLabel == "asset-1")
    }

    @Test
    func `a stale animation completion callback cannot pull the overlay owner back to the old scene`() async throws {
        let vm = makeSmartFillViewModel()

        vm.requestNextScene()
        let firstToken = vm.targetTransitionToken
        let firstTargetIndex = vm.targetIndex
        await vm.synchronizePlaybackReadbackForTesting(token: firstToken, targetIndex: firstTargetIndex)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")
        #expect(vm.overlayAssetIdProbeLabel == "asset-1")

        vm.requestNextScene()
        let secondToken = vm.targetTransitionToken
        let secondTargetIndex = vm.targetIndex
        await vm.synchronizePlaybackReadbackForTesting(token: secondToken, targetIndex: secondTargetIndex)

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-2")
        #expect(vm.visibleOverlayState?.ownerPrimaryAssetId == "asset-2")
        #expect(vm.overlayAssetIdProbeLabel == "asset-2")

        completeCurrentScenePresentation(vm)

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-2")
        #expect(vm.visibleOverlayState?.ownerPrimaryAssetId == "asset-2")
        #expect(vm.overlayAssetIdProbeLabel == "asset-2")
    }

    @Test
    func `SmartFill autoplay only paces the request and does not start a transition while the next slot is pending`() {
        let vm = makeSmartFillViewModel()
        vm.isAutoPlay = true
        vm.downloadManager.assetStates["asset-1"] = .notStarted
        vm.downloadManager.assetURLs["asset-1"] = nil
        let originalToken = vm.targetTransitionToken

        _ = vm.fireScheduledScenePresentationWakeUpForTesting()

        #expect(vm.currentIndex == 0)
        #expect(vm.targetIndex == 0)
        #expect(vm.targetTransitionToken == originalToken)
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0"])
    }

    @Test
    func `SmartFill autoplay requests and commits immediately once ready without waiting on the slot load`()
        async throws
    {
        let vm = makeSmartFillViewModel()
        vm.isAutoPlay = true
        let didPrepareNext = await waitUntilForTesting {
            vm.preparedSmartFillNextAssetIdsForTesting != nil
        }
        #expect(didPrepareNext)
        #expect(vm.preparedSmartFillNextSourceCursorForTesting == vm.currentPreparedSmartFillSourceCursorForTesting)
        #expect(vm.preparedSmartFillNextTargetIndexForTesting == vm.playbackSceneCountForTesting)
        let preparedPrimaryAssetId = vm.preparedSmartFillNextAssetIdsForTesting?.first

        var didEnterLoad = false
        var finishLoad: CheckedContinuation<Void, Never>?
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            if assetId == preparedPrimaryAssetId, size == .fullsize, finishLoad == nil {
                didEnterLoad = true
                await withCheckedContinuation { pending in
                    finishLoad = pending
                }
            }
            markReady(assetId: assetId, size: size, in: vm.downloadManager)
        }

        let tokenBeforeAutoPlay = vm.targetTransitionToken
        _ = vm.fireScheduledScenePresentationWakeUpForTesting()
        if vm.targetTransitionToken == tokenBeforeAutoPlay {
            let didPrepareAfterSkippedTick = await waitUntilForTesting {
                vm.preparedSmartFillNextAssetIdsForTesting?.first == preparedPrimaryAssetId
            }
            #expect(didPrepareAfterSkippedTick)
            _ = vm.fireScheduledScenePresentationWakeUpForTesting()
        }
        let token = vm.targetTransitionToken
        let targetIndex = vm.targetIndex

        let transitionTask = Task {
            await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
        }
        let didStartLoad = await waitUntilForTesting { didEnterLoad && finishLoad != nil }

        try #require(didStartLoad)
        #expect(vm.currentIndex == targetIndex)
        #expect(vm.safeCurrentScene?.primaryAssetId == preparedPrimaryAssetId)

        finishLoad?.resume()
        await transitionTask.value

        #expect(vm.currentIndex == targetIndex)
        #expect(vm.safeCurrentScene?.primaryAssetId == preparedPrimaryAssetId)
    }

    @Test
    func `SmartFill autoplay latency manifest times from the immediate commit after pacing allows the request`()
        async throws
    {
        let vm = makeSmartFillViewModel()
        vm.isAutoPlay = true
        let didPrepareNext = await waitUntilForTesting {
            vm.preparedSmartFillNextAssetIdsForTesting != nil
        }
        #expect(didPrepareNext)
        var now = 200.0
        vm.playbackManifestTimestampProviderForTesting = { now }

        var didEnterLoad = false
        var finishLoad: CheckedContinuation<Void, Never>?
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            if assetId == "asset-1", size == .fullsize, finishLoad == nil {
                didEnterLoad = true
                await withCheckedContinuation { pending in
                    finishLoad = pending
                }
            }
            markReady(assetId: assetId, size: size, in: vm.downloadManager)
        }

        _ = vm.fireScheduledScenePresentationWakeUpForTesting()
        let token = vm.targetTransitionToken
        let targetIndex = vm.targetIndex

        let transitionTask = Task {
            await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
        }
        let didStartLoad = await waitUntilForTesting { didEnterLoad && finishLoad != nil }

        try #require(didStartLoad)
        let publishedReadback = vm.safeCurrentScene?.smartFillReadback
        assertPublishTimingRecorded(publishedReadback, actionTimestamp: 200.0)

        now = 999.0
        finishLoad?.resume()
        await transitionTask.value

        let readback = vm.safeCurrentScene?.smartFillReadback
        assertPublishTimingRecorded(readback, actionTimestamp: 200.0)
    }

    @Test
    func `SmartFill runtime probe summary reports live fields from the view model`() {
        let vm = makeSmartFillViewModel()
        let currentAssetIds = vm.safeCurrentScene?.photoSlots.map(\.asset.id) ?? []
        for assetId in currentAssetIds {
            vm.downloadManager.assetURLs[assetId] = URL(string: "https://example.invalid/\(assetId).jpg")!
        }
        let expectedReadiness = Array(repeating: "ready", count: currentAssetIds.count).joined(separator: ",")

        let summary = vm.currentSmartFillRuntimeQADebugSummary(
            controlBarVisible: true,
            exifOverlayVisible: false
        )

        #expect(summary?.contains("slotReadiness=\(expectedReadiness)") == true)
        #expect(summary?.contains("controlBarVisible=true") == true)
        #expect(summary?.contains("exifOverlayVisible=false") == true)
        #expect(summary?.contains("publishReason=initial") == true)
        #expect(summary?.contains("preparedHit=false") == true)
        for assetId in currentAssetIds {
            #expect(summary?.contains(assetId) == false)
        }
    }

    @Test
    func `SmartFill runtime probe summary does not duplicate manifest keys`() throws {
        let vm = makeSmartFillViewModel()
        let summary = try #require(
            vm.currentSmartFillRuntimeQADebugSummary(
                controlBarVisible: true,
                exifOverlayVisible: false
            ))

        let keys =
            summary
            .split(separator: ";")
            .compactMap { part -> String? in
                guard let equalIndex = part.firstIndex(of: "=") else { return nil }
                return String(part[..<equalIndex])
            }
        let duplicateKeys = Dictionary(grouping: keys, by: { $0 })
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()

        #expect(duplicateKeys.isEmpty)
    }

    @Test
    func `SmartFill startup runtime manifest includes all required startup and photo-load milestone keys`() async throws
    {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: iPadLandscapePlanningPixelSize,
                profile: .iPad,
                orientation: .landscape
            )
        )
        let assets = (0..<6).map { makeAsset(id: "startup-asset-\($0)", width: 6000, height: 4000) }
        var now = 1_000.0
        vm.playbackManifestTimestampProviderForTesting = {
            now += 0.010
            return now
        }
        vm.loadAssetsHookForTesting = { _ in
            markReady(assets, in: vm.downloadManager)
            for asset in assets {
                vm.downloadManager.assetURLs[asset.id] = URL(string: "https://example.invalid/\(asset.id).jpg")!
            }
            return assets
        }
        vm.initialPhotoLoadHookForTesting = { assetId in
            vm.downloadManager.recordPhotoLoadRuntimePhaseForTesting(
                assetId: assetId, size: .fullsize, phase: "cacheChecked", timestamp: now, cacheStatus: "miss")
            now += 0.010
            vm.downloadManager.recordPhotoLoadRuntimePhaseForTesting(
                assetId: assetId, size: .fullsize, phase: "downloadRequestStarted", timestamp: now, cacheStatus: "miss")
            now += 0.010
            vm.downloadManager.recordPhotoLoadRuntimePhaseForTesting(
                assetId: assetId, size: .fullsize, phase: "downloadCompleted", timestamp: now, cacheStatus: "miss")
            now += 0.010
            vm.downloadManager.recordPhotoLoadRuntimePhaseForTesting(
                assetId: assetId, size: .fullsize, phase: "decodeCompleted", timestamp: now, cacheStatus: "miss")
        }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }

        await vm.prepareInitialAssets()
        vm.recordSmartFillFirstImageDisplayedForTesting(assetId: assets[0].id)
        let summary = try #require(
            vm.currentSmartFillRuntimeQADebugSummary(
                controlBarVisible: true,
                exifOverlayVisible: false
            ))
        let fields = parseSummaryFields(summary)
        let timestamps = parsePhaseMap(try #require(fields["runtimePhaseTimestampsMs"]))
        let durations = parsePhaseMap(try #require(fields["runtimePhaseDurationsMs"]))
        let requiredPhases = [
            "playbackEntryRequested",
            "assetPoolRequestStarted",
            "assetPoolReady",
            "firstScenePlanningStarted",
            "firstScenePlanned",
            "firstScenePublished",
            "firstSlotReady",
            "allVisibleSlotsReady"
        ]

        for phase in requiredPhases {
            #expect(timestamps[phase] != nil, "runtimePhaseTimestampsMs is missing \(phase)")
            #expect(durations[phase] != nil, "runtimePhaseDurationsMs is missing \(phase)")
        }
        #expect(fields["assetPoolSizeAtFirstPlan"] == "6")
        #expect(fields["eligibleCandidateCountAtFirstPlan"] == "6")
        #expect(fields["firstSceneSlotReadiness"] == fields["slotReadiness"])
        #expect(fields["resourceReadinessAffectedFallback"] == "false")
        #expect(fields["controlBarAffectedFallback"] == "false")
        #expect(fields["legacyRendererUsedForSmartFillFallback"] == "false")
        let photoLoadTimestamps = parsePhaseMap(try #require(fields["photoLoadPhaseTimestampsMs"]))
        let photoLoadDurations = parsePhaseMap(try #require(fields["photoLoadPhaseDurationsMs"]))
        let requiredPhotoLoadPhases = [
            "cacheChecked",
            "downloadRequestStarted",
            "downloadCompleted",
            "decodeCompleted",
            "firstImageDisplayed"
        ]
        for phase in requiredPhotoLoadPhases {
            #expect(photoLoadTimestamps[phase] != nil, "photoLoadPhaseTimestampsMs is missing \(phase)")
            #expect(photoLoadDurations[phase] != nil, "photoLoadPhaseDurationsMs is missing \(phase)")
        }
        #expect(fields["firstPhotoCacheStatus"] == "miss")
        #expect(Double(try #require(fields["firstImageDisplayedRuntimeMs"])) != nil)
        #expect(fields["firstImageLoadStatus"] == "displayed")
    }

    @Test
    func `SmartFill initial startup does not wait for the non-visible candidate window to download`() async throws {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: iPhonePortraitPlanningPixelSize,
                profile: .iPhone,
                orientation: .portrait
            )
        )
        let assets = [
            makeAsset(id: "asset-raw-current-landscape", width: 5400, height: 3000),
            makeAsset(id: "asset-raw-later-primary", width: 1800, height: 2000),
            makeAsset(id: "asset-raw-extra-0", width: 1200, height: 1800),
            makeAsset(id: "asset-raw-extra-1", width: 1200, height: 1800)
        ]
        var candidateWindowRequests: [String] = []
        var initialSceneRequests: [String] = []
        vm.loadAssetsHookForTesting = { _ in assets }
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            candidateWindowRequests.append("\(assetId):\(size.rawValue)")
            markReady(assetId: assetId, size: size, in: vm.downloadManager)
            if size == .fullsize {
                vm.downloadManager.assetURLs[assetId] = URL(string: "https://example.invalid/\(assetId).jpg")!
            }
        }
        vm.initialPhotoLoadHookForTesting = { assetId in
            initialSceneRequests.append(assetId)
            markReady(assetId: assetId, size: .fullsize, in: vm.downloadManager)
            vm.downloadManager.assetURLs[assetId] = URL(string: "https://example.invalid/\(assetId).jpg")!
        }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }

        await vm.prepareInitialAssets()

        let currentSceneAssetIds = try #require(vm.safeCurrentScene?.photoSlots.map(\.asset.id))
        #expect(currentSceneAssetIds.count > 1)
        #expect(currentSceneAssetIds.first == "asset-raw-current-landscape")
        #expect(candidateWindowRequests.isEmpty)
        #expect(initialSceneRequests == currentSceneAssetIds)
    }

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

    @Test
    func `the playback history ledger lets previous cross the engine's retained scene window`() async throws {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        let assets = (0..<70).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
        markReady(assets, in: vm.downloadManager)
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            markReady(assetId: assetId, size: size, in: vm.downloadManager)
        }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)

        for expectedIndex in 1...60 {
            vm.requestNextScene()
            let token = vm.targetTransitionToken
            let targetIndex = vm.targetIndex

            await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
            completeCurrentScenePresentation(vm)

            #expect(vm.safeCurrentScene?.primaryAssetId == "asset-\(expectedIndex)")
        }

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
            previousAssetIds.append(afterAssetId)
        }

        #expect(previousAssetIds.last == "asset-5")

        vm.requestNextScene()
        await vm.synchronizePlaybackReadbackForTesting(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)
        completeCurrentScenePresentation(vm)

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-6")
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

        vm.requestNextScene()
        await settleManualRequest()
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")
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

        vm.requestPreviousScene()
        await vm.synchronizePlaybackReadbackForTesting(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")
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

    private func makeSmartFillViewModel() -> SlideShowViewModel {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: iPadLandscapePlanningPixelSize,
                profile: .iPad,
                orientation: .landscape
            )
        )
        let initialAssets = (0..<6).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
        markReady(initialAssets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(initialAssets)
        completeCurrentScenePresentation(vm)
        return vm
    }

    private func expectHistory(_ vm: SlideShowViewModel, assetIds: [String], cursor: Int) throws {
        let data = Data(vm.playbackHistoryLedgerDiagnosticsSummaryJSON.utf8)
        let history = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(history["suffixPrimaryAssetIds"] as? [String] == assetIds)
        #expect(history["entryCount"] as? Int == assetIds.count)
        #expect(history["cursor"] as? Int == cursor)
    }

    private func completeCurrentScenePresentation(_ vm: SlideShowViewModel) {
        var snapshot = vm.sceneRenderSnapshot
        guard let targetLayer = snapshot.layers.last(where: { $0.role == .incoming || $0.role == .stable }),
            let scene = vm.scene(for: targetLayer)
        else {
            return
        }

        for slot in scene.photoSlots {
            vm.rendererDecoded(
                SceneRendererIdentity(
                    generation: targetLayer.identity.generation,
                    attemptID: vm.scenePresentationRendererAttemptID(for: targetLayer),
                    sceneID: targetLayer.identity.sceneID,
                    slotID: slot.id,
                    assetID: slot.asset.id
                )
            )
        }

        snapshot = vm.sceneRenderSnapshot
        if snapshot.phase == .transition,
            snapshot.layers.last(where: { $0.role == .incoming })?.isPresentationReady == false,
            let transitionDeadline = vm.fireScheduledScenePresentationWakeUpForTesting()
        {
            vm.scenePresentationTimestampProviderForTesting = { transitionDeadline }
            snapshot = vm.sceneRenderSnapshot
        }

        guard
            let visibleLayer = snapshot.layers.last(where: {
                ($0.role == .incoming || $0.role == .stable) && $0.isPresentationReady
            })
        else {
            return
        }
        if visibleLayer.role == .incoming {
            let visibleTime =
                (visibleLayer.fadeStartTime ?? 0) + SceneTransitionDiagnostic.firstVisibleTickOffsetSeconds
            vm.scenePresentationTimestampProviderForTesting = { visibleTime }
        }
        snapshot = vm.sceneRenderSnapshot
        guard let displayedLayer = snapshot.layers.last(where: { $0.identity == visibleLayer.identity }) else {
            return
        }
        // As with the scene-root reporter, a paused first photo that goes straight to stable must still pass one
        // visible tick.
        let candidate = SceneVisibleFrameCandidate(
            layerIdentity: ScenePresentationLayerIdentity(
                generation: displayedLayer.identity.generation,
                sceneID: displayedLayer.identity.sceneID,
                layerID: "scene-root"
            ),
            role: displayedLayer.role,
            opacity: displayedLayer.opacity,
            isBarrierComplete: vm.isScenePresentationBarrierComplete(for: displayedLayer),
            isSceneRoot: true
        )
        var reporter = SceneVisibleFrameReporter()
        if reporter.transactionCompleted(candidate: candidate),
            let identity = reporter.consumeDisplayTick(currentCandidate: candidate)
        {
            vm.incomingBecameVisible(identity)
        }
        if visibleLayer.role == .incoming,
            let completionDeadline = vm.fireScheduledScenePresentationWakeUpForTesting()
        {
            vm.scenePresentationTimestampProviderForTesting = { completionDeadline }
        }
    }

    private func failSceneRendererThroughRetryBudget(
        layer: PlaybackSessionEngine.SceneRenderLayer,
        viewModel vm: SlideShowViewModel
    ) {
        guard let scene = vm.scene(for: layer),
            let slot = scene.photoSlots.first
        else {
            return
        }
        for _ in 0...SceneLifecycleContract.retryLimit {
            let rendererIdentity = SceneRendererIdentity(
                generation: layer.identity.generation,
                attemptID: vm.scenePresentationRendererAttemptID(for: layer),
                sceneID: layer.identity.sceneID,
                slotID: slot.id,
                assetID: slot.asset.id
            )
            vm.rendererFailed(rendererIdentity)
        }
    }

    // Sleep-polling instead of a yield budget: 10k yields last ~0.3s and starve the detached planner.
    private func waitUntilForTesting(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        await waitUntil(pollInterval: .milliseconds(2), condition)
    }

    private func assertLatency(
        _ readback: PlaybackSmartFillSceneReadback?,
        actionTimestamp: TimeInterval,
        scenePublishTimestamp: TimeInterval,
        latencyMilliseconds: Double
    ) {
        #expect(readback?.actionTimestamp == actionTimestamp)
        #expect(readback?.scenePublishTimestamp == scenePublishTimestamp)
        #expect(
            abs((readback?.actionToSceneLatencyMilliseconds ?? -1) - latencyMilliseconds) < latencyToleranceMilliseconds
        )
        #expect(readback?.qaDebugSummary.contains("actionTimestamp=\(format(actionTimestamp))") == true)
        #expect(readback?.qaDebugSummary.contains("scenePublishTimestamp=\(format(scenePublishTimestamp))") == true)
        #expect(readback?.qaDebugSummary.contains("actionToSceneLatencyMs=\(format(latencyMilliseconds))") == true)
    }

    private func assertPublishTimingRecorded(
        _ readback: PlaybackSmartFillSceneReadback?,
        actionTimestamp: TimeInterval
    ) {
        #expect(readback?.actionTimestamp == actionTimestamp)
        #expect((readback?.scenePublishTimestamp ?? -1) >= actionTimestamp)
        #expect((readback?.actionToSceneLatencyMilliseconds ?? -1) >= 0)
        #expect(readback?.qaDebugSummary.contains("actionTimestamp=\(format(actionTimestamp))") == true)
        #expect(readback?.qaDebugSummary.contains("scenePublishTimestamp=") == true)
        #expect(readback?.qaDebugSummary.contains("actionToSceneLatencyMs=") == true)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func parseSummaryFields(_ summary: String) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: summary.split(separator: ";").compactMap { part -> (String, String)? in
                guard let equalIndex = part.firstIndex(of: "=") else { return nil }
                return (
                    String(part[..<equalIndex]),
                    String(part[part.index(after: equalIndex)...])
                )
            }
        )
    }

    private func parsePhaseMap(_ raw: String) -> [String: Double] {
        raw.split(separator: ",").reduce(into: [String: Double]()) { result, part in
            let entry = String(part)
            guard let separatorIndex = entry.firstIndex(of: ":"),
                let value = Double(entry[entry.index(after: separatorIndex)...])
            else {
                return
            }
            result[String(entry[..<separatorIndex])] = value
        }
    }

    private struct PlaybackHistoryMemoryEstimate {
        let entryCount: Int
        let rawBytes: Int
        let conservativeBytes: Int
    }

    private func estimatePlaybackHistoryLedgerMemory(_ ledger: PlaybackHistoryLedger) -> PlaybackHistoryMemoryEstimate {
        let rawBytes =
            MemoryLayout<PlaybackHistoryLedger>.stride
            + arrayStorageBytes(
                count: ledger.entries.count, elementStride: MemoryLayout<PlaybackHistoryLedgerEntry>.stride)
            + ledger.entries.reduce(0) { partial, entry in
                partial + estimateSceneStorage(entry.scene)
            }
        // The memory estimate leaves headroom for Array/String capacity and CoW so it is not too tight.
        let conservativeBytes = rawBytes * conservativeMemoryHeadroomFactor
        return PlaybackHistoryMemoryEstimate(
            entryCount: ledger.entries.count,
            rawBytes: rawBytes,
            conservativeBytes: conservativeBytes
        )
    }

    private func estimateSceneStorage(_ scene: PlaybackScene) -> Int {
        stringStorageBytes(scene.id)
            + arrayStorageBytes(count: scene.photoSlots.count, elementStride: MemoryLayout<PhotoSlot>.stride)
            + scene.photoSlots.reduce(0) { partial, slot in
                partial
                    + stringStorageBytes(slot.id)
                    + estimateAssetStorage(slot.asset)
                    + estimatePlanningStorage(slot.planning)
            }
            + estimateProtectionStorage(scene.protectionSnapshot)
            + estimateReadbackStorage(scene.smartFillReadback)
    }

    private func estimateAssetStorage(_ asset: Asset) -> Int {
        stringStorageBytes(asset.id)
            + stringStorageBytes(asset.type)
            + optionalStringStorageBytes(asset.livePhotoVideoID)
            + optionalStringStorageBytes(asset.thumbhash)
            + estimateExifStorage(asset.exifInfo)
            + arrayStorageBytes(count: asset.tags?.count ?? 0, elementStride: MemoryLayout<String>.stride)
            + (asset.tags ?? []).reduce(0) { $0 + stringStorageBytes($1) }
            + arrayStorageBytes(count: asset.people?.count ?? 0, elementStride: MemoryLayout<People>.stride)
            + (asset.people ?? []).reduce(0) { $0 + estimatePeopleStorage($1) }
            + arrayStorageBytes(
                count: asset.unassignedFaces?.count ?? 0, elementStride: MemoryLayout<UnassignedFace>.stride)
            + (asset.unassignedFaces ?? []).reduce(0) { $0 + stringStorageBytes($1.id) }
    }

    private func estimateExifStorage(_ exif: ExifInfo?) -> Int {
        guard let exif else { return 0 }
        return MemoryLayout<ExifInfo>.stride
            + optionalStringStorageBytes(exif.make)
            + optionalStringStorageBytes(exif.model)
            + optionalStringStorageBytes(exif.dateTimeOriginal)
            + optionalStringStorageBytes(exif.timeZone)
            + optionalStringStorageBytes(exif.lensModel)
            + optionalStringStorageBytes(exif.exposureTime)
            + optionalStringStorageBytes(exif.city)
            + optionalStringStorageBytes(exif.state)
            + optionalStringStorageBytes(exif.country)
            + optionalStringStorageBytes(exif.orientation)
    }

    private func estimatePeopleStorage(_ person: People) -> Int {
        stringStorageBytes(person.id)
            + stringStorageBytes(person.name)
            + arrayStorageBytes(count: person.faces?.count ?? 0, elementStride: MemoryLayout<FaceBox>.stride)
            + (person.faces ?? []).reduce(0) { partial, face in
                partial
                    + optionalStringStorageBytes(face.id)
                    + optionalStringStorageBytes(face.sourceType)
            }
    }

    private func estimatePlanningStorage(_ planning: PlaybackPlanningSnapshot) -> Int {
        stringStorageBytes(planning.version)
            + stringStorageBytes(planning.sourceImage.orientation)
            + arrayStorageBytes(
                count: planning.fallbackReasons.count,
                elementStride: MemoryLayout<PlaybackPlanningFallbackReason>.stride)
            + stringStorageBytes(planning.qaDebugSummary)
    }

    private func estimateProtectionStorage(_ snapshot: PlaybackProtectionSnapshot) -> Int {
        stringStorageBytes(snapshot.version)
            + stringStorageBytes(snapshot.qaDebugSummary)
            + arrayStorageBytes(
                count: snapshot.regions.count, elementStride: MemoryLayout<PlaybackProtectionRegion>.stride)
    }

    private func estimateReadbackStorage(_ readback: PlaybackSmartFillSceneReadback?) -> Int {
        guard let readback else { return 0 }
        return stringStorageBytes(readback.version)
            + stringStorageBytes(readback.layoutPolicyId)
            + stringStorageBytes(readback.surfaceKey)
            + stringStorageBytes(readback.ratioPreset)
            + stringStorageBytes(readback.rotationStartRatioPreset)
            + stringStorageBytes(readback.acceptedRatioPreset)
            + stringStorageBytes(readback.rotationKeyHashPrefix)
            + stringStorageBytes(readback.qaDebugSummary)
            + arrayStorageBytes(
                count: readback.slotRoles.count, elementStride: MemoryLayout<PlaybackSmartFillSlotRole>.stride)
            + arrayStorageBytes(
                count: readback.rejectedLayoutReasonTopList.count,
                elementStride: MemoryLayout<PlaybackSmartFillPlannerRejectReason>.stride)
            + arrayStorageBytes(count: readback.reasonCodes.count, elementStride: MemoryLayout<String>.stride)
            + readback.reasonCodes.reduce(0) { $0 + stringStorageBytes($1) }
    }

    private func stringStorageBytes(_ value: String) -> Int {
        estimatedStringStorageOverheadBytes + value.utf8.count
    }

    private func optionalStringStorageBytes(_ value: String?) -> Int {
        value.map(stringStorageBytes) ?? 0
    }

    private func arrayStorageBytes(count: Int, elementStride: Int) -> Int {
        guard count > 0 else { return 0 }
        return estimatedArrayStorageOverheadBytes + (count * elementStride)
    }

    private func formatMiB(_ bytes: Int) -> String {
        String(format: "%.3f", Double(bytes) / bytesPerMiB)
    }

    private func makeEstimatedHistoryScene(index: Int, slotCount: Int) -> PlaybackScene {
        let slots = (0..<slotCount).map { slotIndex in
            let asset = makeRichAsset(id: "asset-\(index)-\(slotIndex)", width: 6000, height: 4000)
            return PhotoSlot(
                id: "slot-\(index)-\(slotIndex)-\(asset.id)",
                asset: asset,
                planning: makeEstimatedPlanning(index: index, slotIndex: slotIndex, slotCount: slotCount)
            )
        }
        return PlaybackScene(
            id: "scene-estimate-\(index)",
            photoSlots: slots,
            smartFillReadback: makeEstimatedReadback(index: index, slotCount: slotCount)
        )
    }

    private func makeEstimatedPlanning(
        index: Int,
        slotIndex: Int,
        slotCount: Int
    ) -> PlaybackPlanningSnapshot {
        PlaybackPlanningSnapshot(
            version: "smart-fill-planner-v2",
            sourceImage: PlaybackPlanningSourceImageSummary(
                assetPixelSize: PlaybackPlanningPixelSize(width: 6000, height: 4000),
                exifPixelSize: PlaybackPlanningPixelSize(width: 6000, height: 4000),
                orientation: "available"
            ),
            displayFrame: PlaybackPlanningRect(
                x: slotCount == 1 ? 0 : Double(slotIndex) * 0.5,
                y: 0,
                width: slotCount == 1 ? 1 : 0.5,
                height: 1
            ),
            cropRect: PlaybackPlanningRect(x: 0, y: 0.04, width: 1, height: 0.92),
            qualityDecision: .smartFillAccepted,
            faceProtection: .accepted,
            fallbackReasons: [],
            qaDebugSummary:
                "version=smart-fill-planner-v2;sceneType=\(slotCount == 1 ? "single" : "double");surfaceKey=appleTV-landscape-tv-regular-safeTV;slotRef=asset_\(index)_\(slotIndex);display=x0.000y0.000w0.500h1.000;crop=x0.000y0.040w1.000h0.920;cropRetention=0.920;protectionContained=true;candidateWindowUsed=24;evaluationCount=2;fallback=none"
        )
    }

    private func makeEstimatedReadback(index: Int, slotCount: Int) -> PlaybackSmartFillSceneReadback {
        PlaybackSmartFillSceneReadback(
            version: "smart-fill-planner-v2",
            sceneType: slotCount == 1 ? .single : .double,
            layoutPolicyId: "appletv-landscape-pr49-v1",
            surfaceKey: "appleTV-landscape-tv-regular-safeTV|size:55x32|aspect:35",
            layoutVariant: slotCount == 1 ? .single : .horizontalEqual,
            ratioPreset: slotCount == 1 ? "full" : "50/50",
            slotRoles: slotCount == 1 ? [.primary] : [.primary, .secondary],
            fallbackReason: nil,
            candidateWindowUsed: 24,
            evaluationCount: 2,
            rotationStartLayoutVariant: slotCount == 1 ? .single : .rightPrimaryLeftSecondary,
            rotationStartRatioPreset: slotCount == 1 ? "full" : "55/45",
            acceptedLayoutVariant: slotCount == 1 ? .single : .horizontalEqual,
            acceptedRatioPreset: slotCount == 1 ? "full" : "50/50",
            rotationKeyHashPrefix: "5b8a52baf191",
            rejectedLayoutReasonTopList: [.cropRetentionTooLow, .verticalDoubleDisallowedOnSurface],
            reasonCodes: ["accepted", "crop-retention-too-low", "vertical-double-disallowed-on-surface"],
            qaDebugSummary:
                "version=smart-fill-planner-v2;sceneType=\(slotCount == 1 ? "single" : "double");surfaceKey=appleTV-landscape-tv-regular-safeTV;layoutVariant=\(slotCount == 1 ? PlaybackSmartFillLayoutVariant.single.rawValue : PlaybackSmartFillLayoutVariant.horizontalEqual.rawValue);ratioPreset=\(slotCount == 1 ? "full" : "50/50");slotRefs=asset_\(index)_0\(slotCount == 2 ? ",asset_\(index)_1" : "");ledgerSceneAssets=asset-\(index)-0\(slotCount == 2 ? ",asset-\(index)-1" : "");candidateWindowUsed=24;evaluationCount=2;fallback=none;rejects=vertical-double-disallowed-on-surface,crop-retention-too-low"
        )
    }

    private func makeRichAsset(id: String, width: Int, height: Int) -> Asset {
        Asset(
            id: id,
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: ExifInfo(
                make: "Canon",
                model: "EOS 5D Mark III",
                dateTimeOriginal: "2025-04-14T10:20:30",
                timeZone: "Asia/Shanghai",
                lensModel: "EF35mm f/1.4L II USM",
                fNumber: 4.0,
                focalLength: 35,
                iso: 320,
                exposureTime: "1/125",
                latitude: 31.2304,
                longitude: 121.4737,
                city: "Shanghai",
                state: "Shanghai",
                country: "China",
                rating: 5,
                exifImageWidth: width,
                exifImageHeight: height,
                orientation: "1"
            ),
            people: [
                People(
                    id: "person-\(id)-0",
                    name: "Person \(id)",
                    isHidden: false,
                    isFavorite: false,
                    faces: [
                        FaceBox(
                            id: "face-\(id)-0",
                            boundingBoxX1: 120,
                            boundingBoxX2: 360,
                            boundingBoxY1: 240,
                            boundingBoxY2: 520,
                            imageWidth: width,
                            imageHeight: height,
                            sourceType: "machine-learning"
                        )
                    ]
                )
            ],
            tags: ["travel", "family", "featured"],
            livePhotoVideoID: nil,
            width: width,
            height: height,
            thumbhash: "1QcSHQRnh493V4dIh4eXh1h4kJUI",
            unassignedFaces: [UnassignedFace(id: "unassigned-\(id)-0")]
        )
    }

    private func markReady(_ assets: [Asset], in manager: AssetsDownloadManager) {
        for asset in assets {
            manager.assetStates[asset.id] = .readyToPlay
            manager.assetPreviewStates[asset.id] = .readyToPlay
        }
    }

    private func markReady(assetId: String, size: ThumbnailSize, in manager: AssetsDownloadManager) {
        switch size {
        case .fullsize:
            manager.assetStates[assetId] = .readyToPlay
        case .preview:
            manager.assetPreviewStates[assetId] = .readyToPlay
        case .thumbnail:
            manager.assetThumbnailStates[assetId] = .readyToPlay
        }
    }

    private func makeAsset(id: String, width: Int, height: Int) -> Asset {
        Asset(
            id: id,
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: nil,
            people: nil,
            tags: nil,
            livePhotoVideoID: nil,
            width: width,
            height: height
        )
    }

    private func resetDownloadManagerState(_ manager: AssetsDownloadManager) {
        manager.assetStates = [:]
        manager.assetPreviewStates = [:]
        manager.assetThumbnailStates = [:]
        manager.assetURLs = [:]
        manager.assetPreviewURLs = [:]
        manager.assetThumbnailURLs = [:]
    }
}
