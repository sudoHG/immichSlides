import Foundation
import Testing
@testable import immichSlides

extension SlideShowViewModelStartupTests {
    func makeDisplayModeRebuildViewModel(
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

    func savePlaybackDisplayMode(_ displayMode: PlaybackDisplayMode) {
        var settings = PlaybackSettings()
        settings.autoPlayEnabled = false
        settings.intervalSeconds = persistedPlaybackIntervalSeconds
        settings.showExif = false
        settings.defaultPlaybackMode = .filtered
        settings.showDebugOverlay = true
        settings.displayMode = displayMode
        PlaybackSettingsStore().save(settings)
    }

    func assertSettledWithoutTransitionLayers(_ vm: SlideShowViewModel) {
        #expect(vm.sceneRenderSnapshot.phase != .transition)
        #expect(!vm.sceneRenderSnapshot.layers.contains { $0.role == .outgoing })
        #expect(vm.sceneRenderSnapshot.layers.count <= 1)
    }

    /// History is committed only through renderer decoded plus a visible tick of the full scene-root.
    func completeCurrentScenePresentation(_ vm: SlideShowViewModel) {
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

    func waitForLoadMoreAttempt(
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

    func markReady(_ assets: [Asset], in manager: AssetsDownloadManager) {
        for asset in assets {
            manager.assetStates[asset.id] = .readyToPlay
            manager.assetPreviewStates[asset.id] = .readyToPlay
        }
    }

    func makeAsset(
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

    func resetDownloadManagerState(_ manager: AssetsDownloadManager) {
        manager.assetStates = [:]
        manager.assetPreviewStates = [:]
        manager.assetThumbnailStates = [:]
        manager.assetURLs = [:]
        manager.assetPreviewURLs = [:]
        manager.assetThumbnailURLs = [:]
    }
}
