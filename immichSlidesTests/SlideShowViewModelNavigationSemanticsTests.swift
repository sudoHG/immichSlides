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
    let rawMemoryBudgetBytes: Int = 8 * 1024 * 1024
    let conservativeMemoryBudgetBytes: Int = 16 * 1024 * 1024
    let iPadLandscapePlanningPixelSize = PlaybackPlanningPixelSize(width: 2732, height: 2048)
    let iPhonePortraitPlanningPixelSize = PlaybackPlanningPixelSize(width: 1179, height: 2556)
    let latencyToleranceMilliseconds: Double = 0.001
    let conservativeMemoryHeadroomFactor: Int = 2
    // Estimated storage headers exclude payload bytes and reserved capacity.
    let estimatedStringStorageOverheadBytes: Int = 32
    let estimatedArrayStorageOverheadBytes: Int = 32
    let bytesPerMiB: Double = 1_048_576.0

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
}
