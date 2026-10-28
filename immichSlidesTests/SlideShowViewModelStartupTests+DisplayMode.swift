import Foundation
import Testing
@testable import immichSlides

extension SlideShowViewModelStartupTests {
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

        savePlaybackDisplayMode(.singlePhoto)
        vm.refreshAutoPlaySettingsFromStore()
        vm.requestNextScene()

        #expect(vm.scene(at: vm.targetIndex)?.primaryAssetId == "asset-1")
        completeCurrentScenePresentation(vm)
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-1"])
    }

    @Test
    func `switching to single photo keeps assets from earlier SmartFill scenes excluded from Next`() {
        let snapshot = PersistentPlaybackSnapshot.capture()
        defer { snapshot.restore() }
        savePlaybackDisplayMode(.smartFill)

        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(width: 1179, height: 2556),
                profile: .iPhone,
                orientation: .portrait
            )
        )
        // The panoramas put the first scene's partner after the later anchors in candidate order.
        let assets = (0..<5).map { index in
            makeAsset(
                id: "asset-\(index)", width: (1...2).contains(index) ? 6000 : 1800,
                height: (1...2).contains(index) ? 1000 : 2000)
        }
        markReady(assets, in: vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0", "asset-3"])

        for expectedAnchor in ["asset-1", "asset-2"] {
            vm.requestNextScene()
            completeCurrentScenePresentation(vm)
            #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == [expectedAnchor])
        }
        #expect(vm.currentIndex == 2)

        savePlaybackDisplayMode(.singlePhoto)
        vm.refreshAutoPlaySettingsFromStore()
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-2"])

        vm.requestNextScene()

        #expect(vm.scene(at: vm.targetIndex)?.primaryAssetId == "asset-4")
        completeCurrentScenePresentation(vm)
        #expect(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-4"])
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

        await vm.synchronizePlaybackReadbackForTesting(token: token, targetIndex: targetIndex)
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
}
