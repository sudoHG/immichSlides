//
//  SlideShowViewModelAutoPlayOutgoingExifTests.swift
//  immichSlidesTests
//
//  During auto play, EXIF for a sole visible outgoing single photo must follow the old photo; the pause/resume
//  contract still holds.
//

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.serialized, .sharedRuntimeIsolation)
struct SlideShowViewModelAutoPlayOutgoingExifTests {

    @Test
    func
        `while playing, if outgoing is the sole visible photo and incoming is not yet visible, visibleOverlayAsset stays on outgoing`()
        throws
    {
        let clock = PresentationClock()
        let harness = makeSinglePhotoAutoplayHarness(suffix: "autoplayOutgoingExif", clock: clock)
        defer { harness.tearDown() }

        let snapshot = try uniqueOutgoingA2Window(
            harness.viewModel,
            clock: clock,
            requireAutoPlay: true
        )
        let outgoing = try #require(snapshot.layers.first { $0.role == .outgoing })
        let outgoingScene = try #require(harness.viewModel.scene(for: outgoing))
        try #require(harness.viewModel.isAutoPlay)
        try #require(snapshot.phase == .transition)
        try #require(outgoingScene.photoSlots.count == 1)
        try #require(outgoingScene.primaryAssetId == "asset-a-2")
        try #require(harness.viewModel.safeCurrentScene?.primaryAssetId == "asset-a-3")
        try #require(harness.viewModel.visibleOverlayState?.ownerPrimaryAssetId == "asset-a-3")

        #expect(harness.viewModel.visibleOverlayAsset?.id == "asset-a-2")
        #expect(harness.viewModel.visibleOverlayAsset?.exifInfo?.model != "Fixture 3")
        #expect(harness.viewModel.visibleOverlayAsset?.exifInfo?.make == nil)
        #expect(harness.viewModel.visibleOverlayAsset?.exifInfo?.model == nil)
    }

    @Test
    func `after pausing with only the outgoing photo visible, visibleOverlayAsset stays on outgoing`() throws {
        let clock = PresentationClock()
        let harness = makeSinglePhotoAutoplayHarness(suffix: "pausedOutgoingExif", clock: clock)
        defer { harness.tearDown() }

        _ = try uniqueOutgoingA2Window(harness.viewModel, clock: clock, requireAutoPlay: true)
        harness.viewModel.toggleAutoPlayFromUserInteraction()
        let snapshot = harness.viewModel.sceneRenderSnapshot
        try #require(!harness.viewModel.isAutoPlay)
        try #require(snapshot.phase == .paused)
        try #require(snapshot.layers.filter { $0.opacity > 0 }.map(\.role) == [.outgoing])
        try #require(harness.viewModel.safeCurrentScene?.primaryAssetId == "asset-a-3")

        #expect(harness.viewModel.visibleOverlayAsset?.id == "asset-a-2")
        #expect(harness.viewModel.visibleOverlayAsset?.exifInfo?.model != "Fixture 3")
        clock.now += 20
        #expect(harness.viewModel.visibleOverlayAsset?.id == "asset-a-2")
        #expect(harness.viewModel.sceneRenderSnapshot.layers == snapshot.layers)
    }

    @Test
    func `after resuming playback, visibleOverlayAsset keeps showing outgoing's EXIF while only it is visible`() throws
    {
        let clock = PresentationClock()
        let harness = makeSinglePhotoAutoplayHarness(suffix: "resumeOutgoingExif", clock: clock)
        defer { harness.tearDown() }

        _ = try uniqueOutgoingA2Window(harness.viewModel, clock: clock, requireAutoPlay: true)
        harness.viewModel.toggleAutoPlayFromUserInteraction()
        try #require(!harness.viewModel.isAutoPlay)
        try #require(harness.viewModel.visibleOverlayAsset?.id == "asset-a-2")

        harness.viewModel.toggleAutoPlayFromUserInteraction()
        let snapshot = harness.viewModel.sceneRenderSnapshot
        try #require(harness.viewModel.isAutoPlay)
        try #require(snapshot.layers.filter { $0.opacity > 0 }.map(\.role) == [.outgoing])
        try #require(harness.viewModel.visibleOverlayState?.ownerPrimaryAssetId == "asset-a-3")

        #expect(harness.viewModel.visibleOverlayAsset?.id == "asset-a-2")
        #expect(harness.viewModel.visibleOverlayAsset?.exifInfo?.model != "Fixture 3")
    }

