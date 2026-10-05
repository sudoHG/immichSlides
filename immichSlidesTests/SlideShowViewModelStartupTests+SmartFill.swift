import Combine
import Foundation
import Testing
@testable import immichSlides

extension SlideShowViewModelStartupTests {
    @Test
    func `the initial SmartFill scene uses the configured surface and prefers single to advance the candidate window`()
    {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
                profile: .iPad,
                orientation: .landscape
            )
        )
        let initialAssets = (0..<6).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
        markReady(initialAssets, in: vm.downloadManager)

        vm.replacePlaybackAssetsForTesting(initialAssets)

        #expect(vm.safeCurrentScene?.smartFillReadback?.sceneType == .single)
        #expect(vm.safeCurrentScene?.smartFillReadback?.layoutVariant == .single)
        #expect(vm.safeCurrentScene?.smartFillReadback?.fallbackCategory == .some(.none))
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0"])

        vm.requestNextScene()

        #expect(vm.scene(at: vm.targetIndex)?.smartFillReadback?.sceneType == .single)
        #expect(vm.scene(at: vm.targetIndex)?.smartFillReadback?.fallbackCategory == .some(.none))
        #expect(vm.scene(at: vm.targetIndex)?.photoSlots.map(\.asset.id) == ["asset-1"])
    }

    @Test
    func
        `SmartFill lookahead selecting a distant secondary keeps intervening photos and skips an already shown secondary`()
        async
    {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.isAutoPlay = true
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
                profile: .iPad,
                orientation: .landscape
            )
        )
        let assets =
            [
                makeAsset(id: "asset-0", width: 1800, height: 2000)
            ]
            + (1...12).map { index in
                makeAsset(id: "asset-\(index)", width: 200, height: 6000)
            } + [
                makeAsset(id: "asset-13", width: 1800, height: 2000),
                makeAsset(id: "asset-14", width: 1800, height: 2000),
                makeAsset(id: "asset-15", width: 1800, height: 2000)
            ]
        markReady(assets, in: vm.downloadManager)

        vm.replacePlaybackAssetsForTesting(assets)

        #expect(vm.safeCurrentScene?.smartFillReadback?.sceneType == .double)
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0", "asset-13"])

        for expectedIndex in 1...12 {
            vm.requestNextScene()
            let token = vm.targetTransitionToken
            let targetIndex = vm.targetIndex

            #expect(vm.scene(at: targetIndex)?.primaryAssetId == "asset-\(expectedIndex)")
            #expect(vm.scene(at: targetIndex)?.photoSlots.map(\.asset.id).contains("asset-13") == false)

            await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
            #expect(vm.safeCurrentScene?.primaryAssetId == "asset-\(expectedIndex)")
        }

        vm.requestNextScene()
        let token = vm.targetTransitionToken
        let targetIndex = vm.targetIndex

        #expect(vm.scene(at: targetIndex)?.primaryAssetId == "asset-14")
        #expect(vm.scene(at: targetIndex)?.photoSlots.map(\.asset.id).contains("asset-13") == false)

        await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-14")
    }

    @Test
    func
        `filtered soloOnly SmartFill waits at the retained tail during an in-flight load more instead of wrapping the old pool`()
        async throws
    {
        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-solo", matchMode: .soloOnly)]
        )
        let vm = SlideShowViewModel(source: .filtered(selection))
        resetDownloadManagerState(vm.downloadManager)
        vm.isAutoPlay = true
        vm.maxAssetCount = 200
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
                profile: .iPad,
                orientation: .landscape
            )
        )

        let initialAssets = (0..<36).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
        markReady(initialAssets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(initialAssets)

        for expectedIndex in 1...19 {
            vm.requestNextScene()
            let token = vm.targetTransitionToken
            let targetIndex = vm.targetIndex
            #expect(vm.scene(at: targetIndex)?.primaryAssetId == "asset-\(expectedIndex)")
            await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
            #expect(vm.safeCurrentScene?.primaryAssetId == "asset-\(expectedIndex)")
        }

        #expect(vm.currentIndex == 19)
        #expect(vm.playbackScenes.count == 20)
        #if DEBUG
        vm.markCurrentSmartFillPoolConsumedForTesting(candidateCursorIndex: 0)
        #endif

        var loadMoreContinuation: CheckedContinuation<[Asset], any Error>?
        var loadMoreCallCount = 0
        vm.loadMoreAssetsHookForTesting = { _ in
            loadMoreCallCount += 1
            return try await withCheckedThrowingContinuation { continuation in
                loadMoreContinuation = continuation
            }
        }
        let loadMoreTask = Task {
            await vm.loadMoreAssets()
        }
        let didSuspend = await waitUntil { loadMoreContinuation != nil }
        try #require(didSuspend, "Timed out waiting for loadMoreContinuation to be captured")

        #expect(loadMoreCallCount == 1)
        #expect(vm.isLoadingMore)
        #expect(vm.assets.count == 36)

        let currentIndexBeforeBlockedTick = vm.currentIndex
        let targetIndexBeforeBlockedTick = vm.targetIndex
        let sceneCountBeforeBlockedTick = vm.playbackScenes.count

        vm.requestNextScene()

        #expect(vm.currentIndex == currentIndexBeforeBlockedTick)
        #expect(vm.targetIndex == targetIndexBeforeBlockedTick)
        #expect(vm.playbackScenes.count == sceneCountBeforeBlockedTick)
        #expect(vm.scene(at: vm.targetIndex)?.primaryAssetId != "asset-0")
        #if DEBUG
        #expect(vm.pendingSmartFillCursorResumeAfterLoadMoreAssetCountForTesting == 36)
        #endif

        let appendedAssets = (36..<60).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
        markReady(appendedAssets, in: vm.downloadManager)
        loadMoreContinuation?.resume(returning: appendedAssets)
        await loadMoreTask.value
        let didFinishLoadingMore = await waitUntil { !vm.isLoadingMore }
        #expect(didFinishLoadingMore, "load more did not finish before the deadline")
        #expect(vm.isLoadingMore == false)
        #expect(vm.assets.count == 60)
        #if DEBUG
        #expect(vm.smartFillCandidateCursorIndexForTesting == 36)
        #expect(vm.pendingSmartFillCursorResumeAfterLoadMoreAssetCountForTesting == nil)
        #endif

        vm.requestNextScene()
        let token = vm.targetTransitionToken
        let targetIndex = vm.targetIndex
        #expect(vm.scene(at: targetIndex)?.primaryAssetId == "asset-36")
        await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-36")

        // Resuming against the trimmed pool would lose the first new candidate when oldCount exceeds capacity.
        vm.maxAssetCount = 40
        vm.markCurrentSmartFillPoolConsumedForTesting(candidateCursorIndex: 0)
        loadMoreContinuation = nil
        let trimmingLoadMoreTask = Task { await vm.loadMoreAssets() }
        let didSuspendTrimmingRefill = await waitUntil { loadMoreContinuation != nil }
        try #require(didSuspendTrimmingRefill)
        vm.requestNextScene()
        #expect(vm.pendingSmartFillCursorResumeAfterLoadMoreAssetCountForTesting == 60)
        let nextAssets = (60..<65).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
        markReady(nextAssets, in: vm.downloadManager)
        var publishedPoolCounts: [Int] = []
        var cursorAtPoolPublication: [Int] = []
        let observation = vm.$assets.dropFirst().sink { pool in
            publishedPoolCounts.append(pool.count)
            cursorAtPoolPublication.append(vm.smartFillCandidateCursorIndexForTesting)
        }
        loadMoreContinuation?.resume(returning: nextAssets)
        await trimmingLoadMoreTask.value
        observation.cancel()

        #expect(publishedPoolCounts == [65, 40])
        #expect(cursorAtPoolPublication == [0, 60])
        #expect(vm.assets.map(\.id) == (25..<65).map { "asset-\($0)" })
        #expect(vm.smartFillCandidateCursorIndexForTesting == 35)
        #expect(vm.pendingSmartFillCursorResumeAfterLoadMoreAssetCountForTesting == nil)
        #expect(vm.smartFillDisplayedAssetIds == Set((25..<60).map { "asset-\($0)" }))
        #expect(Set(vm.downloadManager.assetStates.keys) == Set((25..<65).map { "asset-\($0)" }))
        vm.requestNextScene()
        #expect(vm.scene(at: vm.targetIndex)?.primaryAssetId == "asset-60")
    }

    @Test
    func
        `filtered soloOnly SmartFill holds at the retained tail instead of wrapping old assets when the pool is consumed and load more added nothing`()
        async
    {
        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-solo", matchMode: .soloOnly)]
        )
        let vm = SlideShowViewModel(source: .filtered(selection))
        resetDownloadManagerState(vm.downloadManager)
        vm.isAutoPlay = true
        vm.maxAssetCount = 200
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.loadMoreAssetsHookForTesting = { _ in [] }
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
                profile: .iPad,
                orientation: .landscape
            )
        )

        let initialAssets = (0..<36).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
        markReady(initialAssets, in: vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.replacePlaybackAssetsForTesting(initialAssets)
        completeCurrentScenePresentation(vm)

        var displayedPrimaryIds = Set(vm.safeCurrentScene?.primaryAssetId.map { [$0] } ?? [])
        var stepCount = 0
        while vm.smartFillCandidateCursorIndexForTesting != 0 || stepCount == 0 {
            let previousToken = vm.targetTransitionToken
            vm.requestNextScene()
            let token = vm.targetTransitionToken
            guard token != previousToken,
                let primaryAssetId = vm.safeCurrentScene?.primaryAssetId
            else {
                break
            }
            #expect(displayedPrimaryIds.insert(primaryAssetId).inserted)
            completeCurrentScenePresentation(vm)
            stepCount += 1
            if stepCount > initialAssets.count {
                Issue.record("Test did not reach the SmartFill cursor wrap-around within the current pool size")
                break
            }
        }

        #expect(vm.smartFillCandidateCursorIndexForTesting == 0)
        #expect(displayedPrimaryIds.count > 1)

        let currentIndexBeforeWrapRequest = vm.currentIndex
        let targetIndexBeforeWrapRequest = vm.targetIndex
        let sceneCountBeforeWrapRequest = vm.playbackScenes.count

        vm.requestNextScene()
        vm.requestNextScene()

        #expect(vm.currentIndex == currentIndexBeforeWrapRequest)
        #expect(vm.targetIndex == targetIndexBeforeWrapRequest)
        #expect(vm.playbackScenes.count == sceneCountBeforeWrapRequest)
    }

    @Test
    func `filtered soloOnly SmartFill clears the hold marker after load more saturates and allows a retry`() async {
        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-solo", matchMode: .soloOnly)]
        )
        let vm = SlideShowViewModel(source: .filtered(selection))
        resetDownloadManagerState(vm.downloadManager)
        vm.isAutoPlay = true
        vm.maxAssetCount = 200
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        var loadMoreCallCount = 0
        vm.loadMoreAssetsHookForTesting = { _ in
            loadMoreCallCount += 1
            return []
        }
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
                profile: .iPad,
                orientation: .landscape
            )
        )

        let initialAssets = (0..<36).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
        markReady(initialAssets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(initialAssets)
        #if DEBUG
        vm.markCurrentSmartFillPoolConsumedForTesting(candidateCursorIndex: 0)
        #endif

        let sceneCountBeforeHold = vm.playbackScenes.count
        vm.requestNextScene()
        await waitForLoadMoreAttempt(1, callCount: { loadMoreCallCount }, in: vm)

        #if DEBUG
        #expect(vm.pendingSmartFillCursorResumeAfterLoadMoreAssetCountForTesting == nil)
        #endif
        #expect(vm.isLoadingMore == false)
        #expect(vm.playbackScenes.count == sceneCountBeforeHold)

        vm.requestNextScene()
        await waitForLoadMoreAttempt(2, callCount: { loadMoreCallCount }, in: vm)

        #if DEBUG
        #expect(vm.pendingSmartFillCursorResumeAfterLoadMoreAssetCountForTesting == nil)
        #endif
        #expect(loadMoreCallCount == 2)
        #expect(vm.isLoadingMore == false)
        #expect(vm.playbackScenes.count == sceneCountBeforeHold)
    }

    @Test
    func `filtered soloOnly SmartFill clears the hold marker after load more fails and allows a retry`() async {
        struct LoadMoreTestError: Error {}
        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-solo", matchMode: .soloOnly)]
        )
        let vm = SlideShowViewModel(source: .filtered(selection))
        resetDownloadManagerState(vm.downloadManager)
        vm.isAutoPlay = true
        vm.maxAssetCount = 200
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        var loadMoreCallCount = 0
        vm.loadMoreAssetsHookForTesting = { _ in
            loadMoreCallCount += 1
            throw LoadMoreTestError()
        }
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
                profile: .iPad,
                orientation: .landscape
            )
        )

        let initialAssets = (0..<36).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
        markReady(initialAssets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(initialAssets)
        #if DEBUG
        vm.markCurrentSmartFillPoolConsumedForTesting(candidateCursorIndex: 0)
        #endif

        let sceneCountBeforeHold = vm.playbackScenes.count
        vm.requestNextScene()
        await waitForLoadMoreAttempt(1, callCount: { loadMoreCallCount }, in: vm)

        #if DEBUG
        #expect(vm.pendingSmartFillCursorResumeAfterLoadMoreAssetCountForTesting == nil)
        #endif
        #expect(vm.isLoadingMore == false)
        #expect(vm.playbackScenes.count == sceneCountBeforeHold)

        vm.requestNextScene()
        await waitForLoadMoreAttempt(2, callCount: { loadMoreCallCount }, in: vm)

        #if DEBUG
        #expect(vm.pendingSmartFillCursorResumeAfterLoadMoreAssetCountForTesting == nil)
        #endif
        #expect(loadMoreCallCount == 2)
        #expect(vm.isLoadingMore == false)
        #expect(vm.playbackScenes.count == sceneCountBeforeHold)
    }

    @Test
    func `SmartFill does not jump to a distant single photo when the current scene is not yet displayable`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 1179, height: 2556),
                profile: .iPhone,
                orientation: .portrait
            )
        )
        let assets =
            (0..<8).map { index in
                makeAsset(id: "asset-\(index)", width: 6000, height: 1800)
            } + [
                makeAsset(id: "asset-8", width: 1200, height: 2400)
            ]
        markReady(assets, in: vm.downloadManager)

        vm.replacePlaybackAssetsForTesting(assets)

        #expect(vm.safeCurrentScene?.smartFillReadback?.sceneType == .fallback)
        #expect(vm.safeCurrentScene?.smartFillReadback?.fallbackCategory == .some(.layoutReject))
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0"])
        #expect(
            vm.safeCurrentScene?.smartFillReadback?.qaDebugSummary.contains("currentAssetDisposition=fallback-current")
                == true)
        #expect(
            vm.safeCurrentScene?.smartFillReadback?.qaDebugSummary.contains("currentAssetVisibleQualityClass=fail")
                == true)

        vm.requestNextScene()
        let token = vm.targetTransitionToken
        let targetIndex = vm.targetIndex

        #expect(vm.scene(at: targetIndex)?.primaryAssetId == "asset-1")
        #expect(vm.scene(at: targetIndex)?.photoSlots.map(\.asset.id).contains("asset-8") == false)

        await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")
    }

    @Test
    func `SmartFill candidate window deduplicates a repeated asset id instead of crashing or duplicating a slot`() {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
                profile: .iPad,
                orientation: .landscape
            )
        )
        let assets = [
            makeAsset(id: "asset-0", width: 6000, height: 4000),
            makeAsset(id: "asset-0", width: 6000, height: 4000),
            makeAsset(id: "asset-1", width: 6000, height: 4000)
        ]
        markReady(assets, in: vm.downloadManager)

        vm.replacePlaybackAssetsForTesting(assets)

        #expect(vm.safeCurrentScene?.smartFillReadback?.fallbackCategory == .some(.none))
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0"])
        #expect(
            Set(vm.safeCurrentScene?.photoSlots.map(\.asset.id) ?? []).count == vm.safeCurrentScene?.photoSlots.count)
    }

    @Test
    func `a SmartFill transition load covers every slot in the pending scene`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
                profile: .iPad,
                orientation: .landscape
            )
        )
        let initialAssets = (0..<6).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
        markReady(initialAssets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(initialAssets)

        var requestedLoads: [String] = []
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            requestedLoads.append("\(assetId):\(size.rawValue)")
        }

        vm.requestNextScene()
        let token = vm.targetTransitionToken
        let targetIndex = vm.targetIndex

        await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
        let didRequestLoad = await waitUntil { !requestedLoads.isEmpty }
        #expect(didRequestLoad, "no photo load was requested before the deadline")

        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-1"])
        #expect(Set(requestedLoads) == Set(["asset-1:fullsize"]))
    }

    @Test
    func `the initial SmartFill scene does not advance before the full renderer barrier`() {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.isAutoPlay = true
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
                profile: .iPad,
                orientation: .landscape
            )
        )
        let initialAssets = (0..<6).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
        markReady(Array(initialAssets.prefix(3)), in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(initialAssets)

        #expect(vm.currentIndex == 0)
        #expect(vm.targetIndex == 0)
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0"])
        #expect(vm.sceneRenderSnapshot.phase == .loading)
        #expect(vm.sceneRenderSnapshot.layers.count == 1)
        #expect(vm.sceneRenderSnapshot.layers.first?.isPresentationReady == false)
    }

    @Test
    func `SmartFill manual next does not wait for the preview once fullsize is ready`() {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
                profile: .iPad,
                orientation: .landscape
            )
        )
        let initialAssets = (0..<6).map { makeAsset(id: "asset-\($0)", width: 6000, height: 4000) }
        for asset in initialAssets {
            vm.downloadManager.assetStates[asset.id] = .readyToPlay
            vm.downloadManager.assetPreviewStates[asset.id] = .notStarted
        }
        vm.replacePlaybackAssetsForTesting(initialAssets)
        vm.requestNextScene()

        #expect(vm.currentIndex == vm.targetIndex)
        #expect(vm.targetIndex == 1)
        #expect(vm.scene(at: vm.targetIndex)?.primaryAssetId != "asset-0")
    }

    @Test
    func `SmartFill initial preload only waits for the current visible scene, not the candidate window`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 1179, height: 2556),
                profile: .iPhone,
                orientation: .portrait
            )
        )
        let initialAssets = (0..<5).map { makeAsset(id: "asset-\($0)", width: 1800, height: 2000) }
        vm.loadAssetsHookForTesting = { _ in initialAssets }
        var initialSceneRequests: [String] = []
        vm.initialPhotoLoadHookForTesting = { assetId in
            initialSceneRequests.append(assetId)
            vm.downloadManager.assetStates[assetId] = .readyToPlay
        }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        var candidateWindowRequests: [String] = []
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            candidateWindowRequests.append("\(assetId):\(size.rawValue)")
            switch size {
            case .fullsize:
                vm.downloadManager.assetStates[assetId] = .readyToPlay
            case .preview:
                vm.downloadManager.assetPreviewStates[assetId] = .readyToPlay
            default:
                break
            }
        }

        await vm.prepareInitialAssets()
        let didRequestInitialScene = await waitUntil { initialSceneRequests.count >= 2 }
        #expect(didRequestInitialScene, "initial scene photo requests did not arrive before the deadline")

        #expect(vm.safeCurrentScene?.smartFillReadback?.sceneType == .double)
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0", "asset-1"])
        #expect(Set(initialSceneRequests) == Set(["asset-0", "asset-1"]))
        #expect(initialSceneRequests.filter { $0 == "asset-1" }.count == 1)
        #expect(candidateWindowRequests.isEmpty)
    }

    @Test
    func `the initial SmartFill visible commit defers candidate window prewarming until the transition`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 1179, height: 2556),
                profile: .iPhone,
                orientation: .portrait
            )
        )
        let initialAssets = (0..<5).map { makeAsset(id: "asset-\($0)", width: 1800, height: 2000) }
        vm.loadAssetsHookForTesting = { _ in initialAssets }
        vm.initialPhotoLoadHookForTesting = { assetId in
            vm.downloadManager.assetStates[assetId] = .readyToPlay
        }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        var candidateWindowRequests: [String] = []
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            candidateWindowRequests.append("\(assetId):\(size.rawValue)")
            switch size {
            case .fullsize:
                vm.downloadManager.assetStates[assetId] = .readyToPlay
            case .preview:
                vm.downloadManager.assetPreviewStates[assetId] = .readyToPlay
            default:
                break
            }
        }

        await vm.prepareInitialAssets()
        #expect(candidateWindowRequests.isEmpty)

        completeCurrentScenePresentation(vm)
        for _ in 0..<100 {
            await Task.yield()
        }
        #expect(candidateWindowRequests.isEmpty)

        vm.requestNextScene()
        let token = vm.targetTransitionToken
        let targetIndex = vm.targetIndex
        await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
        let didRequestCandidateWindow = await waitUntil { !candidateWindowRequests.isEmpty }
        #expect(didRequestCandidateWindow, "candidate window prewarming did not start before the deadline")

        #expect(!candidateWindowRequests.isEmpty)
        #expect(candidateWindowRequests.allSatisfy { !$0.hasPrefix("asset-0:") && !$0.hasPrefix("asset-1:") })
    }

    @Test
    func `a SmartFill transition restores the existing preload window without preempting the initial visible commit`()
        async
    {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 1179, height: 2556),
                profile: .iPhone,
                orientation: .portrait
            )
        )
        let initialAssets = (0..<6).map { makeAsset(id: "asset-\($0)", width: 1800, height: 2000) }
        vm.loadAssetsHookForTesting = { _ in initialAssets }
        vm.initialPhotoLoadHookForTesting = { assetId in
            vm.downloadManager.assetStates[assetId] = .readyToPlay
        }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            if size == .fullsize {
                vm.downloadManager.assetStates[assetId] = .readyToPlay
            } else if size == .preview {
                vm.downloadManager.assetPreviewStates[assetId] = .readyToPlay
            }
        }
        var transitionWindowPreloads: [(index: Int, count: Int)] = []
        vm.transitionWindowPreloadHookForTesting = { _, index, count in
            transitionWindowPreloads.append((index, count))
        }

        await vm.prepareInitialAssets()
        completeCurrentScenePresentation(vm)
        for _ in 0..<100 { await Task.yield() }
        #expect(transitionWindowPreloads.isEmpty)

        vm.requestNextScene()
        await vm.synchronizePlaybackReadbackForTesting(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)
        let didPreloadTransitionWindow = await waitUntil { !transitionWindowPreloads.isEmpty }
        #expect(didPreloadTransitionWindow, "transition window preload did not start before the deadline")

        #expect(transitionWindowPreloads.count == 1)
        #expect(transitionWindowPreloads.first?.index == 1)
        #expect(transitionWindowPreloads.first?.count == 3)
    }

    @Test
    func `a SmartFill surface arriving after the playback pool rebuilds the initial scene`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        let initialAssets = (0..<5).map { makeAsset(id: "asset-\($0)", width: 1800, height: 2000) }
        vm.replacePlaybackAssetsForTesting(initialAssets)
        var preloadRequests: [String] = []
        var initialSceneRequests: [String] = []
        vm.initialPhotoLoadHookForTesting = { assetId in
            initialSceneRequests.append(assetId)
            vm.downloadManager.assetStates[assetId] = .readyToPlay
        }
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            preloadRequests.append("\(assetId):\(size.rawValue)")
            switch size {
            case .fullsize:
                vm.downloadManager.assetStates[assetId] = .readyToPlay
            case .preview:
                vm.downloadManager.assetPreviewStates[assetId] = .readyToPlay
            default:
                break
            }
        }

        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 1179, height: 2556),
                profile: .iPhone,
                orientation: .portrait
            )
        )
        let didRebuildInitialScene = await waitUntil(pollInterval: initialSceneRequestPollInterval) {
            vm.safeCurrentScene?.smartFillReadback?.sceneType == .double
                && Set(initialSceneRequests) == Set(["asset-0", "asset-1"])
        }
        #expect(didRebuildInitialScene, "initial scene was not rebuilt before the deadline")

        #expect(vm.safeCurrentScene?.smartFillReadback?.sceneType == .double)
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0", "asset-1"])
        #expect(Set(initialSceneRequests) == Set(["asset-0", "asset-1"]))
        #expect(initialSceneRequests.filter { $0 == "asset-1" }.count == 1)
        #expect(Set(preloadRequests).isSubset(of: Set(["asset-0:fullsize", "asset-0:preview"])))
    }
}
