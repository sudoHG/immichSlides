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
    let initialSceneRequestPollIntervalNanoseconds: UInt64 = 30_000_000
    // 100 polls of 30 ms retain the existing nominal three-second wait budget.
    let initialSceneRequestPollCount: Int = 100
    let persistedPlaybackIntervalSeconds: TimeInterval = 9

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
        await vm.synchronizePlaybackReadbackForTesting(token: transitionToken, targetIndex: transitionTargetIndex)
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

        await vm.synchronizePlaybackReadbackForTesting(token: transitionToken, targetIndex: transitionTargetIndex)

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
            await vm.synchronizePlaybackReadbackForTesting(
                token: firstPendingToken, targetIndex: firstPendingTargetIndex)
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
}

struct PersistentPlaybackSnapshot {
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