    @Test
    func `while playing with incoming already visible, visibleOverlayAsset follows the committed incoming photo`()
        throws
    {
        let clock = PresentationClock()
        let harness = makeSinglePhotoAutoplayHarness(suffix: "autoplayIncomingVisibleExif", clock: clock)
        defer { harness.tearDown() }

        let fadeStart = try startAutomaticA2ToA3ReadyTransition(harness.viewModel, clock: clock)
        clock.now = fadeStart + 0.2
        let snapshot = harness.viewModel.sceneRenderSnapshot
        let incoming = try #require(snapshot.layers.last { $0.role == .incoming })
        try #require(harness.viewModel.isAutoPlay)
        try #require(incoming.identity.assetID == "asset-a-3")
        try #require(incoming.opacity > 0)
        try #require(snapshot.layers.filter { $0.opacity > 0 }.map(\.role) != [.outgoing])

        #expect(harness.viewModel.visibleOverlayAsset?.id == "asset-a-3")
        #expect(harness.viewModel.visibleOverlayAsset?.exifInfo?.model == "Fixture 3")
    }

    @Test
    func `during a black transition frame before the new photo appears, EXIF keeps the previously shown photo`() throws
    {
        let clock = PresentationClock()
        let harness = makeSinglePhotoAutoplayHarness(suffix: "autoplayBlackFrameExif", clock: clock)
        defer { harness.tearDown() }

        let fadeStart = try startAutomaticA2ToA3ReadyTransition(harness.viewModel, clock: clock)
        clock.now = fadeStart - 0.01
        let snapshot = harness.viewModel.sceneRenderSnapshot
        try #require(harness.viewModel.isAutoPlay)
        try #require(snapshot.layers.filter { $0.opacity > 0 }.isEmpty)
        try #require(harness.viewModel.visibleOverlayState?.ownerPrimaryAssetId == "asset-a-3")

        #expect(harness.viewModel.visibleOverlayAsset?.id == "asset-a-2")
        #expect(harness.viewModel.visibleOverlayAsset?.exifInfo?.model != "Fixture 3")
    }

    @Test
    func `overlapping photos pick EXIF by composited visibility contribution, ties favor the older photo`() throws {
        let clock = PresentationClock()
        let harness = makeSinglePhotoAutoplayHarness(suffix: "overlappingExif", clock: clock)
        defer { harness.tearDown() }
        _ = try startAutomaticA2ToA3ReadyTransition(harness.viewModel, clock: clock)
        let source = harness.viewModel.sceneRenderSnapshot

        for (outgoingOpacity, incomingOpacity, expected) in [
            (0.8, 0.25, "asset-a-2"),
            (0.8, 0.5, "asset-a-3"),
            (1.0, 0.5, "asset-a-2")
        ] {
            let layers = source.layers.map { layer in
                PlaybackSessionEngine.SceneRenderLayer(
                    identity: layer.identity,
                    role: layer.role,
                    opacity: layer.role == .outgoing ? outgoingOpacity : incomingOpacity,
                    motionActiveTime: layer.motionActiveTime,
                    isMotionEnabled: layer.isMotionEnabled,
                    fadeStartTime: layer.fadeStartTime,
                    fadeDuration: layer.fadeDuration,
                    isPresentationReady: layer.isPresentationReady
                )
            }
            let snapshot = PlaybackSessionEngine.SceneRenderSnapshot(
                phase: source.phase,
                underlyingPhase: source.underlyingPhase,
                layers: layers,
                currentTarget: source.currentTarget,
                frozenInterval: source.frozenInterval,
                activeTime: source.activeTime,
                suspensionReasons: source.suspensionReasons,
                isReduceMotionEnabled: source.isReduceMotionEnabled,
                pendingTargetIsReady: source.pendingTargetIsReady
            )
            #expect(harness.viewModel.visibleOverlayScene(in: snapshot)?.primaryAssetId == expected)
        }
    }

