//
//  SlideShowViewModelAutoPlayIdentityTests.swift
//  immichSlidesTests
//
//  Asserts on a virtual clock that auto play switches identity, and that a foreground/background pause does
//  not catch up on missed advances.
//  Also exercises the real wake-up scheduler with a controllable sleeper.
//

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.sharedRuntimeIsolation)
struct SlideShowViewModelAutoPlayIdentityTests {

    enum WakeUpChange: CaseIterable, Equatable {
        case unchanged, replacement, matchingCancel, reset
    }

    @Test(arguments: WakeUpChange.allCases)
    func `scheduled wake ups deliver only the current tagged event after duplicate replacement cancel or reset`(
        _ change: WakeUpChange
    ) async throws {
        let clock = VirtualClock()
        clock.now = 1
        let sleeper = ControllableWakeUpSleeper()
        var events: [PlaybackSessionEngine.ScenePresentationEvent] = []
        var deliveryTimes: [TimeInterval] = []
        let scheduler = ScenePresentationWakeUpScheduler(
            now: { clock.now },
            sleepForTesting: { await sleeper.sleep(nanoseconds: $0) },
            deliver: { event, timestamp in
                events.append(event)
                deliveryTimes.append(timestamp)
            }
        )
        defer {
            scheduler.reset()
            sleeper.finishAll()
        }
        let generation = UUID()
        // An exactly representable sub-nanosecond fraction must round up to one nanosecond.
        let fraction = 1.0 / 4_294_967_296.0
        let originalDeadline = 1 + fraction
        var expectedDeadline = originalDeadline
        var expectedDelays: [UInt64] = [1]
        scheduler.schedule(generation: generation, deadline: originalDeadline)
        scheduler.schedule(generation: generation, deadline: originalDeadline)
        clock.now = 2
        try #require(await waitUntil(pollInterval: .milliseconds(1)) { sleeper.delays.count == 1 })
        scheduler.cancel(generation: UUID())

        switch change {
        case .unchanged:
            break
        case .replacement:
            expectedDeadline = 3 + fraction
            expectedDelays.append(1_000_000_001)
            scheduler.schedule(generation: generation, deadline: expectedDeadline)
        case .matchingCancel, .reset:
            if change == .matchingCancel {
                scheduler.cancel(generation: generation)
            } else {
                scheduler.reset()
            }
            // Reusing the same key must still reject the cancelled task's late completion.
            expectedDelays.append(0)
            scheduler.schedule(generation: generation, deadline: originalDeadline)
        }

        if expectedDelays.count == 2 {
            try #require(await waitUntil(pollInterval: .milliseconds(1)) { sleeper.delays.count == 2 })
            sleeper.finish(0)
            try #require(await waitUntil(pollInterval: .milliseconds(1)) { sleeper.completed.contains(0) })
            #expect(events.isEmpty)
        }
        clock.now = 42.5
        sleeper.finish(expectedDelays.count - 1)
        try #require(
            await waitUntil(pollInterval: .milliseconds(1)) {
                sleeper.completed.count == expectedDelays.count && events.count == 1
            })
        #expect(sleeper.delays == expectedDelays)
        #expect(events == [.wakeUp(generation: generation, deadline: expectedDeadline)])
        #expect(deliveryTimes == [42.5])
    }

    @Test(arguments: [5.0, 8.0])
    func `autoplay switches the current identity to the next scene once the deadline passes`(
        interval: TimeInterval
    ) throws {
        let clock = VirtualClock()
        let (viewModel, store) = makeIsolatedAutoPlayViewModel(clock: clock, interval: interval)
        defer { store.clear() }
        completeCurrentScenePresentation(viewModel, clock: clock)
        let firstIdentity = try #require(currentPresentationIdentity(viewModel))
        #expect(viewModel.safeCurrentScene?.primaryAssetId == "autoplay-0")
        let firstDeadline = try #require(viewModel.scenePresentationWakeUpScheduler.scheduledDeadlineForTesting)
        #expect(abs(firstDeadline - clock.now - interval) < 0.0001)

        clock.now = firstDeadline - 0.001
        #expect(viewModel.sceneRenderSnapshot.phase == .stablePhoto)
        #expect(viewModel.scenePresentationWakeUpScheduler.scheduledDeadlineForTesting == firstDeadline)
        #expect(currentPresentationIdentity(viewModel) == firstIdentity)
        #expect(viewModel.safeCurrentScene?.primaryAssetId == "autoplay-0")

        clock.now = firstDeadline
        let deadline = viewModel.fireScheduledScenePresentationWakeUpForTesting()
        #expect(deadline == firstDeadline)
        // At the deadline the next scene is committed and enters grace; the visible identity changes only once the next
        // scene is Ready.
        completeCurrentScenePresentation(viewModel, clock: clock)

        #expect(viewModel.safeCurrentScene?.primaryAssetId == "autoplay-1")
        #expect(currentPresentationIdentity(viewModel) != firstIdentity)
        let secondDeadline = try #require(viewModel.scenePresentationWakeUpScheduler.scheduledDeadlineForTesting)
        #expect(abs(secondDeadline - clock.now - interval) < 0.0001)
    }

    @Test(arguments: [5.0, 8.0], [false, true])
    func `overlapping user and background pauses resume only after both reasons clear with the remaining interval`(
        interval: TimeInterval,
        shouldReturnToForegroundFirst: Bool
    ) throws {
        let clock = VirtualClock()
        let (viewModel, store) = makeIsolatedAutoPlayViewModel(clock: clock, interval: interval)
        defer { store.clear() }
        completeCurrentScenePresentation(viewModel, clock: clock)
        let initialIdentity = try #require(currentPresentationIdentity(viewModel))
        let initialDeadline = try #require(viewModel.scenePresentationWakeUpScheduler.scheduledDeadlineForTesting)
        clock.now += 1.25
        let remainingInterval = initialDeadline - clock.now
        viewModel.toggleAutoPlayFromUserInteraction()
        let pausedLayer = try #require(viewModel.sceneRenderSnapshot.layers.first)
        clock.now += 0.5
        viewModel.suspendScenePresentationForBackground()

        clock.now += interval * 10
        if shouldReturnToForegroundFirst {
            viewModel.resumeScenePresentationFromBackground()
            #expect(!viewModel.isAutoPlay)
        } else {
            viewModel.toggleAutoPlayFromUserInteraction()
            #expect(viewModel.isAutoPlay)
        }
        #expect(viewModel.sceneRenderSnapshot.phase == .paused)
        #expect(viewModel.fireScheduledScenePresentationWakeUpForTesting() == nil)
        let stillPausedLayer = try #require(viewModel.sceneRenderSnapshot.layers.first)
        #expect(stillPausedLayer.identity == pausedLayer.identity)
        #expect(stillPausedLayer.opacity == pausedLayer.opacity)
        #expect(stillPausedLayer.motionActiveTime == pausedLayer.motionActiveTime)

        clock.now += interval * 10
        if shouldReturnToForegroundFirst {
            viewModel.toggleAutoPlayFromUserInteraction()
        } else {
            viewModel.resumeScenePresentationFromBackground()
        }
        #expect(viewModel.isAutoPlay)
        #expect(viewModel.sceneRenderSnapshot.phase == .stablePhoto)
        #expect(currentPresentationIdentity(viewModel) == initialIdentity)
        let resumedLayer = try #require(viewModel.sceneRenderSnapshot.layers.first)
        #expect(abs(resumedLayer.motionActiveTime - pausedLayer.motionActiveTime) < 0.0001)
        let resumedDeadline = try #require(viewModel.scenePresentationWakeUpScheduler.scheduledDeadlineForTesting)
        #expect(abs(resumedDeadline - clock.now - remainingInterval) < 0.0001)

        // A duplicate foreground notification must not reset the restored interval.
        clock.now += 0.25
        viewModel.resumeScenePresentationFromBackground()
        #expect(viewModel.scenePresentationWakeUpScheduler.scheduledDeadlineForTesting == resumedDeadline)
        #expect(currentPresentationIdentity(viewModel) == initialIdentity)
        clock.now = resumedDeadline
        #expect(viewModel.fireScheduledScenePresentationWakeUpForTesting() == resumedDeadline)
        completeCurrentScenePresentation(viewModel, clock: clock)
        #expect(viewModel.safeCurrentScene?.primaryAssetId == "autoplay-1")
    }

    @Test
    func `resuming after a background pause spanning ten intervals does not catch up or skip identities`() {
        let clock = VirtualClock()
        let (viewModel, store) = makeIsolatedAutoPlayViewModel(clock: clock)
        defer { store.clear() }
        completeCurrentScenePresentation(viewModel, clock: clock)
        let pausedIdentity = currentPresentationIdentity(viewModel)
        let pausedAssetId = viewModel.safeCurrentScene?.primaryAssetId
        #expect(pausedAssetId == "autoplay-0")

        viewModel.suspendScenePresentationForBackground()
        clock.now = 50
        #expect(viewModel.fireScheduledScenePresentationWakeUpForTesting() == nil)
        #expect(currentPresentationIdentity(viewModel) == pausedIdentity)
        #expect(viewModel.safeCurrentScene?.primaryAssetId == pausedAssetId)

        viewModel.resumeScenePresentationFromBackground()
        #expect(currentPresentationIdentity(viewModel) == pausedIdentity)
        #expect(viewModel.safeCurrentScene?.primaryAssetId == "autoplay-0")
        #expect(viewModel.safeCurrentScene?.primaryAssetId != "autoplay-1")
        #expect(viewModel.safeCurrentScene?.primaryAssetId != "autoplay-10")
    }

    private func makeIsolatedAutoPlayViewModel(
        clock: VirtualClock,
        interval: TimeInterval = 5
    ) -> (SlideShowViewModel, PlaybackSettingsStore) {
        let suiteName = "SlideShowViewModelAutoPlayIdentity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = PlaybackSettingsStore(
            key: "playbackSettings.autoPlayIdentity",
            defaults: defaults
        )
        store.save(
            PlaybackSettings(
                autoPlayEnabled: true,
                intervalSeconds: interval,
                displayMode: .singlePhoto
            )
        )

        let viewModel = SlideShowViewModel(
            source: .random,
            settingsStore: store,
            observeSettingsChanges: false
        )
        viewModel.scenePresentationTimestampProviderForTesting = { clock.now }
        viewModel.initialPhotoLoadHookForTesting = { _ in }
        viewModel.backgroundPreloadHookForTesting = { _, _, _ in }
        viewModel.indexChangePhotoLoadHookForTesting = { _, _ in }
        viewModel.transitionWindowPreloadHookForTesting = { _, _, _ in }
        viewModel.replacePlaybackAssetsForTesting(
            (0..<12).map { makeAsset(id: "autoplay-\($0)") }
        )
        return (viewModel, store)
    }

    private func completeCurrentScenePresentation(
        _ viewModel: SlideShowViewModel,
        clock: VirtualClock
    ) {
        var snapshot = viewModel.sceneRenderSnapshot
        guard snapshot.phase != .stablePhoto,
            let targetLayer = snapshot.layers.last(where: { $0.role == .incoming }),
            let scene = viewModel.scene(for: targetLayer)
        else {
            return
        }

        for slot in scene.photoSlots {
            viewModel.rendererDecoded(
                SceneRendererIdentity(
                    generation: targetLayer.identity.generation,
                    attemptID: viewModel.scenePresentationRendererAttemptID(for: targetLayer),
                    sceneID: targetLayer.identity.sceneID,
                    slotID: slot.id,
                    assetID: slot.asset.id
                )
            )
        }

        snapshot = viewModel.sceneRenderSnapshot
        if snapshot.phase == .transition,
            snapshot.layers.last(where: { $0.role == .incoming })?.isPresentationReady == false,
            let transitionDeadline = viewModel.fireScheduledScenePresentationWakeUpForTesting()
        {
            clock.now = transitionDeadline
            snapshot = viewModel.sceneRenderSnapshot
        }

        guard
            let incoming = snapshot.layers.last(where: {
                $0.role == .incoming && $0.isPresentationReady
            })
        else {
            return
        }
        clock.now = (incoming.fadeStartTime ?? clock.now) + SceneTransitionDiagnostic.firstVisibleTickOffsetSeconds
        viewModel.incomingBecameVisible(
            ScenePresentationLayerIdentity(
                generation: incoming.identity.generation,
                sceneID: incoming.identity.sceneID,
                layerID: "scene-root"
            )
        )
        if let completionDeadline = viewModel.fireScheduledScenePresentationWakeUpForTesting() {
            clock.now = completionDeadline
        }
    }

    private func currentPresentationIdentity(
        _ viewModel: SlideShowViewModel
    ) -> PlaybackSessionEngine.ScenePresentationIdentity? {
        viewModel.sceneRenderSnapshot.currentTarget?.identity
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
            livePhotoVideoID: nil,
            width: 1800,
            height: 1200
        )
    }
}

private final class VirtualClock {
    var now: TimeInterval = 0
}

@MainActor
private final class ControllableWakeUpSleeper {
    private(set) var delays: [UInt64] = []
    private(set) var completed: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func sleep(nanoseconds: UInt64) async {
        let index = delays.count
        delays.append(nanoseconds)
        // Ignore cancellation so the real scheduler must reject stale completions itself.
        await withCheckedContinuation { continuations[index] = $0 }
        completed.insert(index)
    }

    func finish(_ index: Int) {
        continuations.removeValue(forKey: index)?.resume()
    }

    func finishAll() {
        continuations.values.forEach { $0.resume() }
        continuations.removeAll()
    }
}
