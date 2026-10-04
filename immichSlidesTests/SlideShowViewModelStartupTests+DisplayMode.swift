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
