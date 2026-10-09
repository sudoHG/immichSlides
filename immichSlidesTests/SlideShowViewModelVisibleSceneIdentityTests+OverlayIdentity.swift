import CryptoKit
import Foundation
import SDWebImage
import Testing
import UIKit
@testable import immichSlides

extension SlideShowViewModelVisibleSceneIdentityTests {
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
                intervalSeconds: SceneLifecycleContract.minimumInterval,
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
                intervalSeconds: SceneLifecycleContract.minimumInterval,
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

        await vm.awaitInFlightPreparedPlanningForTesting()
        let didPrepareNext = vm.preparedSmartFillNextAssetIdsForTesting != nil
        try #require(didPrepareNext)
        let tokenBeforeAutoPlay = vm.targetTransitionToken

        clock.now += SceneLifecycleContract.minimumInterval
        var deadline = vm.fireScheduledScenePresentationWakeUpForTesting()
        if vm.targetTransitionToken == tokenBeforeAutoPlay {
            await vm.awaitInFlightPreparedPlanningForTesting()
            let didPrepareAfterSkippedTick = vm.preparedSmartFillNextAssetIdsForTesting != nil
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
}
