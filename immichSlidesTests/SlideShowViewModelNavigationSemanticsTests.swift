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

    @Test(arguments: [8.0])
    func
        `a failed initial renderer is skipped without entering history and navigation resumes from the recovered scene`(
            interval: TimeInterval
        )
        async throws
    {
        let store = PlaybackSettingsStore()
        store.save(PlaybackSettings(autoPlayEnabled: true, intervalSeconds: interval, displayMode: .singlePhoto))
        defer { store.clear() }
        let vm = SlideShowViewModel(settingsStore: store, observeSettingsChanges: false)
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.indexChangePhotoLoadHookForTesting = { assetID, size in
            markReady(assetId: assetID, size: size, in: vm.downloadManager)
        }
        let assets = (0..<5).map { makeAsset(id: "recovery-\($0)", width: 6000, height: 4000) }
        markReady(assets, in: vm.downloadManager)
        vm.loadAssetsHookForTesting = { _ in assets }
        await vm.firstPreload()
        let failedLayer = try #require(vm.sceneRenderSnapshot.layers.last { $0.role == .incoming })
        #expect(vm.safeCurrentScene?.primaryAssetId == "recovery-0")
        failSceneRendererThroughRetryBudget(layer: failedLayer, viewModel: vm)
        try #require(await waitUntilForTesting { vm.safeCurrentScene?.primaryAssetId == "recovery-1" })
        completeCurrentScenePresentation(vm)
        #expect(!vm.isLoading)
        #expect(vm.sceneRenderSnapshot.phase == .stablePhoto)
        #expect(vm.sceneRenderSnapshot.layers.count == 1)
        #expect(vm.sceneRenderSnapshot.layers.first?.isPresentationReady == true)
        #expect(vm.sceneRenderSnapshot.layers.first?.opacity == 1)
        #expect(vm.visibleOverlayScene?.primaryAssetId == "recovery-1")
        #expect(vm.canRequestPreviousScene == false)
        try expectHistory(vm, assetIds: ["recovery-1"], cursor: 0)

        vm.toggleAutoPlayFromUserInteraction()
        for (isNext, expectedAsset, cursor) in [
            (true, "recovery-2", 1), (false, "recovery-1", 0), (true, "recovery-2", 1)
        ] {
            if isNext { vm.requestNextScene() } else { vm.requestPreviousScene() }
            completeCurrentScenePresentation(vm)
            #expect(!vm.isAutoPlay)
            #expect(vm.visibleOverlayScene?.primaryAssetId == expectedAsset)
            try expectHistory(vm, assetIds: ["recovery-1", "recovery-2"], cursor: cursor)
        }
        vm.toggleAutoPlayFromUserInteraction()
        let deadline = try #require(vm.scenePresentationWakeUpScheduler.scheduledDeadlineForTesting)
        #expect(vm.visibleOverlayScene?.primaryAssetId == "recovery-2")
        vm.scenePresentationTimestampProviderForTesting = { deadline }
        #expect(vm.fireScheduledScenePresentationWakeUpForTesting() == deadline)
        completeCurrentScenePresentation(vm)
        #expect(vm.visibleOverlayScene?.primaryAssetId == "recovery-3")
        try expectHistory(vm, assetIds: ["recovery-1", "recovery-2", "recovery-3"], cursor: 2)
    }

    @Test(arguments: [false, true])
    func `a late download and renderer callback cannot replace the paused layers overlay or history`(
        isInitialLoad: Bool
    ) async throws {
        let store = PlaybackSettingsStore()
        defer { store.clear() }
        let vm: SlideShowViewModel
        if isInitialLoad {
            store.save(PlaybackSettings(autoPlayEnabled: false))
            vm = SlideShowViewModel(settingsStore: store, observeSettingsChanges: false)
            resetDownloadManagerState(vm.downloadManager)
            vm.scenePresentationTimestampProviderForTesting = { 0 }
            vm.updateSmartFillSurfaceForTesting(
                PlaybackSmartFillSurface(
                    pixelSize: iPadLandscapePlanningPixelSize, profile: .iPad, orientation: .landscape))
            let assets = (0..<6).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
            markReady(Array(assets.dropFirst()), in: vm.downloadManager)
            vm.loadAssetsHookForTesting = { _ in assets }
            vm.backgroundPreloadHookForTesting = { _, _, _ in }
            vm.transitionWindowPreloadHookForTesting = { _, _, _ in }
        } else {
            vm = makeSmartFillViewModel()
            vm.toggleAutoPlayFromUserInteraction()
        }
        var finishOldLoad: CheckedContinuation<Void, Never>?
        var didStartOldLoad = false
        var didFinishOldLoad = false
        var didReleaseOldLoad = false
        let oldAssetID = isInitialLoad ? "asset-0" : "asset-1"
        let loadPhoto: @MainActor (String, ThumbnailSize) async -> Void = { assetID, size in
            if assetID == oldAssetID, size == .fullsize, !didStartOldLoad, !didReleaseOldLoad {
                didStartOldLoad = true
                await withCheckedContinuation { finishOldLoad = $0 }
                didFinishOldLoad = true
            }
            markReady(assetId: assetID, size: size, in: vm.downloadManager)
        }
        vm.indexChangePhotoLoadHookForTesting = loadPhoto
        var firstPreloadTask: Task<Void, Never>?
        defer {
            didReleaseOldLoad = true
            finishOldLoad?.resume()
            firstPreloadTask?.cancel()
        }

        if isInitialLoad {
            vm.initialPhotoLoadHookForTesting = { await loadPhoto($0, .fullsize) }
            firstPreloadTask = Task { await vm.firstPreload() }
        } else {
            vm.requestNextScene()
        }
        try #require(await waitUntilForTesting { finishOldLoad != nil })
        let oldLayer = try #require(vm.sceneRenderSnapshot.layers.last { $0.role == .incoming })
        let oldDownload = try #require(vm.currentSceneDownloadCompletion)
        #expect(oldDownload.identity == oldLayer.identity)
        let oldScene = try #require(vm.scene(for: oldLayer))
        let oldSlot = try #require(oldScene.photoSlots.first)
        let oldRenderer = SceneRendererIdentity(
            generation: oldLayer.identity.generation,
            attemptID: vm.scenePresentationRendererAttemptID(for: oldLayer),
            sceneID: oldLayer.identity.sceneID,
            slotID: oldSlot.id,
            assetID: oldSlot.asset.id
        )
        if isInitialLoad {
            vm.requestNextScene()
            completeCurrentScenePresentation(vm)
        }
        let initialScene = try #require(vm.visibleOverlayScene)
        let seenAssetIDs = [isInitialLoad ? "asset-1" : "asset-0"]
        #expect(initialScene.primaryAssetId == seenAssetIDs[0])
        vm.requestNextScene()
        let pending = vm.sceneRenderSnapshot
        let newLayer = try #require(pending.layers.last { $0.role == .incoming })
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-2")
        #expect(!newLayer.isPresentationReady)
        #expect(pending.phase == .paused)
        try expectHistory(vm, assetIds: seenAssetIDs, cursor: 0)

        vm.rendererDecoded(oldRenderer)
        #expect(vm.sceneRenderSnapshot == pending)
        #expect(vm.visibleOverlayScene?.id == initialScene.id)
        try expectHistory(vm, assetIds: seenAssetIDs, cursor: 0)
        didReleaseOldLoad = true
        let continuation = finishOldLoad
        finishOldLoad = nil
        continuation?.resume()
        try #require(await waitUntilForTesting { didFinishOldLoad })
        await oldDownload.waitForDownloads()
        await firstPreloadTask?.value
        #expect(vm.sceneRenderSnapshot == pending)
        #expect(vm.visibleOverlayScene?.id == initialScene.id)

        completeCurrentScenePresentation(vm)
        let settled = vm.sceneRenderSnapshot
        let currentScene = try #require(vm.visibleOverlayScene)
        #expect(settled.phase == .paused)
        #expect(settled.layers.map(\.identity) == [newLayer.identity])
        #expect(currentScene.primaryAssetId == "asset-2")
        try expectHistory(vm, assetIds: seenAssetIDs + ["asset-2"], cursor: 1)
        vm.scenePresentationTimestampProviderForTesting = { 3_600 }
        vm.rendererDecoded(oldRenderer)
        #expect(vm.sceneRenderSnapshot == settled)
        #expect(vm.visibleOverlayScene?.id == currentScene.id)
        #expect(vm.safeCurrentScene?.id == currentScene.id)
        try expectHistory(vm, assetIds: seenAssetIDs + ["asset-2"], cursor: 1)
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
