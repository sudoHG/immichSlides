import CryptoKit
import Foundation
import SDWebImage
import Testing
import UIKit
@testable import immichSlides

extension SlideShowViewModelVisibleSceneIdentityTests {
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
}
