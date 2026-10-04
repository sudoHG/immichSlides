import Foundation
import Testing
@testable import immichSlides

extension SlideShowViewModelStartupTests {
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
            await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
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
            await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
            completeCurrentScenePresentation(vm)
            #expect(vm.safeCurrentScene?.primaryAssetId == expectedAssetId)
        }

        vm.requestPreviousScene()
        var token = vm.targetTransitionToken
        var targetIndex = vm.targetIndex
        #expect(vm.scene(at: targetIndex)?.primaryAssetId == "asset-2")
        await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
        completeCurrentScenePresentation(vm)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-2")

        vm.requestPreviousScene()
        token = vm.targetTransitionToken
        targetIndex = vm.targetIndex
        #expect(vm.scene(at: targetIndex)?.primaryAssetId == "asset-1")
        await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
        completeCurrentScenePresentation(vm)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")

        vm.requestNextScene()
        token = vm.targetTransitionToken
        targetIndex = vm.targetIndex
        #expect(vm.scene(at: targetIndex)?.primaryAssetId == "asset-2")
        await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
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
            await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
        }

        vm.assets = (26..<30).map { makeAsset(id: "asset-\($0)") }
        let keepIds = vm.makeKeepIds(currentIndex: vm.currentIndex)

        #expect(keepIds.isSuperset(of: Set((7...26).map { "asset-\($0)" })))
    }
}
