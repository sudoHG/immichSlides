import CryptoKit
import Foundation
import SDWebImage
import Testing
import UIKit
@testable import immichSlides

private final class VisibleSceneFixtureBundleToken {}

extension SlideShowViewModelVisibleSceneIdentityTests {
    func runRealPathProbe(
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

    func isLoadedKeyFixtureCredential() -> Bool {
        ImmichAPIService.shared.getApiKey() == LateLoadRealPathFixture.fixtureCredential
    }

    func prepareRealLoadPhoto(assetId: String, port: UInt16) {
        LateLoadRealPathTestSupport.resetDownloadManager(AssetsDownloadManager.shared)
        let urls = [ThumbnailSize.fullsize, .preview, .thumbnail].compactMap {
            LateLoadRealPathFixture.thumbnailURL(port: port, assetId: assetId, size: $0)
        }
        LateLoadRealPathTestSupport.clearImageCache(for: urls)
    }

    final class PresentationTestClock {
        var now: TimeInterval = 0
    }

    struct SinglePhotoAutoplayHarness {
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

    func makeSinglePhotoAutoplayHarness(
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
                intervalSeconds: SceneLifecycleContract.minimumInterval,
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

    func startAutomaticA2ToA3ReadyTransition(
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

    func decodeIncomingRendererForTesting(_ vm: SlideShowViewModel) {
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

    func settleIncomingToStableUsingClock(
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

    // 10_000 yields measured only 0.19-0.32s and starve the detached .utility planning; poll with short sleeps
    // over that window instead.
    nonisolated static let preparedNextWaitTimeoutSeconds: TimeInterval = 1
    static let preparedNextWaitPollNanoseconds: UInt64 = 2_000_000

    func waitUntilForTesting(
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

    func setCachedURL(_ url: URL, assetId: String, size: ThumbnailSize, in manager: AssetsDownloadManager) {
        switch size {
        case .fullsize:
            manager.assetURLs[assetId] = url
        case .preview:
            manager.assetPreviewURLs[assetId] = url
        case .thumbnail:
            manager.assetThumbnailURLs[assetId] = url
        }
    }

    func markReady(assetId: String, size: ThumbnailSize, in manager: AssetsDownloadManager) {
        switch size {
        case .fullsize:
            manager.assetStates[assetId] = .readyToPlay
        case .preview:
            manager.assetPreviewStates[assetId] = .readyToPlay
        case .thumbnail:
            manager.assetThumbnailStates[assetId] = .readyToPlay
        }
    }

    func makeAsset(id: String) -> Asset {
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
    static let iPadPortraitPlanningWidthPoints = 2048
    static let iPadPortraitPlanningHeightPoints = 2732
    // Matches the playback page control-bar protection band: the bottom 18% of the height.
    static let controlBarNormalizedMinY = 0.82
    static let controlBarNormalizedHeight = 0.18
    // Fixture set a has only 5 photos, so at most 4 next steps are enough to reach A2.
    static let fixtureAdvanceStepLimit = 4

    func makeFixtureSetAAssets() -> [Asset] {
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

    func makeFixtureAsset(id: String, width: Int, height: Int, exif: ExifInfo?) -> Asset {
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

    func markReady(_ assets: [Asset], in manager: AssetsDownloadManager) {
        for asset in assets {
            manager.assetStates[asset.id] = .readyToPlay
            manager.assetPreviewStates[asset.id] = .readyToPlay
            manager.assetURLs[asset.id] = URL(fileURLWithPath: "/tmp/immichslides-\(asset.id).png")
            manager.assetPreviewURLs[asset.id] = URL(fileURLWithPath: "/tmp/immichslides-\(asset.id)-preview.png")
        }
    }

    func advanceUntilVisible(_ vm: SlideShowViewModel, assetId: String, maximumSteps: Int) {
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
    func advanceUntilVisibleImage(_ vm: SlideShowViewModel, assetId: String, maximumSteps: Int) {
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

    func releaseAndWaitCompleted(
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

    func firstCompletedAssetOrder(
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
    static let fixtureSetAA2PNGSHA256 =
        "33d585c6774ee80efc2863348aedc67c81555243db70706cc11d8c933af6ff25"
    static let fixtureSetAA3PNGSHA256 =
        "8b08c717bc650543c3ebe36b3563bb7c46c6fd2e84e0a15f663cb681524233e3"

    func loadFixtureSetAPNGs(assetIds: [String]) throws -> [String: Data] {
        let bundle = Bundle(for: VisibleSceneFixtureBundleToken.self)
        var pngs: [String: Data] = [:]
        for assetId in assetIds {
            let url = try #require(
                bundle.url(forResource: assetId, withExtension: "png", subdirectory: "Fixtures/StrictE2ESetA"),
                "Missing bundled scene fixture: \(assetId).png"
            )
            pngs[assetId] = try Data(contentsOf: url)
        }
        return pngs
    }

    func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func decodedPixelSize(assetId: String, port: UInt16) -> (width: Int, height: Int)? {
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

    func pauseHoldProbe(
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

    func oldOrderProbe(
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

    func resetDownloadManagerState(_ manager: AssetsDownloadManager) {
        LateLoadRealPathTestSupport.resetDownloadManager(manager)
    }
}
