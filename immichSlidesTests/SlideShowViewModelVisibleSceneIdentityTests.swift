//
//  SlideShowViewModelVisibleSceneIdentityTests.swift
//  immichSlidesTests
//
//  After switching to the next photo, a late load of the previous one must not write the old asset back
//  into the visible scene. The old hook cases only record the hook-bypass path; they do not count as
//  coverage of the real loadPhoto.
//

import CryptoKit
import Foundation
import SDWebImage
import Testing
import UIKit
@testable import immichSlides

@MainActor
@Suite(.serialized, .sharedPlaybackRuntimeIsolation)
struct SlideShowViewModelVisibleSceneIdentityTests {

    @Test
    func `a late load completing for the previous asset after switching to B does not revert identity to A`()
        async throws
    {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.transitionWindowPreloadHookForTesting = { _, _, _ in }

        let urlA = URL(fileURLWithPath: "/tmp/immichslides-visible-scene-asset-a.jpg")
        let urlB = URL(fileURLWithPath: "/tmp/immichslides-visible-scene-asset-b.jpg")
        let assets = [
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b")
        ]
        vm.loadAssetsHookForTesting = { _ in assets }
        setCachedURL(urlB, assetId: "asset-b", size: .fullsize, in: vm.downloadManager)

        var finishStaleLoadForA: CheckedContinuation<Void, Never>?
        // Once released, a late hook call must not park: nothing would resume it.
        var isStaleLoadReleased = false
        vm.initialPhotoLoadHookForTesting = { assetId in
            if assetId == "asset-a", finishStaleLoadForA == nil, !isStaleLoadReleased {
                await withCheckedContinuation { pending in
                    finishStaleLoadForA = pending
                }
            }
            setCachedURL(urlA, assetId: "asset-a", size: .fullsize, in: vm.downloadManager)
            vm.downloadManager.assetStates["asset-a"] = .readyToPlay
            vm.downloadManager.assetPreviewStates["asset-a"] = .readyToPlay
        }
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            let url = assetId == "asset-a" ? urlA : urlB
            setCachedURL(url, assetId: assetId, size: size, in: vm.downloadManager)
            markReady(assetId: assetId, size: size, in: vm.downloadManager)
        }

        #if DEBUG
        _ = vm.downloadManager.seedRunningPhotoLoadForTesting(
            assetId: "asset-a",
            size: .fullsize,
            priority: .high
        )
        defer {
            vm.downloadManager.clearSeededRunningPhotoLoadForTesting(
                assetId: "asset-a",
                size: .fullsize
            )
        }
        #endif

        let firstPreloadTask = Task {
            await vm.firstPreload()
        }
        // On assertion failure, release the hold first so firstPreload does not hang on the continuation.
        defer {
            isStaleLoadReleased = true
            finishStaleLoadForA?.resume()
            finishStaleLoadForA = nil
            firstPreloadTask.cancel()
        }
        // Shared 30 s deadline; this file's 1 s default loses to main-actor stalls from parallel suites.
        let didHoldStaleA = await waitUntil(pollInterval: .milliseconds(2)) {
            finishStaleLoadForA != nil && vm.safeCurrentScene?.primaryAssetId == "asset-a"
        }
        try #require(didHoldStaleA)
        completeCurrentScenePresentation(vm)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-a")

        vm.requestNextScene()
        completeCurrentScenePresentation(vm)

        let visibleSceneAfterNext = vm.safeCurrentScene
        #expect(visibleSceneAfterNext?.primaryAssetId == "asset-b")
        let sceneIdentityAfterNext = visibleSceneAfterNext?.id
        #expect(sceneIdentityAfterNext != nil)

