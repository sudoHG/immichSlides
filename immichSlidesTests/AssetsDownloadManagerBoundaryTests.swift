//
//  AssetsDownloadManagerBoundaryTests.swift
//  immichSlidesTests
//
//  Offline coverage of the download manager cache, cancellation, renderer-role, and request-lifecycle contracts.
//

import Combine
import Foundation
import SDWebImage
import Testing
@testable import immichSlides

@MainActor
@Suite(.sharedRuntimeIsolation)
struct AssetsDownloadManagerBoundaryTests {

    @Test
    func `cache persistence snapshot requires every ready entry on disk and no in-flight tasks`() {
        let activeSnapshot = PlaybackImageCachePersistenceSnapshot(
            checkSequence: 1,
            activeTaskCount: 1,
            readyFullsizeCount: 1,
            diskReadyFullsizeCount: 1,
            readyPreviewCount: 1,
            diskReadyPreviewCount: 1
        )
        let missingPreviewSnapshot = PlaybackImageCachePersistenceSnapshot(
            checkSequence: 2,
            activeTaskCount: 0,
            readyFullsizeCount: 1,
            diskReadyFullsizeCount: 1,
            readyPreviewCount: 1,
            diskReadyPreviewCount: 0
        )
        let persistedSnapshot = PlaybackImageCachePersistenceSnapshot(
            checkSequence: 3,
            activeTaskCount: 0,
            readyFullsizeCount: 1,
            diskReadyFullsizeCount: 1,
            readyPreviewCount: 1,
            diskReadyPreviewCount: 1
        )

        #expect(!activeSnapshot.isPersisted)
        #expect(!missingPreviewSnapshot.isPersisted)
        #expect(missingPreviewSnapshot.missingReadyPreviewCount == 1)
        #expect(persistedSnapshot.isPersisted)
    }

