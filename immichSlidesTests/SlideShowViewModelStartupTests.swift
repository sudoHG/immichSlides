//
//  SlideShowViewModelStartupTests.swift
//  immichSlidesTests
//
//  Covers the state flow from cold launch into the playback page; settings are restored only from local
//  persistence.
//

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.serialized, .sharedPlaybackRuntimeIsolation)
struct SlideShowViewModelStartupTests {
    let initialSceneRequestPollInterval: Duration = .milliseconds(30)
    let persistedPlaybackIntervalSeconds: TimeInterval = 9

    @Test(arguments: [false, true])
    func `older startup completion keeps newer work joinable and cancellable`(isSurfaceActivation: Bool) async throws {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.isAutoPlay = false
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }

        // First preload is user-reachable; surface overlap is latent: facade admission needs nil readback or .imageNotReady, which the planner never emits.
        if !isSurfaceActivation {
            var continuationA: CheckedContinuation<[Asset], any Error>?
            var continuationB: CheckedContinuation<[Asset], any Error>?
            var executionCount = 0
            var didCancelB = false
            vm.loadAssetsHookForTesting = { _ in
                executionCount += 1
                switch executionCount {
                case 1:
                    return try await withCheckedThrowingContinuation { continuationA = $0 }
                case 2:
                    let assets = try await withCheckedThrowingContinuation { continuationB = $0 }
                    didCancelB = Task.isCancelled
                    return assets
                default:
                    Issue.record("A caller must join the pending first preload")
                    return []
                }
            }
            defer {
                vm.preparePlaybackSourceForPresentation(to: .random)
                vm.loadAssetsHookForTesting = { _ in throw CancellationError() }
                continuationA?.resume(throwing: CancellationError())
                continuationB?.resume(throwing: CancellationError())
            }

            var didFinishA = false
            let callerA = Task {
                await vm.firstPreload()
                didFinishA = true
            }
            defer { callerA.cancel() }
            let didSuspendA = await waitUntil { continuationA != nil }
            try #require(didSuspendA)

            vm.preparePlaybackSourceForPresentation(
                to: .filtered(FilterSelection(albumIds: ["current-album"], personFilters: [])))
            var didFinishB = false
            let callerB = Task {
                await vm.firstPreload()
                didFinishB = true
            }
            defer { callerB.cancel() }
            let didSuspendB = await waitUntil { continuationB != nil }
            try #require(didSuspendB)

            continuationA?.resume(returning: [])
            continuationA = nil
            let didCompleteA = await waitUntil { didFinishA }
            try #require(didCompleteA)

            var didEnterC = false
            var didFinishC = false
            let callerC = Task {
                didEnterC = true
                await vm.firstPreload()
                didFinishC = true
            }
            defer { callerC.cancel() }
            let didStartC = await waitUntil { didEnterC }
            try #require(didStartC)
            #expect(executionCount == 2)
            #expect(!didFinishB)
            #expect(!didFinishC)

            vm.preparePlaybackSourceForPresentation(to: .random)
            continuationB?.resume(returning: [makeAsset(id: "cancelled-current")])
            continuationB = nil
            let didCompleteCurrentCallers = await waitUntil { didFinishB && didFinishC }
            try #require(didCompleteCurrentCallers)
            #expect(didCancelB)
            #expect(executionCount == 2)
            #expect(!vm.didFirstPreload)
            #expect(vm.assets.isEmpty)
        } else {
            let assets = [makeAsset(id: "initial-asset", width: 1200, height: 2400)]
            vm.replacePlaybackAssetsForTesting(assets)
            let setupCompletion = try #require(vm.currentSceneDownloadCompletion)
            var didFinishSetup = false
            let setupCaller = Task {
                await setupCompletion.waitForDownloads()
                didFinishSetup = true
            }
            defer { setupCaller.cancel() }
            let didCompleteSetup = await waitUntil { didFinishSetup }
            try #require(didCompleteSetup)

            var downloadContinuationA: CheckedContinuation<Void, Never>?
            var replacementDownloadContinuation: CheckedContinuation<Void, Never>?
            var delayContinuationB: CheckedContinuation<Void, Never>?
            var delayCount = 0
            var activationCount = 0
            var executionCount = 0
            var completionCount = 0
            var didFinishActivationA = false
            var didFinishActivationB = false
            var didFinishReplacement = false
            let executor = vm.scenePresentationEffectExecutor
            executor.surfaceActivationSleepForTesting = {
                delayCount += 1
                switch delayCount {
                case 1:
                    return { didFinishActivationA = true }
                case 2:
                    await withCheckedContinuation { delayContinuationB = $0 }
                    return { didFinishActivationB = true }
                default:
                    Issue.record("Only the two scheduled activations may enter their delays")
                    return {}
                }
            }
            vm.initialPhotoLoadHookForTesting = { _ in
                executionCount += 1
                let execution = executionCount
                switch execution {
                case 1:
                    await withCheckedContinuation { downloadContinuationA = $0 }
                case 2:
                    await withCheckedContinuation { replacementDownloadContinuation = $0 }
                default:
                    Issue.record("A cancelled surface activation must not rebuild the initial scene")
                }
                completionCount += 1
                if execution == 2 { didFinishReplacement = true }
            }
            defer {
                vm.preparePlaybackSourceForPresentation(to: .random)
                executor.surfaceActivationSleepForTesting = nil
                vm.initialPhotoLoadHookForTesting = { _ in }
                downloadContinuationA?.resume()
                replacementDownloadContinuation?.resume()
                delayContinuationB?.resume()
            }

            // Fixture shortcut: pool replacement self-cancels A before B starts; its download still drains.
            executor.scheduleSurfaceActivation {
                activationCount += 1
                vm.replacePlaybackAssetsForTesting(assets)
                return vm.currentSceneDownloadCompletion
            }
            let didSuspendA = await waitUntil { downloadContinuationA != nil }
            try #require(didSuspendA)

            executor.scheduleSurfaceActivation {
                activationCount += 1
                vm.replacePlaybackAssetsForTesting(assets)
                return vm.currentSceneDownloadCompletion
            }
            let didSuspendB = await waitUntil { delayContinuationB != nil }
            try #require(didSuspendB)
            downloadContinuationA?.resume()
            downloadContinuationA = nil
            let didCompleteA = await waitUntil { didFinishActivationA }
            try #require(didCompleteA)

            // Pool replacement must still cancel B after A's outer activation has finished cleanup.
            vm.replacePlaybackAssetsForTesting(assets)
            let didSuspendReplacement = await waitUntil { replacementDownloadContinuation != nil }
            try #require(didSuspendReplacement)
            delayContinuationB?.resume()
            delayContinuationB = nil
            let didCompleteB = await waitUntil { didFinishActivationB }
            try #require(didCompleteB)
            #expect(activationCount == 1)
            #expect(executionCount == 2)
            #expect(completionCount == 1)

            replacementDownloadContinuation?.resume()
            replacementDownloadContinuation = nil
            let didCompleteReplacement = await waitUntil { didFinishReplacement }
            try #require(didCompleteReplacement)
            #expect(activationCount == 1)
            #expect(executionCount == 2)
            #expect(completionCount == 2)
        }
    }

    @Test
    func `cold launch uses the stored filtered source when the default mode is filtered and criteria are non-empty`() {
        let snapshot = PersistentPlaybackSnapshot.capture()
        defer { snapshot.restore() }

        var settings = PlaybackSettings()
        settings.defaultPlaybackMode = .filtered
        PlaybackSettingsStore().save(settings)

        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-solo", matchMode: .soloOnly)]
        )
        FilterSelectionStore().save(selection)

        let source = ContentView.initialPlaybackSourceForColdLaunch()

        var restoredSelection: FilterSelection?
        if case .filtered(let selection) = source {
            restoredSelection = selection
        }

        #expect(restoredSelection == selection)
    }

    @Test
    func `cold launch falls back to random playback when the default filtered selection is empty`() {
        let snapshot = PersistentPlaybackSnapshot.capture()
        defer { snapshot.restore() }

        var settings = PlaybackSettings()
        settings.defaultPlaybackMode = .filtered
        PlaybackSettingsStore().save(settings)
        FilterSelectionStore().clear()

        let source = ContentView.initialPlaybackSourceForColdLaunch()

        var isRandom = false
        if case .random = source {
            isRandom = true
        }

        #expect(isRandom)
    }

    @Test
    func `a stale initial preload task cannot overwrite a newer filtered playback result`() async throws {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)

        var randomContinuation: CheckedContinuation<[Asset], any Error>?

        vm.loadAssetsHookForTesting = { source in
            switch source {
            case .random:
                return try await withCheckedThrowingContinuation { continuation in
                    randomContinuation = continuation
                }
            case .filtered:
                return [makeAsset(id: "filtered-asset")]
            }
        }

        // Isolate generation from real downloads so a late network completion cannot overwrite the newer filter.
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }

        let oldPreloadTask = Task {
            await vm.firstPreload()
        }

        // Wait until the old random task reaches its suspension point before switching source.
        let didSuspend = await waitUntil { randomContinuation != nil }
        try #require(didSuspend, "Timed out waiting for randomContinuation to be captured")

        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-solo", matchMode: .soloOnly)]
        )
        await vm.switchPlaybackSource(to: .filtered(selection))

        #expect(vm.assets.map(\.id) == ["filtered-asset"])
        #expect(vm.isLoading == false)
        #expect(vm.didFirstPreload)

        // A late empty array from the old random task must be dropped by generation, or it would turn the new filter
        // into an empty pool.

        randomContinuation?.resume(returning: [])
        await oldPreloadTask.value

        #expect(vm.assets.map(\.id) == ["filtered-asset"])
        #expect(vm.isLoading == false)
        #expect(vm.shouldReloadFilteredSource(for: selection) == false)
    }

    @Test(arguments: [false, true], [false, true])
    func `a current empty or failed initial load clears loading and recovers on a valid reload`(
        isFiltered: Bool, shouldThrow: Bool
    ) async {
        let source: PlaybackSource =
            isFiltered ? .filtered(FilterSelection(albumIds: ["album-recovery"])) : .random
        let vm = SlideShowViewModel(source: source)
        resetDownloadManagerState(vm.downloadManager)
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }
        vm.loadAssetsHookForTesting = { _ in
            if shouldThrow { throw URLError(.cannotConnectToHost) }
            return []
        }

        await vm.loadAssets()

        let expectedMessage: String
        if shouldThrow {
            expectedMessage = String(localized: "Failed to load photos. Check your network or server settings.")
        } else if isFiltered {
            expectedMessage = String(
                localized: "No playable photos match the current filters. Try another album or person.")
        } else {
            expectedMessage = String(
                localized: "Immich did not return any playable photos. Check your server library or network connection."
            )
        }
        #expect(vm.isLoading == false)
        #expect(vm.assets.isEmpty)
        #expect(vm.safeCurrentScene == nil)
        #expect(vm.emptyPlaybackMessage == expectedMessage)

        vm.loadAssetsHookForTesting = { _ in [makeAsset(id: "recovered-photo")] }
        await vm.loadAssets()

        #expect(vm.isLoading == false)
        #expect(vm.assets.map(\.id) == ["recovered-photo"])
        #expect(vm.safeCurrentScene?.assetIds == ["recovered-photo"])
        #expect(vm.emptyPlaybackMessage == nil)
    }

    @Test
    func `a stale load-more task cannot append into a newer filtered playback result`() async throws {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.overwritePlaybackPoolWithoutResetForTesting([makeAsset(id: "old-random")])

        var randomContinuation: CheckedContinuation<[Asset], any Error>?

        vm.loadMoreAssetsHookForTesting = { source in
            switch source {
            case .random:
                return try await withCheckedThrowingContinuation { continuation in
                    randomContinuation = continuation
                }
            case .filtered:
                return [makeAsset(id: "filtered-more")]
            }
        }

        vm.loadAssetsHookForTesting = { source in
            switch source {
            case .random:
                return [makeAsset(id: "random-asset")]
            case .filtered:
                return [makeAsset(id: "filtered-asset")]
            }
        }

        // Only checks playback pool state; no image downloads.
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }

        let oldLoadMoreTask = Task {
            await vm.loadMoreAssets()
        }

        let didSuspend = await waitUntil { randomContinuation != nil }
        try #require(didSuspend, "Timed out waiting for randomContinuation to be captured")

        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-solo", matchMode: .soloOnly)]
        )
        await vm.switchPlaybackSource(to: .filtered(selection))

        #expect(vm.assets.map(\.id) == ["filtered-asset"])
        #expect(vm.isLoadingMore == false)

        // A late random refill must be dropped; the new filtered pool stays unchanged.

        randomContinuation?.resume(returning: [makeAsset(id: "stale-random-more")])
        await oldLoadMoreTask.value

        #expect(vm.assets.map(\.id) == ["filtered-asset"])
        #expect(vm.isLoadingMore == false)
    }

    @Test
    func `the initial load result cannot write back when the session identity changed even if generation did not`()
        async throws
    {
        let vm = SlideShowViewModel(source: .random)
        var continuation: CheckedContinuation<[Asset], any Error>?
        vm.loadAssetsHookForTesting = { _ in
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
            }
        }

        let loadTask = Task {
            await vm.loadAssets()
        }
        let didSuspend = await waitUntil { continuation != nil }
        try #require(didSuspend, "Timed out waiting for continuation to be captured")

        vm.replacePlaybackAssetsForTesting([makeAsset(id: "new-session")])
        continuation?.resume(returning: [makeAsset(id: "stale-result")])
        let didApply = await loadTask.value

        #expect(didApply == false)
        #expect(vm.assets.map(\.id) == ["new-session"])
        #expect(vm.safeCurrentScene?.primaryAssetId == "new-session")
    }

    @Test
    func `the load-more result cannot append when the session identity changed even if generation did not`()
        async throws
    {
        let vm = SlideShowViewModel(source: .random)
        vm.replacePlaybackAssetsForTesting([makeAsset(id: "old-session")])
        var continuation: CheckedContinuation<[Asset], any Error>?
        vm.loadMoreAssetsHookForTesting = { _ in
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
            }
        }

        let loadMoreTask = Task {
            await vm.loadMoreAssets()
        }
        let didSuspend = await waitUntil { continuation != nil }
        try #require(didSuspend, "Timed out waiting for continuation to be captured")

        vm.replacePlaybackAssetsForTesting([makeAsset(id: "new-session")])
        continuation?.resume(returning: [makeAsset(id: "stale-more")])
        await loadMoreTask.value

        #expect(vm.assets.map(\.id) == ["new-session"])
    }

    @Test
    func `a filtered soloOnly load-more still appends to the same playback pool after the scene advanced in-session`()
        async throws
    {
        let selection = FilterSelection(
            albumIds: [],
            personFilters: [PersonFilter(personId: "person-solo", matchMode: .soloOnly)]
        )
        let vm = SlideShowViewModel(source: .filtered(selection))
        resetDownloadManagerState(vm.downloadManager)
        vm.maxAssetCount = 200
        vm.qaPlaybackSequenceEvidenceEnabledForTesting = true
        var emittedLines: [String] = []
        vm.qaPlaybackSequenceOSLogEmitterForTesting = { line in
            emittedLines.append(line)
        }
        let initialAssets = (0..<12).map { makeAsset(id: "asset-\($0)") }
        markReady(initialAssets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(initialAssets)

        var continuation: CheckedContinuation<[Asset], any Error>?
        vm.loadMoreAssetsHookForTesting = { _ in
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
            }
        }

        let loadMoreTask = Task {
            await vm.loadMoreAssets()
        }
        let didSuspend = await waitUntil { continuation != nil }
        try #require(didSuspend, "Timed out waiting for continuation to be captured")

        vm.requestNextScene()
        let transitionToken = vm.targetTransitionToken
        let transitionTargetIndex = vm.targetIndex
        await vm.synchronizePlaybackReadbackForTesting(token: transitionToken, targetIndex: transitionTargetIndex)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-1")

        let appendedAssets = (12..<36).map { makeAsset(id: "asset-\($0)") }
        continuation?.resume(returning: appendedAssets)
        await loadMoreTask.value

        #expect(vm.isLoadingMore == false)
        #expect(vm.assets.map(\.id) == (0..<36).map { "asset-\($0)" })
        #expect(emittedLines.contains { $0.contains("eventType=loadMoreResult") })
        #expect(emittedLines.contains { $0.contains("old=12") || $0.contains("oldCount=12") })
    }

    @Test
    func `an initial preload cannot mark the old scene current after the session changed`() async throws {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.loadAssetsHookForTesting = { _ in
            [makeAsset(id: "old-initial")]
        }
        var continuation: CheckedContinuation<Void, Never>?
        vm.initialPhotoLoadHookForTesting = { assetId in
            guard assetId == "old-initial", continuation == nil else { return }
            await withCheckedContinuation { pending in
                continuation = pending
            }
        }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }

        let preloadTask = Task {
            await vm.prepareInitialAssets()
        }
        let didSuspend = await waitUntil { continuation != nil }
        try #require(didSuspend, "Timed out waiting for continuation to be captured")

        vm.replacePlaybackAssetsForTesting([makeAsset(id: "new-session")])
        continuation?.resume()
        await preloadTask.value

        #expect(vm.didFirstPreload == false)
        #expect(vm.assets.map(\.id) == ["new-session"])
        #expect(vm.safeCurrentScene?.primaryAssetId == "new-session")
    }

    @Test
    func `playback scenes come from the session engine and never reuse a sceneId for the same asset`() {
        let vm = SlideShowViewModel(source: .random)
        let zeroSessionId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

        vm.replacePlaybackAssetsForTesting([
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b")
        ])

        #expect(vm.playbackScenes.compactMap(\.primaryAssetId) == ["asset-a"])
        #expect(vm.assetIds(in: 0...1) == ["asset-a"])
        let firstSessionId = vm.playbackScenes.first?.playbackSessionId
        #expect(firstSessionId != zeroSessionId)

        vm.replacePlaybackAssetsForTesting([makeAsset(id: "asset-a")])

        #expect(vm.playbackScenes.compactMap(\.primaryAssetId) == ["asset-a"])
        #expect(vm.playbackScenes.first?.playbackSessionId != firstSessionId)
        #expect(vm.sceneIdLogValue(at: 1) == "nil")
    }

    @Test
    func `after the initial preload, currentIndex aligns with safeCurrentScene`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.loadAssetsHookForTesting = { _ in
            [
                makeAsset(id: "asset-a"),
                makeAsset(id: "asset-b")
            ]
        }
        vm.initialPhotoLoadHookForTesting = { _ in }
        vm.backgroundPreloadHookForTesting = { _, _, _ in }

        await vm.prepareInitialAssets()

        #expect(vm.currentIndex == 0)
        #expect(vm.targetIndex == 0)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-a")
        #expect(vm.sceneIdLogValue(at: vm.currentIndex) == vm.safeCurrentScene?.id)
        #expect(vm.safeCurrentScene?.playbackSessionId != UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        #expect(vm.safeCurrentAsset?.id == "asset-a")
    }

    @Test
    func `after a manual next, currentIndex and targetIndex point to the same scene`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.overwritePlaybackPoolWithoutResetForTesting([
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b"),
            makeAsset(id: "asset-c")
        ])
        vm.replacePlaybackAssetsForTesting(vm.assets)
        vm.requestNextScene()
        let transitionToken = vm.targetTransitionToken
        let transitionTargetIndex = vm.targetIndex
        vm.downloadManager.assetStates["asset-b"] = .readyToPlay
        vm.downloadManager.assetPreviewStates["asset-b"] = .readyToPlay

        await vm.synchronizePlaybackReadbackForTesting(token: transitionToken, targetIndex: transitionTargetIndex)

        #expect(vm.currentIndex == 1)
        #expect(vm.targetIndex == 1)
        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-b")
        #expect(vm.sceneIdLogValue(at: vm.targetIndex) == vm.safeCurrentScene?.id)
        #expect(vm.safeCurrentScene?.playbackSessionId != UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
    }

    @Test
    func `QA playback sequence evidence is off by default and uses the shared log path only when enabled`() async {
        let rawAssetId = "raw-asset-id-that-must-not-leak"
        let disabledVM = SlideShowViewModel(source: .random)
        resetDownloadManagerState(disabledVM.downloadManager)
        disabledVM.loadAssetsHookForTesting = { _ in
            [makeAsset(id: rawAssetId)]
        }
        disabledVM.initialPhotoLoadHookForTesting = { _ in }
        disabledVM.backgroundPreloadHookForTesting = { _, _, _ in }

        var capturedLines: [String] = []
        disabledVM.qaPlaybackSequenceOSLogEmitterForTesting = { capturedLines.append($0) }

        await disabledVM.prepareInitialAssets()
        completeCurrentScenePresentation(disabledVM)
        #expect(capturedLines.isEmpty)

        let enabledVM = SlideShowViewModel(source: .random)
        resetDownloadManagerState(enabledVM.downloadManager)
        enabledVM.loadAssetsHookForTesting = { _ in
            [makeAsset(id: rawAssetId)]
        }
        enabledVM.initialPhotoLoadHookForTesting = { _ in }
        enabledVM.backgroundPreloadHookForTesting = { _, _, _ in }
        enabledVM.qaPlaybackSequenceEvidenceEnabledForTesting = true
        enabledVM.qaPlaybackSequenceOSLogEmitterForTesting = { capturedLines.append($0) }
        await enabledVM.prepareInitialAssets()
        completeCurrentScenePresentation(enabledVM)

        let displayLines = capturedLines.filter { $0.hasPrefix("qa_playback_sequence ") }
        #expect(displayLines.count == 1)
        let line = displayLines[0]
        #expect(line.hasPrefix("qa_playback_sequence "))
        #expect(line.contains("assetStableId=asset_"))
        #expect(line.contains("sceneStableId=asset_"))
        #expect(line.contains("recentWindow=empty"))
        #expect(line.contains("duplicateInWindow=false"))
        #expect(line.contains("windowDuplicateSummary=none"))
        #expect(line.contains(rawAssetId) == false)
    }

    @Test
    func `QA playback sequence evidence records only committed and displayed assets`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.qaPlaybackSequenceEvidenceEnabledForTesting = true
        var capturedLines: [String] = []
        vm.qaPlaybackSequenceOSLogEmitterForTesting = { capturedLines.append($0) }
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        let assets = [
            makeAsset(id: "asset-a-raw"),
            makeAsset(id: "asset-b-raw")
        ]
        markReady(assets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)
        capturedLines.removeAll()

        vm.requestNextScene()
        #expect(capturedLines.isEmpty)
        completeCurrentScenePresentation(vm)

        let displayLines = capturedLines.filter { $0.hasPrefix("qa_playback_sequence ") }
        let eventLines = capturedLines.filter { $0.hasPrefix("qa_playback_sequence_event ") }
        #expect(displayLines.count == 1)
        #expect(displayLines[0].contains("assetStableId=asset_"))
        #expect(displayLines[0].contains("asset-b-raw") == false)
        #expect(eventLines.contains { $0.contains("eventType=loadMoreDecision") })
        #expect(capturedLines.joined(separator: "\n").contains("asset-b-raw") == false)
    }

    @Test
    func `real next and previous navigation switches scenes through the transition token`() async {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        let assets = [
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b")
        ]
        markReady(assets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)
        let initialToken = vm.targetTransitionToken

        vm.requestNextScene()
        let nextToken = vm.targetTransitionToken
        let nextTargetIndex = vm.targetIndex
        #expect(nextToken != initialToken)
        completeCurrentScenePresentation(vm)

        vm.requestPreviousScene()
        #expect(vm.targetTransitionToken != nextToken)
        let previousTargetIndex = vm.targetIndex
        #expect(previousTargetIndex == nextTargetIndex)

        completeCurrentScenePresentation(vm)

        #expect(vm.safeCurrentScene?.primaryAssetId == "asset-a")
        #expect(vm.canRequestPreviousScene == false)
    }

    @Test
    func `a new scene with the same numeric targetIndex is exposed through a new transition token`() {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        let assets = [
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b")
        ]
        markReady(assets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)

        vm.requestNextScene()
        let firstToken = vm.targetTransitionToken
        let firstTargetIndex = vm.targetIndex
        let firstSceneId = vm.scene(at: firstTargetIndex)?.id
        completeCurrentScenePresentation(vm)

        vm.requestPreviousScene()

        #expect(vm.targetIndex == firstTargetIndex)
        #expect(vm.targetTransitionToken != firstToken)
        #expect(vm.scene(at: vm.targetIndex)?.id != firstSceneId)
    }

    @Test
    func `a stale transition handler cannot commit a newer pending transition`() async throws {
        let vm = SlideShowViewModel(source: .random)
        resetDownloadManagerState(vm.downloadManager)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        vm.indexChangePhotoLoadHookForTesting = { _, _ in }
        let assets = [
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b"),
            makeAsset(id: "asset-c")
        ]
        markReady(assets, in: vm.downloadManager)
        vm.replacePlaybackAssetsForTesting(assets)
        completeCurrentScenePresentation(vm)
        var delayedEntry: CheckedContinuation<Void, Never>?

        vm.requestNextScene()
        let firstPendingToken = vm.targetTransitionToken
        let firstPendingTargetIndex = vm.targetIndex
        let firstPendingSceneId = vm.scene(at: vm.targetIndex)?.id
        let oldHandlerTask = Task {
            await withCheckedContinuation { pending in
                delayedEntry = pending
            }
            await vm.synchronizePlaybackReadbackForTesting(
                token: firstPendingToken, targetIndex: firstPendingTargetIndex)
        }
        let didSuspend = await waitUntil { delayedEntry != nil }
        try #require(didSuspend, "Timed out waiting for delayedEntry to be captured")

        vm.requestNextScene()
        let newerPendingSceneId = vm.scene(at: vm.targetIndex)?.id
        #expect(newerPendingSceneId != firstPendingSceneId)
        #expect(vm.scene(at: vm.targetIndex)?.primaryAssetId == "asset-c")

        delayedEntry?.resume()
        await oldHandlerTask.value

        #expect(vm.currentIndex == 2)
        #expect(vm.scene(at: vm.targetIndex)?.id == newerPendingSceneId)
    }
}

struct PersistentPlaybackSnapshot {
    let settings: PlaybackSettings?
    let selection: FilterSelection?

    static func capture() -> PersistentPlaybackSnapshot {
        PersistentPlaybackSnapshot(
            settings: PlaybackSettingsStore().load(),
            selection: FilterSelectionStore().load()
        )
    }

    func restore() {
        let settingsStore = PlaybackSettingsStore()
        if let settings {
            settingsStore.save(settings)
        } else {
            settingsStore.clear()
        }

        let selectionStore = FilterSelectionStore()
        if let selection {
            selectionStore.save(selection)
        } else {
            selectionStore.clear()
        }
    }
}
