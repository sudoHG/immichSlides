//
//  SlideShowViewModelStartupTests.swift
//  immichSlidesTests
//
//  Covers the state flow from cold launch into the playback page; settings are restored only from local
//  persistence.
//

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.serialized, .sharedPlaybackRuntimeIsolation)
struct SlideShowViewModelStartupTests {
    private let initialSceneRequestPollIntervalNanoseconds: UInt64 = 30_000_000
    // 100 polls of 30 ms retain the existing nominal three-second wait budget.
    private let initialSceneRequestPollCount: Int = 100
    private let persistedPlaybackIntervalSeconds: Int = 9

    @Test
    func `cold launch uses the stored filtered source when the default mode is filtered and criteria are non-empty`() {
        let snapshot = PersistentPlaybackSnapshot.capture()
        defer { snapshot.restore() }

        var settings = PlaybackSettings()
        settings.defaultPlaybackMode = .filtered
        PlaybackSettingsStore().save(settings)

        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-solo", matchMode: .soloOnly)]
        )
        FilterSelectionStore().save(selection)

        let source = ContentView.initialPlaybackSourceForColdLaunch()

        var restoredSelection: FilterSelection?
        if case .filtered(let selection) = source {
            restoredSelection = selection
        }

        #expect(restoredSelection == selection)
    }

    @Test
    func `cold launch falls back to random playback when the default filtered selection is empty`() {
        let snapshot = PersistentPlaybackSnapshot.capture()
        defer { snapshot.restore() }

        var settings = PlaybackSettings()
        settings.defaultPlaybackMode = .filtered
        PlaybackSettingsStore().save(settings)
        FilterSelectionStore().clear()

        let source = ContentView.initialPlaybackSourceForColdLaunch()

        var isRandom = false
        if case .random = source {
            isRandom = true
        }

        #expect(isRandom)
    }

    @Test
    func `a stale initial preload task cannot overwrite a newer filtered playback result`() async throws {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)

        var randomContinuation: CheckedContinuation<[Asset], any Error>?

        vm.loadAssetsHookForTesting = { source in
            switch source {
            case .random:
                return try await withCheckedThrowingContinuation { continuation in
                    randomContinuation = continuation
                }
            case .filtered:
                return [makeAsset(id: "filtered-asset")]
            }
        }

        // Isolate generation from real downloads so a late network completion cannot overwrite the newer filter.
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }

        let oldPreloadTask = Task {
            await vm.firstPreload()
        }

        // Wait until the old random task reaches its suspension point before switching source.
        let didSuspend = await waitUntil { randomContinuation != nil }
        try #require(didSuspend, "Timed out waiting for randomContinuation to be captured")

        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-solo", matchMode: .soloOnly)]
        )
        await vm.switchPlaybackSource(to: .filtered(selection))

        #expect(vm.assets.map(\.id) == ["filtered-asset"])
        #expect(vm.isLoading == false)
        #expect(vm.didFirstPreload)

        // A late empty array from the old random task must be dropped by generation, or it would turn the new filter
        // into an empty pool.

        randomContinuation?.resume(returning: [])
        await oldPreloadTask.value

        #expect(vm.assets.map(\.id) == ["filtered-asset"])
        #expect(vm.isLoading == false)
        #expect(vm.shouldReloadFilteredSource(for: selection) == false)
    }

    @Test
    func `a stale load-more task cannot append into a newer filtered playback result`() async throws {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.assets = [makeAsset(id: "old-random")]

        var randomContinuation: CheckedContinuation<[Asset], any Error>?

        vm.loadMoreAssetsHookForTesting = { source in
            switch source {
            case .random:
                return try await withCheckedThrowingContinuation { continuation in
                    randomContinuation = continuation
                }
            case .filtered:
                return [makeAsset(id: "filtered-more")]
            }
        }

        vm.loadAssetsHookForTesting = { source in
            switch source {
            case .random:
                return [makeAsset(id: "random-asset")]
            case .filtered:
                return [makeAsset(id: "filtered-asset")]
            }
        }

        // Only checks playback pool state; no image downloads.
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }

        let oldLoadMoreTask = Task {
            await vm.loadMoreAssets()
        }

        let didSuspend = await waitUntil { randomContinuation != nil }
        try #require(didSuspend, "Timed out waiting for randomContinuation to be captured")

        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-solo", matchMode: .soloOnly)]
        )
        await vm.switchPlaybackSource(to: .filtered(selection))

        #expect(vm.assets.map(\.id) == ["filtered-asset"])
        #expect(vm.isLoadingMore == false)

        // A late random refill must be dropped; the new filtered pool stays unchanged.

        randomContinuation?.resume(returning: [makeAsset(id: "stale-random-more")])
        await oldLoadMoreTask.value

        #expect(vm.assets.map(\.id) == ["filtered-asset"])
        #expect(vm.isLoadingMore == false)
    }

    @Test
    func `the initial load result cannot write back when the session identity changed even if generation did not`()
        async throws
    {
        let vm = SlideShowViewModel(source: .random)
        var continuation: CheckedContinuation<[Asset], any Error>?
        vm.loadAssetsHookForTesting = { _ in
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
            }
        }

        let loadTask = Task {
            await vm.loadAssets()
        }
        let didSuspend = await waitUntil { continuation != nil }
        try #require(didSuspend, "Timed out waiting for continuation to be captured")

        vm.replacePlaybackAssetsForTesting([makeAsset(id: "new-session")])
        continuation?.resume(returning: [makeAsset(id: "stale-result")])
        let didApply = await loadTask.value

        #expect(didApply == false)
        #expect(vm.assets.map(\.id) == ["new-session"])
        #expect(vm.safeCurrentScene?.primaryAssetId == "new-session")
    }

    @Test
    func `the load-more result cannot append when the session identity changed even if generation did not`()
        async throws
    {
        let vm = SlideShowViewModel(source: .random)
        vm.replacePlaybackAssetsForTesting([makeAsset(id: "old-session")])
        var continuation: CheckedContinuation<[Asset], any Error>?
        vm.loadMoreAssetsHookForTesting = { _ in
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
            }
        }

        let loadMoreTask = Task {
            await vm.loadMoreAssets()
        }
        let didSuspend = await waitUntil { continuation != nil }
        try #require(didSuspend, "Timed out waiting for continuation to be captured")

        vm.replacePlaybackAssetsForTesting([makeAsset(id: "new-session")])
        continuation?.resume(returning: [makeAsset(id: "stale-more")])
        await loadMoreTask.value

        #expect(vm.assets.map(\.id) == ["new-session"])
    }

    @Test
    func `a filtered soloOnly load-more still appends to the same playback pool after the scene advanced in-session`()
        async throws
    {
        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-solo", matchMode: .soloOnly)]
        )
        let vm = SlideShowViewModel(source: .filtered(selection))
        resetDownloadManagerState(vm.downloadManager)
        vm.maxAssetCount = 200
        vm.qaPlaybackSequenceEvidenceEnabledForTesting = true
        var emittedLines: [String] = []
        vm.qaPlaybackSequenceOSLogEmitterForTesting = { line in
            emittedLines.append(line)
        }
        let initialAssets = (0..<12).map { makeAsset(id: "asset-\($0)") }
        markReady(initialAssets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(initialAssets)

        var continuation: CheckedContinuation<[Asset], any Error>?
        vm.loadMoreAssetsHookForTesting = { _ in
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
            }
        }

        let loadMoreTask = Task {
            await vm.loadMoreAssets()
        }
        let didSuspend = await waitUntil { continuation != nil }
        try #require(didSuspend, "Timed out waiting for continuation to be captured")

        vm.requestNextScene()
        let transitionToken = vm.targetTransitionToken
        let transitionTargetIndex = vm.targetIndex
        await vm.handleTransitionChange(token: transitionToken, targetIndex: transitionTargetIndex)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")

        let appendedAssets = (12..<36).map { makeAsset(id: "asset-\($0)") }
        continuation?.resume(returning: appendedAssets)
        await loadMoreTask.value

        #expect(vm.isLoadingMore == false)
        #expect(vm.assets.map(\.id) == (0..<36).map { "asset-\($0)" })
        #expect(emittedLines.contains { $0.contains("eventType=loadMoreResult") })
        #expect(emittedLines.contains { $0.contains("old=12") || $0.contains("oldCount=12") })
    }

    @Test
    func `an initial preload cannot mark the old scene current after the session changed`() async throws {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.loadAssetsHookForTesting = { _ in
            [makeAsset(id: "old-initial")]
        }
        var continuation: CheckedContinuation<Void, Never>?
        vm.initialPhotoLoadHookForTesting = { assetId in
            guard assetId == "old-initial", continuation == nil else { return }
            await withCheckedContinuation { pending in
                continuation = pending
            }
        }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }

        let preloadTask = Task {
            await vm.prepareInitialAssets()
        }
        let didSuspend = await waitUntil { continuation != nil }
        try #require(didSuspend, "Timed out waiting for continuation to be captured")

        vm.replacePlaybackAssetsForTesting([makeAsset(id: "new-session")])
        continuation?.resume()
        await preloadTask.value

        #expect(vm.didFirstPreload == false)
        #expect(vm.assets.map(\.id) == ["new-session"])
        #expect(vm.safeCurrentScene?.primaryAssetId == "new-session")
    }

    @Test
    func `playback scenes come from the session engine and never reuse a sceneId for the same asset`() {
        let vm = SlideShowViewModel(source: .random)
        let zeroSessionId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

        vm.replacePlaybackAssetsForTesting([
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b")
        ])

        #expect(vm.playbackScenes.compactMap(\.primaryAssetId) == ["asset-a"])
        #expect(vm.assetIds(in: 0...1) == ["asset-a"])
        let firstSessionId = vm.playbackScenes.first?.playbackSessionId
        #expect(firstSessionId != zeroSessionId)

        vm.replacePlaybackAssetsForTesting([makeAsset(id: "asset-a")])

        #expect(vm.playbackScenes.compactMap(\.primaryAssetId) == ["asset-a"])
        #expect(vm.playbackScenes.first?.playbackSessionId != firstSessionId)
        #expect(vm.sceneIdLogValue(at: 1) == "nil")
    }

    @Test
    func `after the initial preload, currentIndex aligns with safeCurrentScene`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.loadAssetsHookForTesting = { _ in
            [
                makeAsset(id: "asset-a"),
                makeAsset(id: "asset-b")
            ]
        }
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }

        await vm.prepareInitialAssets()

        #expect(vm.currentIndex == 0)
        #expect(vm.targetIndex == 0)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-a")
        #expect(vm.sceneIdLogValue(at: vm.currentIndex) == vm.safeCurrentScene?.id)
        #expect(vm.safeCurrentScene?.playbackSessionId != UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        #expect(vm.safeCurrentAsset?.id == "asset-a")
    }

    @Test
    func `after a manual next, currentIndex and targetIndex point to the same scene`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.assets = [
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b"),
            makeAsset(id: "asset-c")
        ]
        vm.replacePlaybackAssetsForTesting(vm.assets)
        vm.requestNextScene()
        let transitionToken = vm.targetTransitionToken
        let transitionTargetIndex = vm.targetIndex
        vm.downloadManager.assetStates["asset-b"] = .readyToPlay
        vm.downloadManager.assetPreviewStates["asset-b"] = .readyToPlay

        await vm.handleTransitionChange(token: transitionToken, targetIndex: transitionTargetIndex)

        #expect(vm.currentIndex == 1)
        #expect(vm.targetIndex == 1)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-b")
        #expect(vm.sceneIdLogValue(at: vm.targetIndex) == vm.safeCurrentScene?.id)
        #expect(vm.safeCurrentScene?.playbackSessionId != UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
    }

    @Test
    func `QA playback sequence evidence is off by default and uses the shared log path only when enabled`() async {
        let rawAssetId = "raw-asset-id-that-must-not-leak"
        let disabledVM = SlideShowViewModel(source: .random)
        resetDownloadManagerState(disabledVM.downloadManager)
        disabledVM.loadAssetsHookForTesting = { _ in
            [makeAsset(id: rawAssetId)]
        }
        disabledVM.initialPhotoLoadHookForTesting = { _ in }
        disabledVM.backgroundPreloadHookForTesting = { _, _, _ in }

        var capturedLines: [String] = []
        disabledVM.qaPlaybackSequenceOSLogEmitterForTesting = { capturedLines.append($0) }

        await disabledVM.prepareInitialAssets()
        completeCurrentScenePresentation(disabledVM)
        #expect(capturedLines.isEmpty)

        let enabledVM = SlideShowViewModel(source: .random)
        resetDownloadManagerState(enabledVM.downloadManager)
        enabledVM.loadAssetsHookForTesting = { _ in
            [makeAsset(id: rawAssetId)]
        }
        enabledVM.initialPhotoLoadHookForTesting = { _ in }
        enabledVM.backgroundPreloadHookForTesting = { _, _, _ in }
        enabledVM.qaPlaybackSequenceEvidenceEnabledForTesting = true
        enabledVM.qaPlaybackSequenceOSLogEmitterForTesting = { capturedLines.append($0) }
        await enabledVM.prepareInitialAssets()
        completeCurrentScenePresentation(enabledVM)

        let displayLines = capturedLines.filter { $0.hasPrefix("qa_playback_sequence ") }
        #expect(displayLines.count == 1)
        let line = displayLines[0]
        #expect(line.hasPrefix("qa_playback_sequence "))
        #expect(line.contains("assetStableId=asset_"))
        #expect(line.contains("sceneStableId=asset_"))
        #expect(line.contains("recentWindow=empty"))
        #expect(line.contains("duplicateInWindow=false"))
        #expect(line.contains("windowDuplicateSummary=none"))
        #expect(line.contains(rawAssetId) == false)
    }

    @Test
    func `QA playback sequence evidence records only committed and displayed assets`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.qaPlaybackSequenceEvidenceEnabledForTesting = true
        var capturedLines: [String] = []
        vm.qaPlaybackSequenceOSLogEmitterForTesting = { capturedLines.append($0) }
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        let assets = [
            makeAsset(id: "asset-a-raw"),
            makeAsset(id: "asset-b-raw")
        ]
        markReady(assets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)
        capturedLines.removeAll()

        vm.requestNextScene()
        #expect(capturedLines.isEmpty)
        completeCurrentScenePresentation(vm)

        let displayLines = capturedLines.filter { $0.hasPrefix("qa_playback_sequence ") }
        let eventLines = capturedLines.filter { $0.hasPrefix("qa_playback_sequence_event ") }
        #expect(displayLines.count == 1)
        #expect(displayLines[0].contains("assetStableId=asset_"))
        #expect(displayLines[0].contains("asset-b-raw") == false)
        #expect(eventLines.contains { $0.contains("eventType=loadMoreDecision") })
        #expect(capturedLines.joined(separator: "\n").contains("asset-b-raw") == false)
    }

    @Test
    func `real next and previous navigation switches scenes through the transition token`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        let assets = [
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b")
        ]
        markReady(assets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)
        let initialToken = vm.targetTransitionToken

        vm.requestNextScene()
        let nextToken = vm.targetTransitionToken
        let nextTargetIndex = vm.targetIndex
        #expect(nextToken != initialToken)
        completeCurrentScenePresentation(vm)

        vm.requestPreviousScene()
        #expect(vm.targetTransitionToken != nextToken)
        let previousTargetIndex = vm.targetIndex
        #expect(previousTargetIndex == nextTargetIndex)

        completeCurrentScenePresentation(vm)

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-a")
        #expect(vm.canRequestPreviousScene == false)
    }

    @Test
    func `a new scene with the same numeric targetIndex is exposed through a new transition token`() {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        let assets = [
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b")
        ]
        markReady(assets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)

        vm.requestNextScene()
        let firstToken = vm.targetTransitionToken
        let firstTargetIndex = vm.targetIndex
        let firstSceneId = vm.scene(at: firstTargetIndex)?.id
        completeCurrentScenePresentation(vm)

        vm.requestPreviousScene()

        #expect(vm.targetIndex == firstTargetIndex)
        #expect(vm.targetTransitionToken != firstToken)
        #expect(vm.scene(at: vm.targetIndex)?.id != firstSceneId)
    }

    @Test
    func `a stale transition handler cannot commit a newer pending transition`() async throws {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        let assets = [
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b"),
            makeAsset(id: "asset-c")
        ]
        markReady(assets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)
        var delayedEntry: CheckedContinuation<Void, Never>?

        vm.requestNextScene()
        let firstPendingToken = vm.targetTransitionToken
        let firstPendingTargetIndex = vm.targetIndex
        let firstPendingSceneId = vm.scene(at: vm.targetIndex)?.id
        let oldHandlerTask = Task {
            await withCheckedContinuation { pending in
                delayedEntry = pending
            }
            await vm.handleTransitionChange(token: firstPendingToken, targetIndex: firstPendingTargetIndex)
        }
        let didSuspend = await waitUntil { delayedEntry != nil }
        try #require(didSuspend, "Timed out waiting for delayedEntry to be captured")

        vm.requestNextScene()
        let newerPendingSceneId = vm.scene(at: vm.targetIndex)?.id
        #expect(newerPendingSceneId != firstPendingSceneId)
        #expect(vm.scene(at: vm.targetIndex)?.primaryAssetId == "asset-c")

        delayedEntry?.resume()
        await oldHandlerTask.value

        #expect(vm.currentIndex == 2)
        #expect(vm.scene(at: vm.targetIndex)?.id == newerPendingSceneId)
    }

    @Test
    func `retained history capped at 20 still advances the candidate cursor and triggers load more`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.maxAssetCount = 200
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        var loadMoreCallCount = 0
        vm.loadMoreAssetsHookForTesting = { _ in
            loadMoreCallCount += 1
            return (30..<35).map { makeAsset(id: "asset-\($0)") }
        }
        let initialAssets = (0..<30).map { makeAsset(id: "asset-\($0)") }
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        markReady(initialAssets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(initialAssets)
        completeCurrentScenePresentation(vm)

        for step in 1...26 {
            vm.requestNextScene()
            let token = vm.targetTransitionToken
            let targetIndex = vm.targetIndex
            let expectedAssetId = "asset-\(step)"
            #expect(vm.scene(at: targetIndex)?.primaryAssetId == expectedAssetId)
            await vm.handleTransitionChange(token: token, targetIndex: targetIndex)
            completeCurrentScenePresentation(vm)
            #expect(vm.safeCurrentScene?.primaryAssetId == expectedAssetId)
        }

        await waitForLoadMoreAttempt(1, callCount: { loadMoreCallCount }, in: vm)

        #expect(vm.playbackScenes.count == 20)
        #expect(vm.playbackScenes.compactMap(\.primaryAssetId) == (7...26).map { "asset-\($0)" })
        #expect(loadMoreCallCount > 0)
    }

    @Test
    func `filtered load more appends only unseen asset ids`() async {
        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-a", matchMode: .normal)],
            tagIds: [],
            rating: nil,
            isFavorite: nil
        )
        let vm = SlideShowViewModel(source: .filtered(selection))
        resetDownloadManagerState(vm.downloadManager)
        vm.maxAssetCount = 200
        vm.loadMoreAssetsHookForTesting = { _ in
            [
                makeAsset(id: "asset-2"),
                makeAsset(id: "asset-4"),
                makeAsset(id: "asset-5"),
                makeAsset(id: "asset-6")
            ]
        }
        vm.replacePlaybackAssetsForTesting((0..<5).map { makeAsset(id: "asset-\($0)") })

        await vm.loadMoreAssets()

        #expect(
            vm.assets.map(\.id) == [
                "asset-0",
                "asset-1",
                "asset-2",
                "asset-3",
                "asset-4",
                "asset-5",
                "asset-6"
            ])
    }

    @Test
    func `random load more dedupes the current pool and incoming batch while preserving new order`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.maxAssetCount = 200
        vm.loadMoreAssetsHookForTesting = { _ in
            [
                makeAsset(id: "asset-2"),
                makeAsset(id: "asset-5"),
                makeAsset(id: "asset-5"),
                makeAsset(id: "asset-6"),
                makeAsset(id: "asset-4"),
                makeAsset(id: "asset-7")
            ]
        }
        vm.replacePlaybackAssetsForTesting((0..<5).map { makeAsset(id: "asset-\($0)") })

        await vm.loadMoreAssets()

        #expect(
            vm.assets.map(\.id) == [
                "asset-0",
                "asset-1",
                "asset-2",
                "asset-3",
                "asset-4",
                "asset-5",
                "asset-6",
                "asset-7"
            ])
    }

    @Test
    func `filtered load more finishes without changing the pool when every returned asset is a duplicate`() async {
        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-a", matchMode: .normal)],
            tagIds: [],
            rating: nil,
            isFavorite: nil
        )
        let vm = SlideShowViewModel(source: .filtered(selection))
        resetDownloadManagerState(vm.downloadManager)
        vm.maxAssetCount = 200
        vm.loadMoreAssetsHookForTesting = { _ in
            [
                makeAsset(id: "asset-1"),
                makeAsset(id: "asset-2"),
                makeAsset(id: "asset-2")
            ]
        }
        vm.replacePlaybackAssetsForTesting((0..<4).map { makeAsset(id: "asset-\($0)") })

        await vm.loadMoreAssets()

        #expect(
            vm.assets.map(\.id) == [
                "asset-0",
                "asset-1",
                "asset-2",
                "asset-3"
            ])
        #expect(vm.isLoadingMore == false)
    }

    @Test
    func `filtered load more writes QA playback sequence lifecycle events`() async {
        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-a", matchMode: .soloOnly)],
            tagIds: [],
            rating: nil,
            isFavorite: nil
        )
        let vm = SlideShowViewModel(source: .filtered(selection))
        resetDownloadManagerState(vm.downloadManager)
        vm.maxAssetCount = 200
        vm.qaPlaybackSequenceEvidenceEnabledForTesting = true
        var emittedLines: [String] = []
        vm.qaPlaybackSequenceOSLogEmitterForTesting = { line in
            emittedLines.append(line)
        }
        vm.loadMoreAssetsHookForTesting = { _ in
            [
                makeAsset(id: "asset-1"),
                makeAsset(id: "asset-2")
            ]
        }
        vm.replacePlaybackAssetsForTesting((0..<4).map { makeAsset(id: "asset-\($0)") })

        await vm.loadMoreAssets()

        #expect(emittedLines.contains { $0.contains("eventType=loadMoreBegin") })
        #expect(emittedLines.contains { $0.contains("eventType=loadMoreResult") })
        #expect(emittedLines.contains { $0.contains("eventType=loadMoreSaturated") })
        #expect(emittedLines.joined(separator: "\n").contains("person-a") == false)
        #expect(emittedLines.joined(separator: "\n").contains("asset-1") == false)
    }

    @Test
    func `a thrown filtered load more failure unlocks loading and writes failure evidence`() async {
        struct LoadMoreTestError: Error {}
        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-a", matchMode: .soloOnly)],
            tagIds: [],
            rating: nil,
            isFavorite: nil
        )
        let vm = SlideShowViewModel(source: .filtered(selection))
        resetDownloadManagerState(vm.downloadManager)
        vm.qaPlaybackSequenceEvidenceEnabledForTesting = true
        var emittedLines: [String] = []
        vm.qaPlaybackSequenceOSLogEmitterForTesting = { line in
            emittedLines.append(line)
        }
        vm.loadMoreAssetsHookForTesting = { _ in
            throw LoadMoreTestError()
        }
        vm.replacePlaybackAssetsForTesting((0..<12).map { makeAsset(id: "asset-\($0)") })

        await vm.loadMoreAssets()

        #expect(vm.isLoadingMore == false)
        #expect(emittedLines.contains { $0.contains("eventType=loadMoreFailure") })
        #expect(emittedLines.contains { $0.contains("errorKind=failure") })
        #expect(vm.assets.map(\.id) == (0..<12).map { "asset-\($0)" })
    }

    @Test
    func `committed scenes remain readable through retained history`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        let initialAssets = (0..<5).map { makeAsset(id: "asset-\($0)") }
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        vm.replacePlaybackAssetsForTesting(initialAssets)
        markReady(initialAssets, in: vm.downloadManager)
        completeCurrentScenePresentation(vm)

        for expectedAssetId in ["asset-1", "asset-2", "asset-3"] {
            vm.requestNextScene()
            let token = vm.targetTransitionToken
            let targetIndex = vm.targetIndex
            #expect(vm.scene(at: targetIndex)?.primaryAssetId == expectedAssetId)
            await vm.handleTransitionChange(token: token, targetIndex: targetIndex)
            completeCurrentScenePresentation(vm)
            #expect(vm.safeCurrentScene?.primaryAssetId == expectedAssetId)
        }

        vm.requestPreviousScene()
        var token = vm.targetTransitionToken
        var targetIndex = vm.targetIndex
        #expect(vm.scene(at: targetIndex)?.primaryAssetId == "asset-2")
        await vm.handleTransitionChange(token: token, targetIndex: targetIndex)
        completeCurrentScenePresentation(vm)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-2")

        vm.requestPreviousScene()
        token = vm.targetTransitionToken
        targetIndex = vm.targetIndex
        #expect(vm.scene(at: targetIndex)?.primaryAssetId == "asset-1")
        await vm.handleTransitionChange(token: token, targetIndex: targetIndex)
        completeCurrentScenePresentation(vm)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")

        vm.requestNextScene()
        token = vm.targetTransitionToken
        targetIndex = vm.targetIndex
        #expect(vm.scene(at: targetIndex)?.primaryAssetId == "asset-2")
        await vm.handleTransitionChange(token: token, targetIndex: targetIndex)
        completeCurrentScenePresentation(vm)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-2")
    }

    @Test
    func `keep ids include retained history asset ids after the candidate pool is trimmed`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        let initialAssets = (0..<30).map { makeAsset(id: "asset-\($0)") }
        vm.replacePlaybackAssetsForTesting(initialAssets)

        for _ in 1...26 {
            vm.requestNextScene()
            let token = vm.targetTransitionToken
            let targetIndex = vm.targetIndex
            await vm.handleTransitionChange(token: token, targetIndex: targetIndex)
        }

        vm.assets = (26..<30).map { makeAsset(id: "asset-\($0)") }
        let keepIds = vm.makeKeepIds(currentIndex: vm.currentIndex)

        #expect(keepIds.isSuperset(of: Set((7...26).map { "asset-\($0)" })))
    }

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

            await vm.handleTransitionChange(token: token, targetIndex: targetIndex)
            #expect(vm.safeCurrentScene?.primaryAssetId == "asset-\(expectedIndex)")
        }

        vm.requestNextScene()
        let token = vm.targetTransitionToken
        let targetIndex = vm.targetIndex

        #expect(vm.scene(at: targetIndex)?.primaryAssetId == "asset-14")
        #expect(vm.scene(at: targetIndex)?.photoSlots.map(\.asset.id).contains("asset-13") == false)

        await vm.handleTransitionChange(token: token, targetIndex: targetIndex)
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
            await vm.handleTransitionChange(token: token, targetIndex: targetIndex)
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
        for _ in 0..<1_000 where vm.isLoadingMore {
            await Task.yield()
        }
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
        await vm.handleTransitionChange(token: token, targetIndex: targetIndex)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-36")
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

        await vm.handleTransitionChange(token: token, targetIndex: targetIndex)
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

        await vm.handleTransitionChange(token: token, targetIndex: targetIndex)
        for _ in 0..<1_000 where requestedLoads.isEmpty {
            await Task.yield()
        }

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
        for _ in 0..<1_000 where initialSceneRequests.count < 2 {
            await Task.yield()
        }

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
        await vm.handleTransitionChange(token: token, targetIndex: targetIndex)
        for _ in 0..<1_000 where candidateWindowRequests.isEmpty {
            await Task.yield()
        }

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
        await vm.handleTransitionChange(token: vm.targetTransitionToken, targetIndex: vm.targetIndex)
        for _ in 0..<1_000 where transitionWindowPreloads.isEmpty { await Task.yield() }

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
        for _ in 0..<initialSceneRequestPollCount {
            if vm.safeCurrentScene?.smartFillReadback?.sceneType == .double,
                Set(initialSceneRequests) == Set(["asset-0", "asset-1"])
            {
                break
            }
            try? await Task.sleep(nanoseconds: initialSceneRequestPollIntervalNanoseconds)
        }

        #expect(vm.safeCurrentScene?.smartFillReadback?.sceneType == .double)
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0", "asset-1"])
        #expect(Set(initialSceneRequests) == Set(["asset-0", "asset-1"]))
        #expect(initialSceneRequests.filter { $0 == "asset-1" }.count == 1)
        #expect(Set(preloadRequests).isSubset(of: Set(["asset-0:fullsize", "asset-0:preview"])))
    }

    @Test
    func `a persisted single photo mode takes effect before the first scene is planned`() {
        let snapshot = PersistentPlaybackSnapshot.capture()
        defer { snapshot.restore() }
        savePlaybackDisplayMode(.singlePhoto)

        let vm = makeDisplayModeRebuildViewModel()

        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0"])
        #expect(vm.safeCurrentScene?.smartFillReadback == nil)
    }

    @Test
    func
        `switching from SmartFill to single photo instantly replaces the current scene in place and releases the partner asset`()
    {
        let snapshot = PersistentPlaybackSnapshot.capture()
        defer { snapshot.restore() }
        savePlaybackDisplayMode(.smartFill)

        let vm = makeDisplayModeRebuildViewModel()
        let originalScene = vm.safeCurrentScene
        let originalSceneId = originalScene?.id
        let originalPresentationIdentity = vm.sceneRenderSnapshot.layers.first?.identity
        let originalSlots = originalScene?.photoSlots.map(\.asset.id) ?? []
        #expect(originalSlots == ["asset-0", "asset-1"])

        savePlaybackDisplayMode(.singlePhoto)
        vm.refreshAutoPlaySettingsFromStore()

        #expect(vm.safeCurrentScene?.id == originalSceneId)
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0"])
        #expect(vm.sceneRenderSnapshot.layers.first?.identity.sceneID == originalPresentationIdentity?.sceneID)
        #expect(vm.sceneRenderSnapshot.layers.first?.identity.generation != originalPresentationIdentity?.generation)
        assertSettledWithoutTransitionLayers(vm)

        savePlaybackDisplayMode(.smartFill)
        vm.refreshAutoPlaySettingsFromStore()

        #expect(vm.safeCurrentScene?.id == originalSceneId)
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0", "asset-1"])
        assertSettledWithoutTransitionLayers(vm)
    }

    @Test
    func
        `switching from single photo to SmartFill rebuilds from the anchor and the next scene skips assets already consumed by the new slots`()
        async
    {
        let snapshot = PersistentPlaybackSnapshot.capture()
        defer { snapshot.restore() }
        savePlaybackDisplayMode(.singlePhoto)

        let vm = makeDisplayModeRebuildViewModel()
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0"])

        savePlaybackDisplayMode(.smartFill)
        vm.refreshAutoPlaySettingsFromStore()

        let rebuiltSlots = vm.safeCurrentScene?.photoSlots.map(\.asset.id) ?? []
        #expect(rebuiltSlots == ["asset-0", "asset-1"])
        assertSettledWithoutTransitionLayers(vm)

        vm.requestNextScene()
        let token = vm.targetTransitionToken
        let targetIndex = vm.targetIndex
        #expect(vm.scene(at: targetIndex)?.primaryAssetId == "asset-2")

        await vm.handleTransitionChange(token: token, targetIndex: targetIndex)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-2")
    }

    @Test
    func `refreshing settings with an unchanged display mode does not rebuild the scene or reset playback state`() {
        let snapshot = PersistentPlaybackSnapshot.capture()
        defer { snapshot.restore() }
        savePlaybackDisplayMode(.smartFill)

        let vm = makeDisplayModeRebuildViewModel()
        let originalSceneId = vm.safeCurrentScene?.id
        let originalSlots = vm.safeCurrentScene?.photoSlots.map(\.asset.id)
        let originalPresentationIdentity = vm.sceneRenderSnapshot.layers.first?.identity
        let originalToken = vm.targetTransitionToken

        vm.refreshAutoPlaySettingsFromStore()

        #expect(vm.safeCurrentScene?.id == originalSceneId)
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == originalSlots)
        #expect(vm.sceneRenderSnapshot.layers.first?.identity == originalPresentationIdentity)
        #expect(vm.targetTransitionToken == originalToken)
        assertSettledWithoutTransitionLayers(vm)
    }

    @Test
    func `switching display mode preserves the playback source and does not reload the whole pool`() {
        let snapshot = PersistentPlaybackSnapshot.capture()
        defer { snapshot.restore() }
        savePlaybackDisplayMode(.smartFill)

        let selection = FilterSelection(
            albumIds: ["album-a"],
            personFilters: [PersonFilter(personId: "person-a", matchMode: .normal)]
        )
        let vm = makeDisplayModeRebuildViewModel(source: .filtered(selection))
        var reloadRequestCount = 0
        vm.loadAssetsHookForTesting = { _ in
            reloadRequestCount += 1
            return []
        }

        savePlaybackDisplayMode(.singlePhoto)
        vm.refreshAutoPlaySettingsFromStore()

        #expect(vm.currentPlaybackMode == .filtered)
        #expect(vm.shouldReloadFilteredSource(for: selection) == false)
        #expect(reloadRequestCount == 0)
    }

    @Test
    func `strict solo produces a specific empty-state message when Vision is unavailable`() {
        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-solo", matchMode: .soloOnly)]
        )

        let message = SlideShowViewModel.emptyPlaybackMessage(
            for: .strictSoloVisionUnavailable,
            source: .filtered(selection)
        )
        let normalEmptyMessage = SlideShowViewModel.emptyPlaybackMessage(
            for: .noMatchingAssets,
            source: .filtered(selection)
        )
        let randomEmptyMessage = SlideShowViewModel.emptyPlaybackMessage(
            for: .noMatchingAssets,
            source: .random
        )

        // Does not check Chinese wording; verifies the Vision-unavailable message differs from the normal/random
        // empty-pool messages.

        #expect(message.isEmpty == false)
        #expect(message != normalEmptyMessage)
        #expect(message != randomEmptyMessage)
    }

    private func makeDisplayModeRebuildViewModel(
        source: PlaybackSource = .random
    ) -> SlideShowViewModel {
        let vm = SlideShowViewModel(source: source)
        resetDownloadManagerState(vm.downloadManager)
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 1179, height: 2556),
                profile: .iPhone,
                orientation: .portrait
            )
        )
        let assets = (0..<5).map { makeAsset(id: "asset-\($0)", width: 1800, height: 2000) }
        markReady(assets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(assets)
        return vm
    }

    private func savePlaybackDisplayMode(_ displayMode: PlaybackDisplayMode) {
        var settings = PlaybackSettings()
        settings.autoPlayEnabled = false
        settings.intervalSeconds = persistedPlaybackIntervalSeconds
        settings.showExif = false
        settings.defaultPlaybackMode = .filtered
        settings.showDebugOverlay = true
        settings.displayMode = displayMode
        PlaybackSettingsStore().save(settings)
    }

    private func assertSettledWithoutTransitionLayers(_ vm: SlideShowViewModel) {
        #expect(vm.sceneRenderSnapshot.phase != .transition)
        #expect(!vm.sceneRenderSnapshot.layers.contains { $0.role == .outgoing })
        #expect(vm.sceneRenderSnapshot.layers.count <= 1)
    }

    /// History is committed only through renderer decoded plus a visible tick of the full scene-root.
    private func completeCurrentScenePresentation(_ vm: SlideShowViewModel) {
        var snapshot = vm.sceneRenderSnapshot
        guard snapshot.phase != .stablePhoto,
            let targetLayer = snapshot.layers.last(where: { $0.role == .incoming }),
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
            let incoming = snapshot.layers.last(where: {
                $0.role == .incoming && $0.isPresentationReady
            })
        else {
            return
        }
        let visibleTime = (incoming.fadeStartTime ?? 0) + SceneTransitionDiagnostic.firstVisibleTickOffsetSeconds
        vm.scenePresentationTimestampProviderForTesting = { visibleTime }
        vm.incomingBecameVisible(
            ScenePresentationLayerIdentity(
                generation: incoming.identity.generation,
                sceneID: incoming.identity.sceneID,
                layerID: "scene-root"
            )
        )
        if let completionDeadline = vm.fireScheduledScenePresentationWakeUpForTesting() {
            vm.scenePresentationTimestampProviderForTesting = { completionDeadline }
        }
    }

    private func waitForLoadMoreAttempt(
        _ expectedCallCount: Int,
        callCount: () -> Int,
        in vm: SlideShowViewModel
    ) async {
        for _ in 0..<1_000 {
            if callCount() >= expectedCallCount && vm.isLoadingMore == false {
                return
            }
            await Task.yield()
        }
    }

    private func markReady(_ assets: [Asset], in manager: AssetsDownloadManager) {
        for asset in assets {
            manager.assetStates[asset.id] = .readyToPlay
            manager.assetPreviewStates[asset.id] = .readyToPlay
        }
    }

    private func makeAsset(
        id: String,
        width: Int? = nil,
        height: Int? = nil,
        exifInfo: ExifInfo? = nil,
        people: [People]? = nil
    ) -> Asset {
        Asset(
            id: id,
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: exifInfo,
            people: people,
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

private struct PersistentPlaybackSnapshot {
    let settings: PlaybackSettings?
    let selection: FilterSelection?

    static func capture() -> PersistentPlaybackSnapshot {
        PersistentPlaybackSnapshot(
            settings: PlaybackSettingsStore().load(),
            selection: FilterSelectionStore().load()
        )
    }

    func restore() {
        let settingsStore = PlaybackSettingsStore()
        if let settings {
            settingsStore.save(settings)
        } else {
            settingsStore.clear()
        }

        let selectionStore = FilterSelectionStore()
        if let selection {
            selectionStore.save(selection)
        } else {
            selectionStore.clear()
        }
    }
}
