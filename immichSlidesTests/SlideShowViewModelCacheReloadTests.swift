//
//  SlideShowViewModelCacheReloadTests.swift
//  immichSlidesTests
//
//  After clearing the cache, preview and fullsize must be requested again for the current primaryAssetId;
//  neither a neighbor nor an empty scene may stand in.
//

import Foundation
import Testing
@testable import immichSlides

#if DEBUG
@MainActor
@Suite(.serialized, .sharedPlaybackRuntimeIsolation)
struct SlideShowViewModelCacheReloadTests {

    @Test
    func
        `clearing the cache without forceReload leaves the current asset not ready and issues no new preview or fullsize requests`()
        async
    {
        let fixture = makeCurrentSceneFixture()
        defer { resetSharedDownloadManager(fixture.vm.downloadManager) }

        await fixture.vm.downloadManager.clearDiskCacheForSettings()
        fixture.vm.downloadManager.resetPlaybackImageRequestLifecycleDiagnostics(isEnabled: true)

        #expect(!fixture.vm.downloadManager.isReady(assetId: fixture.currentId, size: .fullsize))
        #expect(!fixture.vm.downloadManager.isReady(assetId: fixture.currentId, size: .preview))
        #expect(fixture.vm.downloadManager.findURL(assetId: fixture.currentId, size: .fullsize) == nil)
        #expect(fixture.vm.downloadManager.findURL(assetId: fixture.currentId, size: .preview) == nil)
        #expect(
            fixture.vm.downloadManager.latestLifecycleRequestIdForTesting(assetId: fixture.currentId, size: .fullsize)
                == nil)
        #expect(
            fixture.vm.downloadManager.latestLifecycleRequestIdForTesting(assetId: fixture.currentId, size: .preview)
                == nil)
        #expect(
            fixture.vm.downloadManager.playbackImageRequestLifecycleSummary()
                .counter(for: .assetManagerLoadPhoto).requestCount == 0
        )
    }

    @Test
    func `force reload requests the current asset and never records the request against its neighbor`() async {
        let fixture = makeCurrentSceneFixture()
        defer { resetSharedDownloadManager(fixture.vm.downloadManager) }

        await fixture.vm.downloadManager.clearDiskCacheForSettings()
        fixture.vm.downloadManager.resetPlaybackImageRequestLifecycleDiagnostics(isEnabled: true)

        let captured = await forceReloadAndCaptureLifecycleRequestIds(
            vm: fixture.vm,
            currentId: fixture.currentId,
            neighborId: fixture.neighborId
        )

        #expect(captured.current[.fullsize] != nil)
        #expect(captured.current[.preview] != nil)
        #expect(captured.neighbor[.fullsize] == nil)
        #expect(captured.neighbor[.preview] == nil)
        #expect(fixture.vm.safeCurrentScene?.primaryAssetId == fixture.currentId)
    }

    @Test
    func `force reload after clearing the cache requests both preview and fullsize for the current asset`() async {
        let fixture = makeCurrentSceneFixture()
        defer { resetSharedDownloadManager(fixture.vm.downloadManager) }

        await fixture.vm.downloadManager.clearDiskCacheForSettings()
        #expect(!fixture.vm.downloadManager.isReady(assetId: fixture.currentId, size: .fullsize))
        #expect(!fixture.vm.downloadManager.isReady(assetId: fixture.currentId, size: .preview))

        fixture.vm.downloadManager.resetPlaybackImageRequestLifecycleDiagnostics(isEnabled: true)
        let captured = await forceReloadAndCaptureLifecycleRequestIds(
            vm: fixture.vm,
            currentId: fixture.currentId,
            neighborId: fixture.neighborId
        )

        #expect(captured.current[.fullsize] != nil)
        #expect(captured.current[.preview] != nil)
        #expect(captured.current[.fullsize] != captured.current[.preview])
        #expect(fixture.vm.safeCurrentScene?.primaryAssetId == fixture.currentId)
    }

    @Test
    func `force reload returns immediately without requests when there is no current scene`() async {
        let vm = makeIsolatedViewModel()
        defer { resetSharedDownloadManager(vm.downloadManager) }

        #expect(vm.safeCurrentScene == nil)
        vm.downloadManager.resetPlaybackImageRequestLifecycleDiagnostics(isEnabled: true)

        await vm.forceReloadCurrentAssetAfterCacheClear()

        #expect(vm.safeCurrentScene == nil)
        #expect(vm.downloadManager.latestLifecycleRequestIdForTesting(assetId: "current", size: .fullsize) == nil)
        #expect(vm.downloadManager.latestLifecycleRequestIdForTesting(assetId: "current", size: .preview) == nil)
        #expect(
            vm.downloadManager.playbackImageRequestLifecycleSummary()
                .counter(for: .assetManagerLoadPhoto).requestCount == 0
        )
    }

    private struct CurrentSceneFixture {
        let vm: SlideShowViewModel
        let currentId: String
        let neighborId: String
    }

    // Uses only the shared manager; preloading is blocked first so neighbor requests do not pollute it before the
    // cache is cleared.
    private func makeCurrentSceneFixture() -> CurrentSceneFixture {
        let vm = makeIsolatedViewModel()
        #expect(vm.downloadManager === AssetsDownloadManager.shared)

        let currentId = "current"
        let neighborId = "neighbor"
        let currentURL = URL(fileURLWithPath: "/tmp/immichslides-cache-reload-current.jpg")
        // setURL lives in a private extension, so the test can only write the existing public dictionaries.
        vm.downloadManager.assetURLs[currentId] = currentURL
        vm.downloadManager.assetPreviewURLs[currentId] = currentURL
        markReady(assetId: currentId, size: .fullsize, in: vm.downloadManager)
        markReady(assetId: currentId, size: .preview, in: vm.downloadManager)

        vm.replacePlaybackAssetsForTesting([
            makeAsset(id: currentId),
            makeAsset(id: neighborId)
        ])
        #expect(vm.safeCurrentScene?.primaryAssetId == currentId)
        return CurrentSceneFixture(vm: vm, currentId: currentId, neighborId: neighborId)
    }

    private func makeIsolatedViewModel() -> SlideShowViewModel {
        let vm = SlideShowViewModel(source: .random)
        resetSharedDownloadManager(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.transitionWindowPreloadHookForTesting = { _, _, _ in }
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        return vm
    }

    // Production awaits fullsize, then preview; the hooks are cleared when loadPhoto ends.
    // Open one observation window for each, in that order; never require both ids to be non-nil at the same instant.
    // The preview seed must be in place before fullsize is released, or the second request ends before its window
    // opens.
    private func forceReloadAndCaptureLifecycleRequestIds(
        vm: SlideShowViewModel,
        currentId: String,
        neighborId: String
    ) async -> (current: [ThumbnailSize: String], neighbor: [ThumbnailSize: String]) {
        let manager = vm.downloadManager
        _ = manager.seedRunningPhotoLoadForTesting(
            assetId: currentId,
            size: .fullsize,
            priority: .high
        )
        _ = manager.seedRunningPhotoLoadForTesting(
            assetId: currentId,
            size: .preview,
            priority: .high
        )

        let reloadTask = Task {
            await vm.forceReloadCurrentAssetAfterCacheClear()
        }

        var current: [ThumbnailSize: String] = [:]
        var neighbor: [ThumbnailSize: String] = [:]

        await captureLifecycleRequestIdsInProductionOrder(
            manager: manager,
            currentId: currentId,
            neighborId: neighborId,
            size: .fullsize,
            current: &current,
            neighbor: &neighbor
        )
        await captureLifecycleRequestIdsInProductionOrder(
            manager: manager,
            currentId: currentId,
            neighborId: neighborId,
            size: .preview,
            current: &current,
            neighbor: &neighbor
        )

        await reloadTask.value
        return (current, neighbor)
    }

    private func captureLifecycleRequestIdsInProductionOrder(
        manager: AssetsDownloadManager,
        currentId: String,
        neighborId: String,
        size: ThumbnailSize,
        current: inout [ThumbnailSize: String],
        neighbor: inout [ThumbnailSize: String]
    ) async {
        _ = await waitUntilForTesting {
            manager.latestLifecycleRequestIdForTesting(assetId: currentId, size: size) != nil
        }
        captureLifecycleRequestIds(
            manager: manager,
            currentId: currentId,
            neighborId: neighborId,
            size: size,
            current: &current,
            neighbor: &neighbor
        )
        manager.clearSeededRunningPhotoLoadForTesting(assetId: currentId, size: size)
    }

    private func captureLifecycleRequestIds(
        manager: AssetsDownloadManager,
        currentId: String,
        neighborId: String,
        size: ThumbnailSize,
        current: inout [ThumbnailSize: String],
        neighbor: inout [ThumbnailSize: String]
    ) {
        if let requestId = manager.latestLifecycleRequestIdForTesting(assetId: currentId, size: size) {
            current[size] = requestId
        }
        if let requestId = manager.latestLifecycleRequestIdForTesting(assetId: neighborId, size: size) {
            neighbor[size] = requestId
        }
    }

    private func waitUntilForTesting(
        maxYields: Int = 10_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<maxYields {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
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

    private func makeAsset(id: String) -> Asset {
        Asset(
            id: id,
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: nil,
            people: nil,
            tags: nil,
            livePhotoVideoID: nil
        )
    }

    private func resetSharedDownloadManager(_ manager: AssetsDownloadManager) {
        manager.assetStates = [:]
        manager.assetPreviewStates = [:]
        manager.assetThumbnailStates = [:]
        manager.assetURLs = [:]
        manager.assetPreviewURLs = [:]
        manager.assetThumbnailURLs = [:]
        manager.resetPlaybackImageRequestLifecycleDiagnostics()
        manager.clearSeededRunningPhotoLoadForTesting(assetId: "current", size: .fullsize)
        manager.clearSeededRunningPhotoLoadForTesting(assetId: "current", size: .preview)
        manager.clearSeededRunningPhotoLoadForTesting(assetId: "neighbor", size: .fullsize)
        manager.clearSeededRunningPhotoLoadForTesting(assetId: "neighbor", size: .preview)
    }
}
#endif