    private final class PresentationClock {
        var now: TimeInterval = 0
    }

    private struct SinglePhotoAutoplayHarness {
        let viewModel: SlideShowViewModel
        let store: PlaybackSettingsStore
        let defaults: UserDefaults
        let suiteName: String

        @MainActor
        func tearDown() {
            store.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeSinglePhotoAutoplayHarness(
        suffix: String,
        clock: PresentationClock
    ) -> SinglePhotoAutoplayHarness {
        let suiteName = "SlideShowViewModelAutoPlayOutgoingExif.\(suffix).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = PlaybackSettingsStore(
            key: "playbackSettings.autoPlayOutgoingExif.\(suffix)",
            defaults: defaults
        )
        store.save(
            PlaybackSettings(
                autoPlayEnabled: true,
                intervalSeconds: 5,
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
        let assets = makeSinglePhotoAssets()
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

    private func uniqueOutgoingA2Window(
        _ vm: SlideShowViewModel,
        clock: PresentationClock,
        requireAutoPlay: Bool
    ) throws -> PlaybackSessionEngine.SceneRenderSnapshot {
        _ = try startAutomaticA2ToA3ReadyTransition(vm, clock: clock)
        clock.now += 0.5
        let snapshot = vm.sceneRenderSnapshot
        let outgoing = try #require(snapshot.layers.first { $0.role == .outgoing })
        let incoming = try #require(snapshot.layers.last { $0.role == .incoming })
        if requireAutoPlay {
            try #require(vm.isAutoPlay)
        }
        try #require(snapshot.phase == .transition)
        try #require(outgoing.identity.assetID == "asset-a-2")
        try #require(outgoing.opacity > 0 && outgoing.opacity < 1)
        try #require(incoming.identity.assetID == "asset-a-3")
        try #require(incoming.opacity == 0)
        try #require(snapshot.layers.filter { $0.opacity > 0 }.map(\.role) == [.outgoing])
        return snapshot
    }

    private func startAutomaticA2ToA3ReadyTransition(
        _ vm: SlideShowViewModel,
        clock: PresentationClock
    ) throws -> TimeInterval {
        try #require(vm.sceneRenderSnapshot.phase == .stablePhoto)
        try #require(vm.safeCurrentScene?.primaryAssetId == "asset-a-2")
        try #require(vm.isAutoPlay)

        clock.now += 5
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
        clock: PresentationClock
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
        clock.now = (incoming.fadeStartTime ?? clock.now) + 0.5
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

    private func makeSinglePhotoAssets() -> [Asset] {
        [
            makeAsset(id: "asset-a-2", width: 180, height: 320, exif: ExifInfo()),
            makeAsset(
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
            makeAsset(id: "asset-a-4", width: 360, height: 240, exif: ExifInfo()),
            makeAsset(
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

    private func makeAsset(id: String, width: Int, height: Int, exif: ExifInfo?) -> Asset {
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

    private func resetDownloadManagerState(_ manager: AssetsDownloadManager) {
        manager.assetStates = [:]
        manager.assetPreviewStates = [:]
        manager.assetThumbnailStates = [:]
        manager.assetURLs = [:]
        manager.assetPreviewURLs = [:]
        manager.assetThumbnailURLs = [:]
    }
}