    @Test
    func `SmartFill stable current slot resolves to the current diagnostics role, not incoming`() {
        #expect(
            PlaybackImageRequestLifecycleRole.smartFillRendererRole(
                isCurrent: true,
                renderLayerRole: .incoming
            ) == .current
        )
        #expect(
            PlaybackImageRequestLifecycleRole.smartFillRendererRole(
                isCurrent: false,
                renderLayerRole: .incoming
            ) == .incoming
        )
    }

    @Test
    func
        `the sole incoming renderer on first frame counts as current, but a real transition's incoming renderer does not`()
    {
        #expect(
            PlaybackSessionEngine.ScenePresentationLayerRole.isCurrentForRenderer(
                role: .incoming,
                opacity: 0,
                hasOutgoingLayer: false
            )
        )
        #expect(
            !PlaybackSessionEngine.ScenePresentationLayerRole.isCurrentForRenderer(
                role: .incoming,
                opacity: 0,
                hasOutgoingLayer: true
            ))
    }

    @Test
    func `preloading with an empty asset pool returns immediately without creating a reversed range`() async {
        // Use a new instance to avoid in-flight tasks in the global singleton.
        let manager = AssetsDownloadManager()

        await manager.preloadPhotos(
            assets: [],
            currentIndex: 0,
            preloadCount: 3,
            size: .preview
        )

        #expect(manager.activeTaskCount == 0)
    }

    @Test
    func `preloading with an invalid current index returns immediately without creating a reversed range`() async {
        let manager = AssetsDownloadManager()
        let assets = [makeAsset(id: "asset-a")]

        await manager.preloadPhotos(
            assets: assets,
            currentIndex: 5,
            preloadCount: 3,
            size: .preview
        )

        #expect(manager.activeTaskCount == 0)
    }

    @Test
    func `makeKeepIds returns an empty set for an invalid current index`() {
        let viewModel = SlideShowViewModel(source: .random)
        viewModel.overwritePlaybackPoolWithoutResetForTesting([makeAsset(id: "asset-a")])

        let keepIds = viewModel.makeKeepIds(currentIndex: 5)

        #expect(keepIds.isEmpty)
    }

    @Test
    func `SDWebImage bridge cancellation resumes the waiting continuation and cancels the underlying download`() async {

        let bridge = SDWebImageAsyncBridge<String>(fallbackValue: "cancelled")
        let operation = FakeSDWebImageOperation()

        let value = await withCheckedContinuation { continuation in
            bridge.setContinuation(continuation)
            bridge.setOperation(operation)
            bridge.cancelAndResume()
        }

        #expect(value == "cancelled")
        #expect(operation.cancelCallCount == 1)
    }

    #if DEBUG
    @Test
    func `loadPhoto on an already ready photo short-circuits without entering the request lifecycle`() async {
        let manager = AssetsDownloadManager()
        let assetId = "asset-ready"
        manager.assetStates[assetId] = .readyToPlay
        manager.resetPlaybackImageRequestLifecycleDiagnostics(isEnabled: true)

        await manager.loadPhoto(assetId: assetId, size: .fullsize, priority: .high)

        let summary = manager.playbackImageRequestLifecycleSummary()
        #expect(summary.counter(for: .assetManagerLoadPhoto).requestCount == 0)
        #expect(manager.activeTaskCount == 0)
    }

    @Test
    func `a high priority request reuses an in-flight low priority task with the same key instead of restarting it`()
        async
    {
        let manager = AssetsDownloadManager()
        let assetId = "asset-in-flight"
        manager.resetPlaybackImageRequestLifecycleDiagnostics(isEnabled: true)
        let seededTask = manager.seedRunningPhotoLoadForTesting(
            assetId: assetId,
            size: .fullsize,
            priority: .low
        )

        let highPriorityRequestTask = Task {
            await manager.loadPhoto(assetId: assetId, size: .fullsize, priority: .high)
        }
        await Task.yield()

        let summary = manager.playbackImageRequestLifecycleSummary()
        #expect(summary.counter(for: .assetManagerLoadPhoto).inFlightReusedCount == 1)
        #expect(summary.counter(for: .assetManagerLoadPhoto).canceledCount == 0)
        #expect(manager.runningPhotoLoadPriorityForTesting(assetId: assetId, size: .fullsize) == .high)

        seededTask.cancel()
        await highPriorityRequestTask.value
        manager.clearSeededRunningPhotoLoadForTesting(assetId: assetId, size: .fullsize)
    }

    @Test
    func `the debug legacy priority upgrade flag restores the old cancel and restart behavior`() async {
        let manager = AssetsDownloadManager(environment: [
            "IMMICHSLIDES_PLAYBACK_REQUEST_LIFECYCLE_LEGACY_PRIORITY_UPGRADE": "1"
        ])
        let assetId = "asset-legacy-priority-upgrade"
        manager.resetPlaybackImageRequestLifecycleDiagnostics(isEnabled: true)
        manager.assetURLs[assetId] = URL(fileURLWithPath: "/tmp/immichslides-missing-\(UUID().uuidString).jpg")
        let seededTask = manager.seedRunningPhotoLoadForTesting(
            assetId: assetId,
            size: .fullsize,
            priority: .low
        )

        await manager.loadPhoto(assetId: assetId, size: .fullsize, priority: .high)

        let summary = manager.playbackImageRequestLifecycleSummary()
        #expect(seededTask.isCancelled)
        #expect(summary.counter(for: .assetManagerLoadPhoto).canceledCount == 1)
        #expect(summary.counter(for: .assetManagerLoadPhoto).inFlightReusedCount == 0)
        manager.clearSeededRunningPhotoLoadForTesting(assetId: assetId, size: .fullsize)
    }

    @Test
    func `canceling expired tasks clears the latest lifecycle request mapping`() {
        let manager = AssetsDownloadManager()
        let assetId = "asset-expired-lifecycle"
        manager.resetPlaybackImageRequestLifecycleDiagnostics(isEnabled: true)
        _ = manager.seedRunningPhotoLoadForTesting(
            assetId: assetId,
            size: .fullsize,
            priority: .low
        )
        let requestId = manager.recordRendererImageRequestForDiagnostics(
            source: .rendererSingleFullsize,
            assetId: assetId,
            size: .fullsize,
            mode: .single,
            role: .current,
            navigationToken: UUID(),
            sceneId: "scene-expired",
            url: URL(string: "https://example.invalid/\(assetId).jpg")!,
            contextHash: "context-expired"
        )

        #expect(manager.latestLifecycleRequestIdForTesting(assetId: assetId, size: .fullsize) == requestId)

        manager.cancelExpiredTasks(keepAssetIds: [])

        #expect(manager.latestLifecycleRequestIdForTesting(assetId: assetId, size: .fullsize) == nil)
        manager.clearSeededRunningPhotoLoadForTesting(assetId: assetId, size: .fullsize)
    }

    @Test
    func `loadPhoto completion clears the latest lifecycle request mapping`() async {
        let manager = AssetsDownloadManager()
        let assetId = "asset-completed-lifecycle"
        manager.resetPlaybackImageRequestLifecycleDiagnostics(isEnabled: true)
        manager.assetURLs[assetId] = URL(fileURLWithPath: "/tmp/immichslides-missing-\(UUID().uuidString).jpg")

        await manager.loadPhoto(assetId: assetId, size: .fullsize, priority: .high)

        #expect(manager.latestLifecycleRequestIdForTesting(assetId: assetId, size: .fullsize) == nil)
    }

    @Test
    func `active task count changes arrive after the new count is stored`() async {
        let manager = AssetsDownloadManager()
        let assetId = "asset-active-count-change"
        var emittedCounts: [Int] = []
        var storedCounts: [Int] = []
        let subscription = manager.activeTaskCountChanges.sink { count in
            emittedCounts.append(count)
            storedCounts.append(manager.activeTaskCount)
        }
        defer { subscription.cancel() }

        _ = manager.seedRunningPhotoLoadForTesting(assetId: assetId, size: .fullsize, priority: .low)
        #expect(await waitUntil(pollInterval: .milliseconds(10)) { emittedCounts.count == 1 })
        manager.clearSeededRunningPhotoLoadForTesting(assetId: assetId, size: .fullsize)
        #expect(await waitUntil(pollInterval: .milliseconds(10)) { emittedCounts.count == 2 })

        #expect(emittedCounts == [1, 0])
        #expect(storedCounts == [1, 0])
    }
    #endif

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

    private final class FakeSDWebImageOperation: NSObject, SDWebImageOperation {
        private(set) var cancelCallCount = 0

        func cancel() {
            cancelCallCount += 1
        }
    }
}