        isStaleLoadReleased = true
        if let pending = finishStaleLoadForA {
            finishStaleLoadForA = nil
            pending.resume()
        }
        await firstPreloadTask.value

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-b")
        #expect(vm.safeCurrentScene?.id == sceneIdentityAfterNext)
        #expect(vm.downloadManager.findURL(assetId: "asset-b", size: .fullsize) != urlA)
        #expect(vm.downloadManager.findURL(assetId: "asset-a", size: .fullsize) == urlA)
    }

    @Test
    func `a request from the real loadPhoto path is intercepted by the local fixture, not a hook bypass`() async throws
    {
        try await runRealPathProbe { fixture, assetId in
            await AssetsDownloadManager.shared.loadPhoto(assetId: assetId, size: .fullsize, priority: .high)
            #expect(fixture.enteredCount(assetId: assetId) > 0)
            #expect(fixture.completedCount(assetId: assetId) > 0)
            #expect(AssetsDownloadManager.shared.isReady(assetId: assetId, size: .fullsize))
        }
    }

    @Test
    func `stub save success does not mean the singleton read the key before reload sends the test key only`()
        async throws
    {
        try await ServerConfigurationTestIsolation.run {
            let fixture = LateLoadLocalHTTPFixture()
            defer {
                fixture.releaseAll()
                fixture.stop()
            }
            try await fixture.start()
            #expect(fixture.isListeningOnLoopbackOnly)
            #expect(fixture.boundHost == LateLoadRealPathFixture.loopbackHost)
            #expect(fixture.isUsingSystemAssignedPort)
            #expect(fixture.port > 0)

            ImmichServer.clearSavedConfiguration()
            ImmichAPIService.shared.reloadServerConfiguration()
            let keyBeforeSave = ImmichAPIService.shared.getApiKey() ?? ""

            var didStubWriterRun = false
            let server = ImmichServer(
                immichURL: ImmichServer.normalizeServerURL(
                    "http://\(LateLoadRealPathFixture.loopbackHost):\(fixture.port)"
                ),
                immichApiKey: LateLoadRealPathFixture.fixtureCredential
            )
            let didSave = server.save { _ in
                didStubWriterRun = true
                return true
            }
            #expect(didSave)
            #expect(didStubWriterRun)
            // Compute the Bool first so #expect does not expand the environment key or the getApiKey() literal.
            let isKeyUnchangedAfterStubSave =
                (ImmichAPIService.shared.getApiKey() ?? "") == keyBeforeSave
            #expect(isKeyUnchangedAfterStubSave)

            ImmichAPIService.shared.reloadServerConfiguration()
            #expect(isLoadedKeyFixtureCredential())
            if let envKey = ProcessInfo.processInfo.environment["IMMICH_TEST_API_KEY"], !envKey.isEmpty {
                let isUsingEnvironmentKey = ImmichAPIService.shared.getApiKey() == envKey
                #expect(!isUsingEnvironmentKey)
            }
            if let loadedURL = ImmichServer.load()?.immichURL {
                #expect(loadedURL.contains("\(LateLoadRealPathFixture.loopbackHost):\(fixture.port)"))
            } else {
                Issue.record("Test server URL still cannot be read after reload")
            }

            let assetId = "late-load-auth-\(UUID().uuidString)"
            prepareRealLoadPhoto(assetId: assetId, port: fixture.port)
            await AssetsDownloadManager.shared.loadPhoto(assetId: assetId, size: .fullsize, priority: .high)

            let recorded = fixture.completedRequests()
            #expect(!recorded.isEmpty)
            let isEveryHostLoopback = recorded.allSatisfy { request in
                (request.host ?? "").hasPrefix(LateLoadRealPathFixture.loopbackHost)
            }
            #expect(isEveryHostLoopback)
            let didSeeFixtureCredential = recorded.contains { $0.apiKey == LateLoadRealPathFixture.fixtureCredential }
            #expect(didSeeFixtureCredential)
            let hasNoForeignCredential = !recorded.contains { request in
                guard let apiKey = request.apiKey, !apiKey.isEmpty else { return false }
                return apiKey != LateLoadRealPathFixture.fixtureCredential
            }
            #expect(hasNoForeignCredential)
        }
    }

    @Test
    func `interception still works after AssetsDownloadManager and SDWebImage singletons are already initialized`()
        async throws
    {
        _ = AssetsDownloadManager.shared
        _ = SDWebImageManager.shared
        _ = SDWebImageDownloader.shared
        _ = ImmichAPIService.shared
        try await runRealPathProbe { fixture, assetId in
            await AssetsDownloadManager.shared.loadPhoto(assetId: assetId, size: .fullsize, priority: .high)
            #expect(fixture.enteredCount(assetId: assetId) > 0)
            #expect(fixture.completedCount(assetId: assetId) > 0)
        }
    }

    @Test
    func
        `releasing a pending real request for A after B becomes current keeps identity on B without A polluting its URL`()
        async throws
    {
        try await ServerConfigurationTestIsolation.run {
            let fixture = LateLoadLocalHTTPFixture()
            var firstPreloadTask: Task<Void, Never>?
            do {
                try await fixture.start()
                #expect(fixture.isListeningOnLoopbackOnly)
                let didInstall = LateLoadRealPathTestSupport.installIsolatedFixtureServer(
                    port: fixture.port,
                    credential: LateLoadRealPathFixture.fixtureCredential
                )
                #expect(didInstall)
                #expect(isLoadedKeyFixtureCredential())

                let assetA = "late-load-real-a-\(UUID().uuidString)"
                let assetB = "late-load-real-b-\(UUID().uuidString)"
                if let jpegA = LateLoadLocalHTTPFixture.makeJPEG(red: 0.9, green: 0.1, blue: 0.1) {
                    fixture.setJPEG(jpegA, for: assetA)
                }
                if let jpegB = LateLoadLocalHTTPFixture.makeJPEG(red: 0.1, green: 0.2, blue: 0.9) {
                    fixture.setJPEG(jpegB, for: assetB)
                }
                fixture.hold(assetIds: [assetA])

                let urlA = try #require(
                    LateLoadRealPathFixture.thumbnailURL(port: fixture.port, assetId: assetA, size: .fullsize)
                )
                let urlB = try #require(
                    LateLoadRealPathFixture.thumbnailURL(port: fixture.port, assetId: assetB, size: .fullsize)
                )
                LateLoadRealPathTestSupport.resetDownloadManager(AssetsDownloadManager.shared)
                LateLoadRealPathTestSupport.clearImageCache(for: [urlA, urlB])

                let vm = SlideShowViewModel(source: .random)
                vm.scenePresentationTimestampProviderForTesting = { 0 }
                vm.backgroundPreloadHookForTesting = { _, _, _ in }
                vm.transitionWindowPreloadHookForTesting = { _, _, _ in }
                vm.loadAssetsHookForTesting = { _ in
                    [self.makeAsset(id: assetA), self.makeAsset(id: assetB)]
                }

                firstPreloadTask = Task {
                    await vm.firstPreload()
                }
                let didHoldA = await waitUntilForTesting {
                    fixture.enteredCount(assetId: assetA) > 0 && vm.safeCurrentScene?.primaryAssetId == assetA
                }
                try #require(didHoldA)
                #expect(fixture.completedCount(assetId: assetA) == 0)

                completeCurrentScenePresentation(vm)
                vm.requestNextScene()

                let didFinishB = await fixture.waitUntilCompleted(assetId: assetB)
                try #require(didFinishB)
                let didBecomeReadyB = await waitUntilForTesting {
                    vm.downloadManager.isReady(assetId: assetB, size: .fullsize)
                }
                try #require(didBecomeReadyB, "B not ready; stop the test, do not go on to synthesize the presentation")
                completeCurrentScenePresentation(vm)

                let visibleAfterNext = vm.safeCurrentScene
                #expect(visibleAfterNext?.primaryAssetId == assetB)
                let sceneIdentityAfterNext = visibleAfterNext?.id
                #expect(sceneIdentityAfterNext != nil)

                fixture.release(assetId: assetA)
                if let firstPreloadTask {
                    await firstPreloadTask.value
                }
                let didFinishLoadPhotoA = vm.downloadManager.isReady(assetId: assetA, size: .fullsize)
                #expect(didFinishLoadPhotoA)

                #expect(fixture.enteredCount(assetId: assetA) > 0)
                #expect(fixture.completedCount(assetId: assetA) > 0)
                #expect(fixture.enteredCount(assetId: assetB) > 0)
                #expect(fixture.completedCount(assetId: assetB) > 0)
                #expect(vm.safeCurrentScene?.primaryAssetId == assetB)
                #expect(vm.safeCurrentScene?.id == sceneIdentityAfterNext)
                #expect(vm.downloadManager.findURL(assetId: assetB, size: .fullsize) != urlA)
                #expect(vm.downloadManager.findURL(assetId: assetB, size: .fullsize) == urlB)
                #expect(vm.downloadManager.findURL(assetId: assetA, size: .fullsize) == urlA)
                fixture.releaseAll()
                fixture.stop()
            } catch {
                // Release the hold before waiting for the Task, so it does not stay parked on the fixture continuation
                // after cancel.
                fixture.releaseAll()
                firstPreloadTask?.cancel()
                if let firstPreloadTask {
                    await firstPreloadTask.value
                }
                fixture.stop()
                throw error
            }
        }
    }

    @Test
    func `current scene B completing its own load keeps identity on B and findURL for B returns B's URL`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.transitionWindowPreloadHookForTesting = { _, _, _ in }

        let urlA = URL(fileURLWithPath: "/tmp/immichslides-visible-scene-current-a.jpg")
        let urlB = URL(fileURLWithPath: "/tmp/immichslides-visible-scene-current-b.jpg")
        let assets = [
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b")
        ]
        setCachedURL(urlA, assetId: "asset-a", size: .fullsize, in: vm.downloadManager)
        setCachedURL(urlB, assetId: "asset-b", size: .fullsize, in: vm.downloadManager)
        markReady(assetId: "asset-a", size: .fullsize, in: vm.downloadManager)
        markReady(assetId: "asset-a", size: .preview, in: vm.downloadManager)

        var finishCurrentLoadForB: CheckedContinuation<Void, Never>?
        vm.indexChangePhotoLoadHookForTesting = { assetId, size in
            if assetId == "asset-b", size == .fullsize, finishCurrentLoadForB == nil {
                await withCheckedContinuation { pending in
                    finishCurrentLoadForB = pending
                }
            }
            let url = assetId == "asset-a" ? urlA : urlB
            setCachedURL(url, assetId: assetId, size: size, in: vm.downloadManager)
            markReady(assetId: assetId, size: size, in: vm.downloadManager)
        }

        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-a")

        vm.requestNextScene()
        let visibleSceneAfterNext = vm.safeCurrentScene
        #expect(visibleSceneAfterNext?.primaryAssetId == "asset-b")
        let sceneIdentityAfterNext = visibleSceneAfterNext?.id
        #expect(sceneIdentityAfterNext != nil)

        _ = await waitUntilForTesting { finishCurrentLoadForB != nil }
        finishCurrentLoadForB?.resume()
        completeCurrentScenePresentation(vm)

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-b")
        #expect(vm.safeCurrentScene?.id == sceneIdentityAfterNext)
        #expect(vm.downloadManager.findURL(assetId: "asset-b", size: .fullsize) == urlB)
        #expect(vm.downloadManager.findURL(assetId: "asset-b", size: .fullsize) != urlA)
    }

    @Test
    func
        `on iPad after a stable pause the visible photo, overlay owner, and EXIF agree, and empty-EXIF A2 never borrows fixture 3`()
        async throws
    {
        // Locks the ViewModel overlay owner and visible scene; the view's retainedExifOverlayAsset remains unverified.
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.transitionWindowPreloadHookForTesting = { _, _, _ in }
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }

        let assets = makeFixtureSetAAssets()
        markReady(assets, in: vm.downloadManager)
        let iPadPortrait = PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(
                width: Self.iPadPortraitPlanningWidthPoints,
                height: Self.iPadPortraitPlanningHeightPoints
            ),
            profile: .iPad,
            orientation: .portrait
        )
        vm.updateSmartFillSurface(iPadPortrait, protectionSnapshot: PlaybackProtectionSnapshot(regions: []))
        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)

        advanceUntilVisible(vm, assetId: "asset-a-2", maximumSteps: Self.fixtureAdvanceStepLimit)
        completeCurrentScenePresentation(vm)

        let controlBarProtection = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.controlBar(
                    rect: PlaybackProtectionRect(
                        x: 0,
                        y: Self.controlBarNormalizedMinY,
                        width: 1,
                        height: Self.controlBarNormalizedHeight
                    ),
                    activeConditionSummary: "visible"
                ))
        ])
        vm.updateSmartFillSurface(iPadPortrait, protectionSnapshot: controlBarProtection)
        await Task.yield()
        completeCurrentScenePresentation(vm)

        let visibleImageId = vm.visibleImageAssetId
        let overlayOwnerId = vm.visibleOverlayState?.ownerPrimaryAssetId
        let overlayAsset = vm.visibleOverlayAsset
        let slotIds = vm.safeCurrentScene?.photoSlots.map(\.asset.id) ?? []

        #expect(visibleImageId == "asset-a-2")
        #expect(overlayOwnerId == "asset-a-2")
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-a-2")
        #expect(slotIds.contains("asset-a-2"))
        #expect(overlayAsset?.id == "asset-a-2")
        #expect(overlayAsset?.exifInfo?.model != "Fixture 3")
        #expect(overlayAsset?.exifInfo?.make == nil)
        #expect(overlayAsset?.exifInfo?.model == nil)
    }

    @Test
    func
        `with stale batch order A1 A3 A4 held before A2 plans, a stable pause on visible A2 never borrows fixture 3 owner`()
        async throws
    {
        // When A3 and A4 complete first, the visible layer must stay A2 and must not take A3 as owner.
        try await ServerConfigurationTestIsolation.run {
            let fixture = LateLoadLocalHTTPFixture()
            var firstPreloadTask: Task<Void, Never>?
            do {
                try await fixture.start()
                #expect(fixture.isListeningOnLoopbackOnly)
                let didInstall = LateLoadRealPathTestSupport.installIsolatedFixtureServer(
                    port: fixture.port,
                    credential: LateLoadRealPathFixture.fixtureCredential
                )
                #expect(didInstall)
                #expect(isLoadedKeyFixtureCredential())

                let assets = makeFixtureSetAAssets()
                let assetIds = assets.map(\.id)
                for asset in assets {
                    if let jpeg = LateLoadLocalHTTPFixture.makeJPEG(red: 0.2, green: 0.4, blue: 0.8) {
                        fixture.setJPEG(jpeg, for: asset.id)
                    }
                }

                fixture.hold(assetIds: ["asset-a-2", "asset-a-3", "asset-a-4", "asset-a-5"])

                let cacheURLs = assetIds.flatMap { assetId in
                    [ThumbnailSize.fullsize, .preview, .thumbnail].compactMap {
                        LateLoadRealPathFixture.thumbnailURL(port: fixture.port, assetId: assetId, size: $0)
                    }
                }
                LateLoadRealPathTestSupport.resetDownloadManager(AssetsDownloadManager.shared)
                LateLoadRealPathTestSupport.clearImageCache(for: cacheURLs)

                let iPadPortrait = PlaybackSmartFillSurface(
                    pixelSize: PlaybackPlanningPixelSize(
                        width: Self.iPadPortraitPlanningWidthPoints,
                        height: Self.iPadPortraitPlanningHeightPoints
                    ),
                    profile: .iPad,
                    orientation: .portrait
                )
                let vm = SlideShowViewModel(source: .random)
                vm.scenePresentationTimestampProviderForTesting = { 0 }
                vm.backgroundPreloadHookForTesting = { _, _, _ in }
                vm.transitionWindowPreloadHookForTesting = { _, _, _ in }
                vm.loadAssetsHookForTesting = { _ in assets }
                vm.updateSmartFillSurface(
                    iPadPortrait,
                    protectionSnapshot: PlaybackProtectionSnapshot(regions: [])
                )

                firstPreloadTask = Task {
                    await vm.firstPreload()
                }

                try await releaseAndWaitCompleted(
                    assetId: "asset-a-1",
                    fixture: fixture,
                    manager: vm.downloadManager
                )
                try await releaseAndWaitCompleted(
                    assetId: "asset-a-3",
                    fixture: fixture,
                    manager: vm.downloadManager
                )
                try await releaseAndWaitCompleted(
                    assetId: "asset-a-4",
                    fixture: fixture,
                    manager: vm.downloadManager
                )

                let completedBeforeA2 = firstCompletedAssetOrder(
                    fixture,
                    among: ["asset-a-1", "asset-a-3", "asset-a-4"]
                )
                #expect(completedBeforeA2 == ["asset-a-1", "asset-a-3", "asset-a-4"])
                try #require(
                    fixture.completedCount(assetId: "asset-a-2") == 0,
                    "A2 completed before release; the fixture did not hold it"
                )

                completeCurrentScenePresentation(vm)
                advanceUntilVisibleImage(vm, assetId: "asset-a-2", maximumSteps: Self.fixtureAdvanceStepLimit)

                try await releaseAndWaitCompleted(
                    assetId: "asset-a-2",
                    fixture: fixture,
                    manager: vm.downloadManager
                )
                completeCurrentScenePresentation(vm)

                let controlBarProtection = PlaybackProtectionSnapshot(regions: [
                    try #require(
                        PlaybackProtectionRegion.controlBar(
                            rect: PlaybackProtectionRect(
                                x: 0,
                                y: Self.controlBarNormalizedMinY,
                                width: 1,
                                height: Self.controlBarNormalizedHeight
                            ),
                            activeConditionSummary: "visible"
                        ))
                ])
                vm.updateSmartFillSurface(iPadPortrait, protectionSnapshot: controlBarProtection)
                await Task.yield()
                completeCurrentScenePresentation(vm)

                let visibleImageId = vm.visibleImageAssetId
                let overlayOwnerId = vm.visibleOverlayState?.ownerPrimaryAssetId
                let overlayAsset = vm.visibleOverlayAsset
                let primaryId = vm.safeCurrentScene?.primaryAssetId
                let slotIds = vm.safeCurrentScene?.photoSlots.map(\.asset.id) ?? []
                let sceneType = vm.safeCurrentScene?.smartFillReadback?.sceneType
                let probe = oldOrderProbe(
                    visibleImageId: visibleImageId,
                    overlayOwnerId: overlayOwnerId,
                    overlayAsset: overlayAsset,
                    primaryId: primaryId,
                    slotIds: slotIds,
                    sceneType: sceneType
                )

                #expect(visibleImageId == "asset-a-2", "\(probe)")
                #expect(overlayOwnerId == "asset-a-2", "\(probe)")
                #expect(primaryId == "asset-a-2", "\(probe)")
                #expect(overlayAsset?.id == "asset-a-2", "\(probe)")
                #expect(overlayAsset?.exifInfo?.model != "Fixture 3", "\(probe)")
                #expect(overlayAsset?.exifInfo?.make == nil, "\(probe)")
                #expect(overlayAsset?.exifInfo?.model == nil, "\(probe)")

                fixture.releaseAll()
                if let firstPreloadTask {
                    await firstPreloadTask.value
                }
                fixture.stop()
            } catch {
                fixture.releaseAll()
                firstPreloadTask?.cancel()
                if let firstPreloadTask {
                    await firstPreloadTask.value
                }
                fixture.stop()
                throw error
            }
        }
    }

    @Test
    func `pause hold after visible A2 and completed A3 keeps decoded size, view model ids, and overlay model on A2`()
        async throws
    {
        // Covers only the pause hold after A2 is visible and A3 has completed; the out-of-order
        // completion variant is `with stale batch order A1 A3 A4 held before A2 plans, a stable
        // pause on visible A2 never borrows fixture 3 owner`.
        try await ServerConfigurationTestIsolation.run {
            let fixture = LateLoadLocalHTTPFixture()
            var firstPreloadTask: Task<Void, Never>?
            do {
                try await fixture.start()
                #expect(fixture.isListeningOnLoopbackOnly)
                let didInstall = LateLoadRealPathTestSupport.installIsolatedFixtureServer(
                    port: fixture.port,
                    credential: LateLoadRealPathFixture.fixtureCredential
                )
                #expect(didInstall)
                #expect(isLoadedKeyFixtureCredential())

                let assets = makeFixtureSetAAssets()
                let assetIds = assets.map(\.id)
                let pngByAssetId = try loadFixtureSetAPNGs(assetIds: assetIds)
                let pngA2 = try #require(pngByAssetId["asset-a-2"])
                let pngA3 = try #require(pngByAssetId["asset-a-3"])
                #expect(sha256Hex(pngA2) == Self.fixtureSetAA2PNGSHA256)
                #expect(sha256Hex(pngA3) == Self.fixtureSetAA3PNGSHA256)
                for asset in assets {
                    let png = try #require(pngByAssetId[asset.id])
                    #expect(png.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))
                    fixture.setJPEG(png, for: asset.id)
                }

                fixture.hold(assetIds: ["asset-a-3", "asset-a-4", "asset-a-5"])

                let cacheURLs = assetIds.flatMap { assetId in
                    [ThumbnailSize.fullsize, .preview, .thumbnail].compactMap {
                        LateLoadRealPathFixture.thumbnailURL(port: fixture.port, assetId: assetId, size: $0)
                    }
                }
                LateLoadRealPathTestSupport.resetDownloadManager(AssetsDownloadManager.shared)
                LateLoadRealPathTestSupport.clearImageCache(for: cacheURLs)

                let iPadPortrait = PlaybackSmartFillSurface(
                    pixelSize: PlaybackPlanningPixelSize(
                        width: Self.iPadPortraitPlanningWidthPoints,
                        height: Self.iPadPortraitPlanningHeightPoints
                    ),
                    profile: .iPad,
                    orientation: .portrait
                )
                let vm = SlideShowViewModel(source: .random)
                vm.scenePresentationTimestampProviderForTesting = { 0 }
                vm.backgroundPreloadHookForTesting = { _, _, _ in }
                vm.transitionWindowPreloadHookForTesting = { _, _, _ in }
                vm.loadAssetsHookForTesting = { _ in assets }
                vm.updateSmartFillSurface(
                    iPadPortrait,
                    protectionSnapshot: PlaybackProtectionSnapshot(regions: [])
                )

                firstPreloadTask = Task {
                    await vm.firstPreload()
                }

                try await releaseAndWaitCompleted(
                    assetId: "asset-a-1",
                    fixture: fixture,
                    manager: vm.downloadManager
                )
                completeCurrentScenePresentation(vm)

                try await releaseAndWaitCompleted(
                    assetId: "asset-a-2",
                    fixture: fixture,
                    manager: vm.downloadManager
                )
                completeCurrentScenePresentation(vm)
                advanceUntilVisibleImage(vm, assetId: "asset-a-2", maximumSteps: Self.fixtureAdvanceStepLimit)

                try #require(
                    vm.visibleImageAssetId == "asset-a-2",
                    "A2 is not on screen yet; cannot release A3"
                )
                try #require(
                    fixture.completedCount(assetId: "asset-a-3") == 0,
                    "A3 completed before A2 became visible; this is not the intended timeline"
                )

                try await releaseAndWaitCompleted(
                    assetId: "asset-a-3",
                    fixture: fixture,
                    manager: vm.downloadManager
                )

                let controlBarProtection = PlaybackProtectionSnapshot(regions: [
                    try #require(
                        PlaybackProtectionRegion.controlBar(
                            rect: PlaybackProtectionRect(
                                x: 0,
                                y: Self.controlBarNormalizedMinY,
                                width: 1,
                                height: Self.controlBarNormalizedHeight
                            ),
                            activeConditionSummary: "visible"
                        ))
                ])
                vm.updateSmartFillSurface(iPadPortrait, protectionSnapshot: controlBarProtection)
                await Task.yield()
                completeCurrentScenePresentation(vm)

                let visibleImageId = vm.visibleImageAssetId
                let overlayOwnerId = vm.visibleOverlayState?.ownerPrimaryAssetId
                let overlayAsset = vm.visibleOverlayAsset
                let primaryId = vm.safeCurrentScene?.primaryAssetId
                let a2Decode = decodedPixelSize(assetId: "asset-a-2", port: fixture.port)
                let a3Decode = decodedPixelSize(assetId: "asset-a-3", port: fixture.port)
                let probe = pauseHoldProbe(
                    visibleImageId: visibleImageId,
                    overlayOwnerId: overlayOwnerId,
                    overlayAsset: overlayAsset,
                    primaryId: primaryId,
                    a2Decode: a2Decode,
                    a3Decode: a3Decode
                )

                #expect(a2Decode?.width == 180 && a2Decode?.height == 320, "\(probe)")
                #expect(a3Decode?.width == 300 && a3Decode?.height == 300, "\(probe)")
                #expect(visibleImageId == "asset-a-2", "\(probe)")
                #expect(overlayOwnerId == "asset-a-2", "\(probe)")
                #expect(primaryId == "asset-a-2", "\(probe)")
                #expect(overlayAsset?.id == "asset-a-2", "\(probe)")
                #expect(overlayAsset?.exifInfo?.model != "Fixture 3", "\(probe)")
                #expect(overlayAsset?.exifInfo?.make == nil, "\(probe)")
                #expect(overlayAsset?.exifInfo?.model == nil, "\(probe)")

                fixture.releaseAll()
                if let firstPreloadTask {
                    await firstPreloadTask.value
                }
                fixture.stop()
            } catch {
                fixture.releaseAll()
                firstPreloadTask?.cancel()
                if let firstPreloadTask {
                    await firstPreloadTask.value
                }
                fixture.stop()
                throw error
            }
        }
    }

    @Test
    func
        `pausing an automatic transition while only the translucent outgoing layer is visible keeps visibleOverlayAsset on A2`()
        throws
    {
        // When not paused and only the outgoing layer is visible, EXIF follows the still-visible old photo A2;
        // after pausing in the same window it is still A2.
        let suiteName = "SlideShowViewModelVisibleSceneIdentity.pausedOutgoingExif.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = PlaybackSettingsStore(
            key: "playbackSettings.visibleSceneIdentity.pausedOutgoingExif",
            defaults: defaults
        )
        store.save(
            PlaybackSettings(
                autoPlayEnabled: true,
                intervalSeconds: Int(SceneLifecycleContract.minimumInterval),
                displayMode: .singlePhoto
            )
        )
        defer {
            store.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let clock = PresentationTestClock()
        let vm = SlideShowViewModel(
            source: .random,
            settingsStore: store,
            observeSettingsChanges: false
        )
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { clock.now }
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        vm.transitionWindowPreloadHookForTesting = { _, _, _ in }

        let assets = Array(makeFixtureSetAAssets().dropFirst())
        markReady(assets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(assets)

        settleIncomingToStableUsingClock(vm, clock: clock)
        try #require(vm.sceneRenderSnapshot.phase == .stablePhoto)
        try #require(vm.safeCurrentScene?.primaryAssetId == "asset-a-2")
        try #require(vm.isAutoPlay)

        clock.now += SceneLifecycleContract.minimumInterval
        let deadline = vm.fireScheduledScenePresentationWakeUpForTesting()
        try #require(deadline != nil)
        clock.now = deadline ?? clock.now
        try #require(vm.sceneRenderSnapshot.phase == .grace)
        try #require(vm.safeCurrentScene?.primaryAssetId == "asset-a-3")

        decodeIncomingRendererForTesting(vm)
        var snapshot = vm.sceneRenderSnapshot
        try #require(snapshot.underlyingPhase == .transition)
        let outgoingAtReady = try #require(snapshot.layers.first { $0.role == .outgoing })
        let incomingAtReady = try #require(snapshot.layers.last { $0.role == .incoming })
        try #require(outgoingAtReady.identity.assetID == "asset-a-2")
        try #require(incomingAtReady.identity.assetID == "asset-a-3")
        try #require(incomingAtReady.isPresentationReady)
        let fadeStart = try #require(incomingAtReady.fadeStartTime)
        try #require(fadeStart > clock.now)

        clock.now += 0.5
        snapshot = vm.sceneRenderSnapshot
        let outgoingBeforePause = try #require(snapshot.layers.first { $0.role == .outgoing })
        let incomingBeforePause = try #require(snapshot.layers.last { $0.role == .incoming })
        try #require(vm.isAutoPlay)
        try #require(snapshot.phase == .transition)
        try #require(outgoingBeforePause.identity.assetID == "asset-a-2")
        try #require(outgoingBeforePause.opacity > 0 && outgoingBeforePause.opacity < 1)
        try #require(incomingBeforePause.identity.assetID == "asset-a-3")
        try #require(incomingBeforePause.opacity == 0)
        #expect(vm.visibleOverlayAsset?.id == "asset-a-2")

        vm.toggleAutoPlayFromUserInteraction()

        snapshot = vm.sceneRenderSnapshot
        let outgoing = try #require(snapshot.layers.first { $0.role == .outgoing })
        let incoming = try #require(snapshot.layers.last { $0.role == .incoming })
        let outgoingScene = try #require(vm.scene(for: outgoing))
        try #require(!vm.isAutoPlay)
        try #require(snapshot.phase == .paused)
        try #require(snapshot.underlyingPhase == .transition)
        try #require(snapshot.suspensionReasons.contains(.userPaused))
        try #require(outgoing.identity.assetID == "asset-a-2")
        try #require(outgoing.opacity > 0 && outgoing.opacity < 1)
        try #require(incoming.identity.assetID == "asset-a-3")
        try #require(incoming.opacity == 0)
        try #require(incoming.isPresentationReady)
        try #require(snapshot.layers.filter { $0.opacity > 0 }.map(\.role) == [.outgoing])
        try #require(outgoingScene.photoSlots.count == 1)
        try #require(outgoingScene.primaryAssetId == "asset-a-2")
        try #require(vm.safeCurrentScene?.primaryAssetId == "asset-a-3")
        try #require(vm.visibleOverlayState?.ownerPrimaryAssetId == "asset-a-3")

        #expect(vm.visibleOverlayAsset?.id == "asset-a-2")
    }

    @Test
    func `resuming auto play after a pause keeps EXIF following the sole visible outgoing photo A2`() throws {
        let clock = PresentationTestClock()
        let harness = makeSinglePhotoAutoplayHarness(suffix: "resumeOutgoingExif", clock: clock)
        defer { harness.tearDown() }

        _ = try startAutomaticA2ToA3ReadyTransition(harness.viewModel, clock: clock)
        clock.now += 0.5
        try #require(harness.viewModel.isAutoPlay)
        harness.viewModel.toggleAutoPlayFromUserInteraction()
        var snapshot = harness.viewModel.sceneRenderSnapshot
        try #require(!harness.viewModel.isAutoPlay)
        try #require(snapshot.layers.filter { $0.opacity > 0 }.map(\.role) == [.outgoing])
        try #require(harness.viewModel.visibleOverlayState?.ownerPrimaryAssetId == "asset-a-3")

        harness.viewModel.toggleAutoPlayFromUserInteraction()
        snapshot = harness.viewModel.sceneRenderSnapshot
        try #require(harness.viewModel.isAutoPlay)
        try #require(snapshot.layers.filter { $0.opacity > 0 }.map(\.role) == [.outgoing])
        try #require(harness.viewModel.visibleOverlayState?.ownerPrimaryAssetId == "asset-a-3")
        #expect(harness.viewModel.visibleOverlayAsset?.id == "asset-a-2")
    }

    @Test
    func `pausing while the incoming layer is already visible keeps visibleOverlayAsset on committed A3`() throws {
        // Once the new photo shows, pausing does not take the sole-outgoing exception. At auto pace outgoing takes 1s
        // and the incoming delay is 1.025s, so the two layers never overlap for long.
        let clock = PresentationTestClock()
        let harness = makeSinglePhotoAutoplayHarness(suffix: "incomingVisibleExif", clock: clock)
        defer { harness.tearDown() }

        let fadeStart = try startAutomaticA2ToA3ReadyTransition(harness.viewModel, clock: clock)
        clock.now = fadeStart + 0.2
        var snapshot = harness.viewModel.sceneRenderSnapshot
        let incoming = try #require(snapshot.layers.last { $0.role == .incoming })
        try #require(incoming.identity.assetID == "asset-a-3")
        try #require(incoming.opacity > 0)
        try #require(snapshot.layers.filter { $0.opacity > 0 }.map(\.role) != [.outgoing])

        harness.viewModel.toggleAutoPlayFromUserInteraction()
        snapshot = harness.viewModel.sceneRenderSnapshot
        try #require(!harness.viewModel.isAutoPlay)
        try #require(snapshot.layers.filter { $0.opacity > 0 }.map(\.role) != [.outgoing])
        try #require(harness.viewModel.visibleOverlayState?.ownerPrimaryAssetId == "asset-a-3")
        #expect(harness.viewModel.visibleOverlayAsset?.id == "asset-a-3")
    }

    @Test
    func `pausing during a black transition frame keeps EXIF on the previously shown photo A2`() throws {
        let clock = PresentationTestClock()
        let harness = makeSinglePhotoAutoplayHarness(suffix: "blackFrameExif", clock: clock)
        defer { harness.tearDown() }

        let fadeStart = try startAutomaticA2ToA3ReadyTransition(harness.viewModel, clock: clock)
        clock.now = fadeStart - 0.01
        var snapshot = harness.viewModel.sceneRenderSnapshot
        try #require(snapshot.layers.filter { $0.opacity > 0 }.isEmpty)

        harness.viewModel.toggleAutoPlayFromUserInteraction()
        snapshot = harness.viewModel.sceneRenderSnapshot
        try #require(!harness.viewModel.isAutoPlay)
        try #require(snapshot.layers.filter { $0.opacity > 0 }.isEmpty)
        try #require(harness.viewModel.visibleOverlayState?.ownerPrimaryAssetId == "asset-a-3")
        #expect(harness.viewModel.visibleOverlayAsset?.id == "asset-a-2")
    }

    @Test
    func
        `when the sole visible outgoing layer is a multi-photo scene, EXIF and display policy still follow that scene`()
        async throws
    {
        let suiteName = "SlideShowViewModelVisibleSceneIdentity.multiPhotoOutgoingExif.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = PlaybackSettingsStore(
            key: "playbackSettings.visibleSceneIdentity.multiPhotoOutgoingExif",
            defaults: defaults
        )
        store.save(
            PlaybackSettings(
                autoPlayEnabled: true,
                intervalSeconds: Int(SceneLifecycleContract.minimumInterval),
                displayMode: .smartFill
            )
        )
        defer {
            store.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let clock = PresentationTestClock()
        let vm = SlideShowViewModel(
            source: .random,
            settingsStore: store,
            observeSettingsChanges: false
        )
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { clock.now }
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        vm.transitionWindowPreloadHookForTesting = { _, _, _ in }
        vm.updateSmartFillSurfaceForTesting(
            PlaybackSmartFillSurface(
                pixelSize: PlaybackPlanningPixelSize(
                    width: Self.iPadPortraitPlanningHeightPoints, height: Self.iPadPortraitPlanningWidthPoints),
                profile: .iPad,
                orientation: .landscape
            )
        )

        let assets =
            [
                makeFixtureAsset(id: "asset-0", width: 1800, height: 2000, exif: nil)
            ]
            + (1...12).map { index in
                makeFixtureAsset(id: "asset-\(index)", width: 200, height: 6000, exif: nil)
            } + [
                makeFixtureAsset(id: "asset-13", width: 1800, height: 2000, exif: nil),
                makeFixtureAsset(id: "asset-14", width: 1800, height: 2000, exif: nil),
                makeFixtureAsset(id: "asset-15", width: 1800, height: 2000, exif: nil)
            ]
        markReady(assets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(assets)
        settleIncomingToStableUsingClock(vm, clock: clock)
        try #require(vm.safeCurrentScene?.photoSlots.count == 2)
        try #require(vm.safeCurrentScene?.photoSlots.map(\.asset.id) == ["asset-0", "asset-13"])
        try #require(vm.isAutoPlay)

        let didPrepareNext = await waitUntilForTesting {
            vm.preparedSmartFillNextAssetIdsForTesting != nil
        }
        try #require(didPrepareNext)
        let tokenBeforeAutoPlay = vm.targetTransitionToken

        clock.now += SceneLifecycleContract.minimumInterval
        var deadline = vm.fireScheduledScenePresentationWakeUpForTesting()
        if vm.targetTransitionToken == tokenBeforeAutoPlay {
            let didPrepareAfterSkippedTick = await waitUntilForTesting {
                vm.preparedSmartFillNextAssetIdsForTesting != nil
            }
            try #require(didPrepareAfterSkippedTick)
            clock.now += SceneLifecycleContract.minimumInterval
            deadline = vm.fireScheduledScenePresentationWakeUpForTesting()
        }
        try #require(deadline != nil)
        clock.now = deadline ?? clock.now
        decodeIncomingRendererForTesting(vm)
        var snapshot = vm.sceneRenderSnapshot
        try #require(snapshot.underlyingPhase == .transition)
        let outgoingAtReady = try #require(snapshot.layers.first { $0.role == .outgoing })
        let incomingAtReady = try #require(snapshot.layers.last { $0.role == .incoming })
        let outgoingSceneAtReady = try #require(vm.scene(for: outgoingAtReady))
        try #require(outgoingSceneAtReady.photoSlots.count == 2)
        try #require(incomingAtReady.isPresentationReady)
        let fadeStart = try #require(incomingAtReady.fadeStartTime)
        try #require(fadeStart > clock.now)

        clock.now += 0.5
        let committedId = try #require(vm.safeCurrentScene?.primaryAssetId)
        try #require(committedId != "asset-0")
        vm.toggleAutoPlayFromUserInteraction()
        snapshot = vm.sceneRenderSnapshot
        let outgoing = try #require(snapshot.layers.first { $0.role == .outgoing })
        let outgoingScene = try #require(vm.scene(for: outgoing))
        try #require(!vm.isAutoPlay)
        try #require(snapshot.layers.filter { $0.opacity > 0 }.map(\.role) == [.outgoing])
        try #require(outgoingScene.photoSlots.count == 2)
        try #require(outgoingScene.primaryAssetId == "asset-0")
        try #require(vm.safeCurrentScene?.primaryAssetId == committedId)
        try #require(vm.visibleOverlayState?.ownerPrimaryAssetId == committedId)
        #expect(vm.visibleOverlayScene?.id == outgoingScene.id)
        #expect(vm.visibleOverlayAsset?.id == "asset-0")
    }

    private func runRealPathProbe(
        _ body: (LateLoadLocalHTTPFixture, String) async throws -> Void
    ) async throws {
        try await ServerConfigurationTestIsolation.run {
            let fixture = LateLoadLocalHTTPFixture()
            defer {
                fixture.releaseAll()
                fixture.stop()
            }
            try await fixture.start()
            #expect(fixture.isListeningOnLoopbackOnly)
            let didInstall = LateLoadRealPathTestSupport.installIsolatedFixtureServer(
                port: fixture.port,
                credential: LateLoadRealPathFixture.fixtureCredential
            )
            #expect(didInstall)
            #expect(isLoadedKeyFixtureCredential())

            let assetId = "late-load-probe-\(UUID().uuidString)"
            prepareRealLoadPhoto(assetId: assetId, port: fixture.port)
            try await body(fixture, assetId)
        }
    }

    private func isLoadedKeyFixtureCredential() -> Bool {
        ImmichAPIService.shared.getApiKey() == LateLoadRealPathFixture.fixtureCredential
    }

    private func prepareRealLoadPhoto(assetId: String, port: UInt16) {
        LateLoadRealPathTestSupport.resetDownloadManager(AssetsDownloadManager.shared)
        let urls = [ThumbnailSize.fullsize, .preview, .thumbnail].compactMap {
            LateLoadRealPathFixture.thumbnailURL(port: port, assetId: assetId, size: $0)
        }
        LateLoadRealPathTestSupport.clearImageCache(for: urls)
    }

    private final class PresentationTestClock {
        var now: TimeInterval = 0
    }

    private struct SinglePhotoAutoplayHarness {
        let viewModel: SlideShowViewModel
        let store: PlaybackSettingsStore
        let defaults: UserDefaults
        let suiteName: String

        // Nested type methods do not inherit the outer suite's @MainActor; clear() runs on the main actor.
        @MainActor
        func tearDown() {
            store.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeSinglePhotoAutoplayHarness(
        suffix: String,
        clock: PresentationTestClock
    ) -> SinglePhotoAutoplayHarness {
        let suiteName = "SlideShowViewModelVisibleSceneIdentity.\(suffix).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = PlaybackSettingsStore(
            key: "playbackSettings.visibleSceneIdentity.\(suffix)",
            defaults: defaults
        )
        store.save(
            PlaybackSettings(
                autoPlayEnabled: true,
                intervalSeconds: Int(SceneLifecycleContract.minimumInterval),
                displayMode: .singlePhoto
            )
        )
        let vm = SlideShowViewModel(
            source: .random,
            settingsStore: store,
            observeSettingsChanges: false
        )
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { clock.now }
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        vm.transitionWindowPreloadHookForTesting = { _, _, _ in }
        let assets = Array(makeFixtureSetAAssets().dropFirst())
        markReady(assets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(assets)
        settleIncomingToStableUsingClock(vm, clock: clock)
        return SinglePhotoAutoplayHarness(
            viewModel: vm,
            store: store,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func startAutomaticA2ToA3ReadyTransition(
        _ vm: SlideShowViewModel,
        clock: PresentationTestClock
    ) throws -> TimeInterval {
        try #require(vm.sceneRenderSnapshot.phase == .stablePhoto)
        try #require(vm.safeCurrentScene?.primaryAssetId == "asset-a-2")
        try #require(vm.isAutoPlay)

        clock.now += SceneLifecycleContract.minimumInterval
        let deadline = vm.fireScheduledScenePresentationWakeUpForTesting()
        try #require(deadline != nil)
        clock.now = deadline ?? clock.now
        try #require(vm.sceneRenderSnapshot.phase == .grace)
        try #require(vm.safeCurrentScene?.primaryAssetId == "asset-a-3")

        decodeIncomingRendererForTesting(vm)
        let snapshot = vm.sceneRenderSnapshot
        try #require(snapshot.underlyingPhase == .transition)
        let outgoingAtReady = try #require(snapshot.layers.first { $0.role == .outgoing })
        let incomingAtReady = try #require(snapshot.layers.last { $0.role == .incoming })
        try #require(outgoingAtReady.identity.assetID == "asset-a-2")
        try #require(incomingAtReady.identity.assetID == "asset-a-3")
        try #require(incomingAtReady.isPresentationReady)
        let fadeStart = try #require(incomingAtReady.fadeStartTime)
        try #require(fadeStart > clock.now)
        return fadeStart
    }

    private func decodeIncomingRendererForTesting(_ vm: SlideShowViewModel) {
        let snapshot = vm.sceneRenderSnapshot
        guard let targetLayer = snapshot.layers.last(where: { $0.role == .incoming }),
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
    }

    private func settleIncomingToStableUsingClock(
        _ vm: SlideShowViewModel,
        clock: PresentationTestClock
    ) {
        decodeIncomingRendererForTesting(vm)
        var snapshot = vm.sceneRenderSnapshot
        if snapshot.phase == .transition,
            snapshot.layers.last(where: { $0.role == .incoming })?.isPresentationReady == false,
            let transitionDeadline = vm.fireScheduledScenePresentationWakeUpForTesting()
        {
            clock.now = transitionDeadline
            snapshot = vm.sceneRenderSnapshot
        }
        guard
            let incoming = snapshot.layers.last(where: {
                $0.role == .incoming && $0.isPresentationReady
            })
        else {
            return
        }
        clock.now = (incoming.fadeStartTime ?? clock.now) + SceneTransitionDiagnostic.firstVisibleTickOffsetSeconds
        vm.incomingBecameVisible(
            ScenePresentationLayerIdentity(
                generation: incoming.identity.generation,
                sceneID: incoming.identity.sceneID,
                layerID: "scene-root"
            )
        )
        if let completionDeadline = vm.fireScheduledScenePresentationWakeUpForTesting() {
            clock.now = completionDeadline
        }
    }

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

    // 10_000 yields measured only 0.19-0.32s and starve the detached .utility planning; poll with short sleeps
    // over that window instead.
    private nonisolated static let preparedNextWaitTimeoutSeconds: TimeInterval = 1
    private static let preparedNextWaitPollNanoseconds: UInt64 = 2_000_000

    private func waitUntilForTesting(
        timeout: TimeInterval = Self.preparedNextWaitTimeoutSeconds,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: Self.preparedNextWaitPollNanoseconds)
        }
        return condition()
    }

    private func setCachedURL(_ url: URL, assetId: String, size: ThumbnailSize, in manager: AssetsDownloadManager) {
        switch size {
        case .fullsize:
            manager.assetURLs[assetId] = url
        case .preview:
            manager.assetPreviewURLs[assetId] = url
        case .thumbnail:
            manager.assetThumbnailURLs[assetId] = url
        }
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

    // iPad Pro 13 portrait planning size, in pt.
    private static let iPadPortraitPlanningWidthPoints = 2048
    private static let iPadPortraitPlanningHeightPoints = 2732
    // Matches the playback page control-bar protection band: the bottom 18% of the height.
    private static let controlBarNormalizedMinY = 0.82
    private static let controlBarNormalizedHeight = 0.18
    // Fixture set a has only 5 photos, so at most 4 next steps are enough to reach A2.
    private static let fixtureAdvanceStepLimit = 4

    private func makeFixtureSetAAssets() -> [Asset] {
        [
            makeFixtureAsset(
                id: "asset-a-1",
                width: 320,
                height: 180,
                exif: ExifInfo(
                    make: "immichSlides Synthetic",
                    model: "Fixture 1",
                    dateTimeOriginal: "2026-01-01T12:00:00.000Z",
                    city: "Fixture City",
                    state: "Fixture State",
                    country: "Synthetic"
                )
            ),
            makeFixtureAsset(id: "asset-a-2", width: 180, height: 320, exif: ExifInfo()),
            makeFixtureAsset(
                id: "asset-a-3",
                width: 300,
                height: 300,
                exif: ExifInfo(
                    make: "immichSlides Synthetic",
                    model: "Fixture 3",
                    dateTimeOriginal: "2026-01-03T12:00:00.000Z",
                    city: "Fixture City",
                    state: "Fixture State",
                    country: "Synthetic"
                )
            ),
            makeFixtureAsset(id: "asset-a-4", width: 360, height: 240, exif: ExifInfo()),
            makeFixtureAsset(
                id: "asset-a-5",
                width: 240,
                height: 360,
                exif: ExifInfo(
                    make: "immichSlides Synthetic",
                    model: "Fixture 5",
                    dateTimeOriginal: "2026-01-05T12:00:00.000Z",
                    city: "Fixture City",
                    state: "Fixture State",
                    country: "Synthetic"
                )
            )
        ]
    }

    private func makeFixtureAsset(id: String, width: Int, height: Int, exif: ExifInfo?) -> Asset {
        Asset(
            id: id,
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: exif,
            people: nil,
            tags: nil,
            livePhotoVideoID: nil,
            width: width,
            height: height
        )
    }

    private func markReady(_ assets: [Asset], in manager: AssetsDownloadManager) {
        for asset in assets {
            manager.assetStates[asset.id] = .readyToPlay
            manager.assetPreviewStates[asset.id] = .readyToPlay
            manager.assetURLs[asset.id] = URL(fileURLWithPath: "/tmp/immichslides-\(asset.id).png")
            manager.assetPreviewURLs[asset.id] = URL(fileURLWithPath: "/tmp/immichslides-\(asset.id)-preview.png")
        }
    }

    private func advanceUntilVisible(_ vm: SlideShowViewModel, assetId: String, maximumSteps: Int) {
        if vm.visibleImageAssetId == assetId || vm.safeCurrentScene?.primaryAssetId == assetId {
            return
        }
        for _ in 0..<maximumSteps {
            vm.requestNextScene()
            completeCurrentScenePresentation(vm)
            if vm.visibleImageAssetId == assetId || vm.safeCurrentScene?.primaryAssetId == assetId {
                return
            }
        }
    }

    // Stop only on the visible layer, so we do not skip the "screen shows A2, owner differs" state when primary
    // reaches A2 first.
    private func advanceUntilVisibleImage(_ vm: SlideShowViewModel, assetId: String, maximumSteps: Int) {
        if vm.visibleImageAssetId == assetId {
            return
        }
        for _ in 0..<maximumSteps {
            vm.requestNextScene()
            completeCurrentScenePresentation(vm)
            if vm.visibleImageAssetId == assetId {
                return
            }
        }
    }

    private func releaseAndWaitCompleted(
        assetId: String,
        fixture: LateLoadLocalHTTPFixture,
        manager: AssetsDownloadManager
    ) async throws {
        var loadTask: Task<Void, Never>?
        if fixture.enteredCount(assetId: assetId) == 0 {
            loadTask = Task {
                await manager.loadPhoto(assetId: assetId, size: .fullsize, priority: .high)
            }
            let didEnter = await fixture.waitUntilEntered(assetId: assetId)
            try #require(didEnter, "Request did not enter: \(assetId)")
        }
        fixture.release(assetId: assetId)
        let didComplete = await fixture.waitUntilCompleted(assetId: assetId)
        try #require(didComplete, "Response did not complete: \(assetId)")
        if let loadTask {
            await loadTask.value
        }
        let didBecomeReady = await waitUntilForTesting {
            manager.isReady(assetId: assetId, size: .fullsize)
        }
        try #require(didBecomeReady, "\(assetId) not ready")
    }

    private func firstCompletedAssetOrder(
        _ fixture: LateLoadLocalHTTPFixture,
        among assetIds: [String]
    ) -> [String] {
        let wanted = Set(assetIds)
        var seen: Set<String> = []
        var order: [String] = []
        for request in fixture.completedRequests() {
            guard let assetId = request.assetId,
                wanted.contains(assetId),
                seen.insert(assetId).inserted
            else {
                continue
            }
            order.append(assetId)
        }
        return order
    }

    // SHA of the source files for scripts/strict_e2e_server.py `_png` / set `a`.
    private static let fixtureSetAA2PNGSHA256 =
        "33d585c6774ee80efc2863348aedc67c81555243db70706cc11d8c933af6ff25"
    private static let fixtureSetAA3PNGSHA256 =
        "8b08c717bc650543c3ebe36b3563bb7c46c6fd2e84e0a15f663cb681524233e3"

    private func loadFixtureSetAPNGs(assetIds: [String]) throws -> [String: Data] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/StrictE2ESetA")
        var pngs: [String: Data] = [:]
        for assetId in assetIds {
            let url = directory.appendingPathComponent("\(assetId).png")
            pngs[assetId] = try Data(contentsOf: url)
        }
        return pngs
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func decodedPixelSize(assetId: String, port: UInt16) -> (width: Int, height: Int)? {
        guard
            let url = LateLoadRealPathFixture.thumbnailURL(
                port: port,
                assetId: assetId,
                size: .fullsize
            )
        else {
            return nil
        }
        guard let image = SDImageCache.shared.imageFromCache(forKey: url.absoluteString),
            let cgImage = image.cgImage
        else {
            return nil
        }
        return (cgImage.width, cgImage.height)
    }

    private func pauseHoldProbe(
        visibleImageId: String?,
        overlayOwnerId: String?,
        overlayAsset: Asset?,
        primaryId: String?,
        a2Decode: (width: Int, height: Int)?,
        a3Decode: (width: Int, height: Int)?
    ) -> String {
        let model = overlayAsset?.exifInfo?.model ?? "nil"
        let a2Size = a2Decode.map { "\($0.width)x\($0.height)" } ?? "nil"
        let a3Size = a3Decode.map { "\($0.width)x\($0.height)" } ?? "nil"
        return [
            "visible=\(visibleImageId ?? "nil")",
            "owner=\(overlayOwnerId ?? "nil")",
            "overlay=\(overlayAsset?.id ?? "nil")",
            "model=\(model)",
            "primary=\(primaryId ?? "nil")",
            "a2Decode=\(a2Size)",
            "a3Decode=\(a3Size)"
        ].joined(separator: " ")
    }

    private func oldOrderProbe(
        visibleImageId: String?,
        overlayOwnerId: String?,
        overlayAsset: Asset?,
        primaryId: String?,
        slotIds: [String],
        sceneType: PlaybackSmartFillSceneType?
    ) -> String {
        let model = overlayAsset?.exifInfo?.model ?? "nil"
        let sceneTypeText = sceneType.map { String(describing: $0) } ?? "nil"
        return [
            "visible=\(visibleImageId ?? "nil")",
            "owner=\(overlayOwnerId ?? "nil")",
            "overlay=\(overlayAsset?.id ?? "nil")",
            "model=\(model)",
            "primary=\(primaryId ?? "nil")",
            "slots=\(slotIds.joined(separator: ","))",
            "sceneType=\(sceneTypeText)"
        ].joined(separator: " ")
    }

    private func resetDownloadManagerState(_ manager: AssetsDownloadManager) {
        LateLoadRealPathTestSupport.resetDownloadManager(manager)
    }
}
