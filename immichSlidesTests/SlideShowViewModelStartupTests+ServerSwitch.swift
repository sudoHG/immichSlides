import Foundation
import SDWebImage
import Testing
@testable import immichSlides

extension SlideShowViewModelStartupTests {
    private var fixtureKey: String { LateLoadRealPathFixture.fixtureCredential }
    private var serverSwitchCompletionTimeout: Duration { .seconds(TestWait.seconds(.product(8))) }

    @Test(arguments: [false, true], [false, true])
    func `saving a different server discards old playback and returns in random mode`(
        isFiltered: Bool, hasPendingReload: Bool
    ) async throws {
        let fixture = try await makeServerSwitchFixture(isFiltered: isFiltered)
        defer { fixture.stop() }
        let vm = fixture.player
        let oldSession = vm.playbackSession.currentSessionIdentity.playbackSessionId
        let oldAsset = try #require(vm.safeCurrentAsset?.id)
        try #require(!vm.retainedPlaybackHistoryRecipesForTesting.isEmpty)

        var pendingReload: Task<Void, Never>?
        if hasPendingReload {
            try #require(await waitUntil { vm.downloadManager.activeTaskCount == 0 })
            await vm.downloadManager.clearDiskCacheForSettings()
            SDImageCache.shared.clearMemory()
            fixture.serverA.hold(assetIds: [oldAsset])
            let priorRequestCount = fixture.serverA.enteredCount(assetId: oldAsset)
            pendingReload = Task { await vm.forceReloadCurrentAssetAfterCacheClear() }
            try #require(await waitUntil { fixture.serverA.enteredCount(assetId: oldAsset) > priorRequestCount })
        }
        defer { pendingReload?.cancel() }

        let settings = SettingsServerViewModel()
        settings.serverURL = fixture.urlB
        settings.apiKey = fixtureKey
        await settings.saveServerConfig().value
        try #require(settings.didSaveConfig)
        #expect(vm.playbackSession.currentSessionIdentity.playbackSessionId != oldSession)
        #expect(vm.assets.isEmpty)
        #expect(vm.safeCurrentScene == nil)
        #expect(vm.sceneRenderSnapshot.layers.isEmpty)
        #expect(vm.retainedPlaybackHistoryRecipesForTesting.isEmpty)
        #expect(vm.currentPlaybackMode == .random)
        #expect(PlaybackSettingsStore().load()?.defaultPlaybackMode == .random)
        #expect(FilterSelectionStore().load()?.isEmpty != false)
        if case .filtered = ContentView.initialPlaybackSourceForColdLaunch() {
            Issue.record("A cold launch after changing servers must use random playback")
        }
        let requestsAAfterSave = fixture.serverA.enteredRequests()

        fixture.serverA.releaseAll()
        await pendingReload?.value
        vm.refreshPlaybackRelatedSettings(applyExifVisibility: { _ in }, applyDebugOverlayVisibility: { _ in })
        let coordinator = ContentPlaybackCoordinator(viewModel: vm)
        coordinator.flow.initializeRoute(isServerConfigured: true)
        await coordinator.settingsDidDisappear()
        completePausedServerSwitchScene(vm)

        #expect(vm.didFirstPreload)
        #expect(vm.currentPlaybackMode == .random)
        #expect(vm.assets.map(\.id) == fixture.assetsB.map(\.id))
        #expect(vm.safeCurrentAsset?.id == fixture.assetsB.first?.id)
        #expect(!vm.canRequestPreviousScene)
        #expect(vm.retainedPlaybackHistoryRecipesForTesting.flatMap(\.assetIds) == [fixture.assetsB[0].id])
        let requestsB = fixture.serverB.enteredRequests()
        #expect(requestsB.contains { $0.assetId == fixture.assetsB[0].id })
        #expect(requestsB.allSatisfy { $0.assetId == nil || fixture.assetsB.map(\.id).contains($0.assetId!) })
        #expect(!requestsB.contains { $0.path.contains("asset-a-") })
        #expect(fixture.serverA.enteredRequests() == requestsAAfterSave)
    }

    @Test(arguments: [false, true])
    func `saving the same server preserves the running playback session and default mode`(isFiltered: Bool)
        async throws
    {
        let fixture = try await makeServerSwitchFixture(isFiltered: isFiltered)
        defer { fixture.stop() }
        let vm = fixture.player
        let session = vm.playbackSession.currentSessionIdentity.playbackSessionId
        let scene = vm.safeCurrentScene?.id
        let sourceGeneration = vm.playbackSourceGeneration
        let history = vm.retainedPlaybackHistoryRecipesForTesting.map(\.id)
        let selection = FilterSelectionStore().load()
        let searchesBeforeSave = fixture.serverA.enteredRequests().filter { $0.path == "/api/search/random" }.count
        let settings = SettingsServerViewModel()
        settings.serverURL = fixture.urlA
        settings.apiKey = fixtureKey

        await settings.saveServerConfig().value
        try #require(settings.didSaveConfig)
        let searchesAfterSave = fixture.serverA.enteredRequests().filter { $0.path == "/api/search/random" }.count
        vm.refreshPlaybackRelatedSettings(applyExifVisibility: { _ in }, applyDebugOverlayVisibility: { _ in })
        await ContentPlaybackCoordinator(viewModel: vm).settingsDidDisappear()

        #expect(vm.playbackSession.currentSessionIdentity.playbackSessionId == session)
        #expect(vm.safeCurrentScene?.id == scene)
        #expect(vm.playbackSourceGeneration == sourceGeneration)
        #expect(vm.retainedPlaybackHistoryRecipesForTesting.map(\.id) == history)
        #expect(Set(vm.assets.map(\.id)) == Set(fixture.assetsA.map(\.id)))
        #expect(vm.currentPlaybackMode == (isFiltered ? .filtered : .random))
        #expect(PlaybackSettingsStore().load()?.defaultPlaybackMode == (isFiltered ? .filtered : .random))
        #expect(FilterSelectionStore().load() == selection)
        // Save performs one connection probe, but returning must not acquire another playback pool.
        #expect(searchesAfterSave == searchesBeforeSave + 1)
        #expect(fixture.serverA.enteredRequests().filter { $0.path == "/api/search/random" }.count == searchesAfterSave)
        #expect(fixture.serverB.enteredRequests().isEmpty)
    }

    @Test
    func `a server save finishing after Settings closes restarts playback from the change event`() async throws {
        let fixture = try await makeServerSwitchFixture(isFiltered: true)
        defer { fixture.stop() }
        let vm = fixture.player
        let coordinator = ContentPlaybackCoordinator(viewModel: vm)
        coordinator.flow.handleFirstBootConfigured(isServerConfigured: true)
        coordinator.flow.handleOnboardingModeDone(.filtered)
        coordinator.flow.handleFilteredPlaybackStarted()
        let oldSession = vm.playbackSession.currentSessionIdentity.playbackSessionId
        fixture.serverB.hold(assetIds: [fixture.assetsB[0].id])
        let settings = SettingsServerViewModel()
        settings.serverURL = fixture.urlB
        settings.apiKey = fixtureKey
        let save = settings.saveServerConfig()
        defer { save.cancel(); fixture.serverB.releaseAll() }
        try #require(await waitUntil { fixture.serverB.enteredCount(assetId: fixture.assetsB[0].id) > 0 })

        // Back runs while the real connection probe is suspended on B's thumbnail.
        await coordinator.settingsDidDisappear()
        try #require(vm.playbackSession.currentSessionIdentity.playbackSessionId == oldSession)
        fixture.serverB.releaseAll()
        await save.value
        try #require(settings.didSaveConfig)
        let requestsAAfterSave = fixture.serverA.enteredRequests()
        try #require(await waitUntil(timeout: serverSwitchCompletionTimeout) { vm.didFirstPreload && !vm.isLoading })
        completePausedServerSwitchScene(vm)
        #expect(vm.currentPlaybackMode == .random)
        #expect(vm.safeCurrentAsset?.id == fixture.assetsB[0].id)
        #expect(fixture.serverA.enteredRequests() == requestsAAfterSave)
        #expect(
            fixture.serverB.enteredRequests().allSatisfy {
                $0.assetId == nil || fixture.assetsB.map(\.id).contains($0.assetId!)
            })
        // Repeated dismissal joins/completes the same entry; it must not acquire another pool.
        let searches = fixture.serverB.enteredRequests().filter { $0.path == "/api/search/random" }.count
        await coordinator.settingsDidDisappear()
        #expect(fixture.serverB.enteredRequests().filter { $0.path == "/api/search/random" }.count == searches)
    }

    @Test
    func `a first server save clears stale filters and caches without restarting or rewriting the default`()
        async throws
    {
        let fixture = try await makeServerSwitchFixture(isFiltered: true)
        defer { fixture.stop() }
        ImmichServer.clearSavedConfiguration()
        try #require(ImmichServer.load() == nil)
        let session = fixture.player.playbackSession.currentSessionIdentity.playbackSessionId
        let oldAsset = try #require(fixture.player.safeCurrentAsset?.id)
        try #require(fixture.player.downloadManager.findURL(assetId: oldAsset, size: .fullsize) != nil)
        try #require(FilterSelectionStore().load()?.isEmpty == false)
        var changes: [Notification.Name] = []
        let observers = [Notification.Name.serverConfigurationWillChange, .serverConfigurationDidChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { changes.append(name) }
            }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        let coordinator = ContentPlaybackCoordinator(viewModel: fixture.player)
        #expect(coordinator.flow.route == .firstBoot)
        let settings = SettingsServerViewModel()
        settings.serverURL = fixture.urlB
        settings.apiKey = fixtureKey
        await settings.saveServerConfig().value

        try #require(settings.didSaveConfig)
        #expect(changes == [.serverConfigurationDidChange])
        #expect(fixture.player.playbackSession.currentSessionIdentity.playbackSessionId == session)
        #expect(PlaybackSettingsStore().load()?.defaultPlaybackMode == .filtered)
        #expect(FilterSelectionStore().load()?.isEmpty != false)
        #expect(fixture.player.downloadManager.findURL(assetId: oldAsset, size: .fullsize) == nil)
        #expect(fixture.serverB.enteredRequests().filter { $0.path == "/api/search/random" }.count == 1)
    }

    @Test
    func `saving a different key at the same URL restarts random playback for the new library`() async throws {
        let fixture = try await makeServerSwitchFixture(isFiltered: true)
        defer { fixture.stop() }
        let vm = fixture.player
        let coordinator = ContentPlaybackCoordinator(viewModel: vm)
        coordinator.flow.initializeRoute(isServerConfigured: true)
        let session = vm.playbackSession.currentSessionIdentity.playbackSessionId
        fixture.serverA.setRandomAssetsResponse(try JSONEncoder().encode(fixture.assetsB))
        let settings = SettingsServerViewModel()
        settings.serverURL = fixture.urlA
        settings.apiKey = fixtureKey + "-second-account"
        await settings.saveServerConfig().value
        try #require(settings.didSaveConfig)
        try #require(await waitUntil { vm.didFirstPreload && !vm.isLoading })
        completePausedServerSwitchScene(vm)
        #expect(vm.playbackSession.currentSessionIdentity.playbackSessionId != session)
        #expect(vm.currentPlaybackMode == .random)
        #expect(PlaybackSettingsStore().load()?.defaultPlaybackMode == .random)
        #expect(vm.safeCurrentAsset?.id == fixture.assetsB[0].id)
        #expect(FilterSelectionStore().load()?.isEmpty != false)
        #expect(fixture.serverB.enteredRequests().isEmpty)
    }

    @Test
    func `an already cancelled photo load never starts an independent download`() async throws {
        let fixture = try await makeServerSwitchFixture(isFiltered: false)
        defer { fixture.stop() }
        let manager = fixture.player.downloadManager
        let assetId = "cancelled-photo-\(UUID().uuidString)"
        try #require(manager.findURL(assetId: assetId, size: .fullsize) == nil)
        let cancelledLoad = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(Task.isCancelled)
            await manager.loadPhoto(assetId: assetId, size: .fullsize, priority: .high)
        }
        await cancelledLoad.value
        #expect(fixture.serverA.enteredCount(assetId: assetId) == 0)
        #expect(manager.findURL(assetId: assetId, size: .fullsize) == nil)
        #expect(!manager.isReady(assetId: assetId, size: .fullsize))
    }

    @Test
    func `a server switch cancels solo person refill before more candidates or rounds reach either server`()
        async throws
    {
        let fixture = try await makeServerSwitchFixture(isFiltered: true)
        defer { fixture.stop() }
        let vm = fixture.player
        try #require(await waitUntil { vm.downloadManager.activeTaskCount == 0 })
        let personId = "person-a-\(UUID().uuidString)"
        let selection = FilterSelection(personFilters: [PersonFilter(personId: personId, matchMode: .soloOnly)])
        vm.preparePlaybackSourceForPresentation(to: .filtered(selection))
        vm.replacePlaybackAssetsForTesting(fixture.assetsA)
        try #require(vm.isSoloOnlyPlaybackSource)
        let refillAssets = (1...4).map {
            makeAsset(
                id: "refill-a-\(UUID().uuidString)-\($0)",
                people: [People(id: personId, name: "Fixture person", isHidden: false, isFavorite: false)])
        }
        fixture.serverA.setRandomAssetsResponse(try JSONEncoder().encode(refillAssets))
        fixture.serverA.hold(assetIds: Set(refillAssets.map(\.id)))
        let coordinator = ContentPlaybackCoordinator(viewModel: vm)
        coordinator.flow.initializeRoute(isServerConfigured: true)
        let refill = Task { await vm.loadMoreAssets() }
        defer { refill.cancel(); fixture.serverA.releaseAll() }
        try #require(
            await waitUntil { refillAssets.prefix(2).allSatisfy { fixture.serverA.enteredCount(assetId: $0.id) > 0 } })
        try #require(vm.isLoadingMore)
        let settings = SettingsServerViewModel()
        settings.serverURL = fixture.urlB
        settings.apiKey = fixtureKey
        await settings.saveServerConfig().value
        try #require(settings.didSaveConfig)
        let requestsAAfterSave = fixture.serverA.enteredRequests()
        fixture.serverA.releaseAll()
        await refill.value
        try #require(await waitUntil { vm.didFirstPreload && !vm.isLoading })
        completePausedServerSwitchScene(vm)

        #expect(vm.currentPlaybackMode == .random)
        #expect(vm.safeCurrentAsset?.id == fixture.assetsB[0].id)
        #expect(!vm.isLoadingMore)
        #expect(fixture.serverA.enteredRequests() == requestsAAfterSave)
        #expect(
            fixture.serverB.enteredRequests().allSatisfy {
                ($0.assetId == nil || fixture.assetsB.map(\.id).contains($0.assetId!))
                    && !$0.path.contains(personId)
                    && !String(decoding: $0.body, as: UTF8.self).contains(personId)
            })
    }

    @Test
    func `a server switch cancels the settings solo person load before old IDs or the new key leak`() async throws {
        let fixture = try await makeServerSwitchFixture(isFiltered: true)
        defer { fixture.stop() }
        let vm = fixture.player
        try #require(await waitUntil { vm.downloadManager.activeTaskCount == 0 })
        let personId = "person-a-\(UUID().uuidString)"
        let selection = FilterSelection(personFilters: [PersonFilter(personId: personId, matchMode: .soloOnly)])
        FilterSelectionStore().save(selection)
        let candidates = (1...4).map {
            makeAsset(
                id: "settings-a-\(UUID().uuidString)-\($0)",
                people: [People(id: personId, name: "Fixture person", isHidden: false, isFavorite: false)])
        }
        fixture.serverA.setRandomAssetsResponse(try JSONEncoder().encode(candidates))
        fixture.serverA.hold(assetIds: Set(candidates.map(\.id)))
        let coordinator = ContentPlaybackCoordinator(viewModel: vm)
        coordinator.flow.initializeRoute(isServerConfigured: true)
        vm.refreshPlaybackRelatedSettings(applyExifVisibility: { _ in }, applyDebugOverlayVisibility: { _ in })
        defer { fixture.serverA.releaseAll() }
        try #require(
            await waitUntil { candidates.prefix(2).allSatisfy { fixture.serverA.enteredCount(assetId: $0.id) > 0 } })
        try #require(vm.isSoloOnlyPlaybackSource && vm.isLoading)
        let settings = SettingsServerViewModel()
        let newKey = fixtureKey + "-server-b"
        settings.serverURL = fixture.urlB
        settings.apiKey = newKey
        await settings.saveServerConfig().value
        try #require(settings.didSaveConfig)
        let requestsAAfterSave = fixture.serverA.enteredRequests()
        fixture.serverA.releaseAll()
        await coordinator.settingsDidDisappear()
        try #require(await waitUntil { vm.didFirstPreload && !vm.isLoading })
        completePausedServerSwitchScene(vm)

        #expect(vm.currentPlaybackMode == .random)
        #expect(vm.safeCurrentAsset?.id == fixture.assetsB[0].id)
        #expect(fixture.serverA.enteredRequests() == requestsAAfterSave)
        #expect(!fixture.serverA.enteredRequests().contains { $0.apiKey == newKey })
        #expect(
            fixture.serverB.enteredRequests().allSatisfy {
                ($0.assetId == nil || fixture.assetsB.map(\.id).contains($0.assetId!))
                    && !$0.path.contains(personId)
                    && !String(decoding: $0.body, as: UTF8.self).contains(personId)
                    && !String(decoding: $0.body, as: UTF8.self).contains("settings-a-")
            })
    }

    @MainActor private struct ServerSwitchFixture {
        let serverA: LateLoadLocalHTTPFixture
        let serverB: LateLoadLocalHTTPFixture
        let player: SlideShowViewModel
        let assetsA: [Asset]
        let assetsB: [Asset]
        var urlA: String { "http://127.0.0.1:\(serverA.port)" }
        var urlB: String { "http://127.0.0.1:\(serverB.port)" }

        func stop() {
            player.preparePlaybackSourceForPresentation(to: .random)
            LateLoadRealPathTestSupport.resetDownloadManager(player.downloadManager)
            serverA.stop()
            serverB.stop()
        }
    }

    private func makeServerSwitchFixture(isFiltered: Bool) async throws -> ServerSwitchFixture {
        let runID = UUID().uuidString
        let assetsA = (1...3).map { makeAsset(id: "asset-a-\(runID)-\($0)") }
        let assetsB = (1...3).map { makeAsset(id: "asset-b-\(runID)-\($0)") }
        let serverA = LateLoadLocalHTTPFixture(randomAssetsResponse: try JSONEncoder().encode(assetsA))
        let serverB = LateLoadLocalHTTPFixture(randomAssetsResponse: try JSONEncoder().encode(assetsB))
        try await serverA.start()
        do { try await serverB.start() } catch { serverA.stop(); throw error }
        try #require(
            LateLoadRealPathTestSupport.installIsolatedFixtureServer(
                port: serverA.port, credential: LateLoadRealPathFixture.fixtureCredential))
        var settings = PlaybackSettings()
        settings.defaultPlaybackMode = isFiltered ? .filtered : .random
        settings.autoPlayEnabled = false
        settings.displayMode = .singlePhoto
        PlaybackSettingsStore().save(settings)
        let selection = FilterSelection(albumIds: ["album-a"])
        FilterSelectionStore().save(selection)
        let vm = SlideShowViewModel(source: isFiltered ? .filtered(selection) : .random, observeSettingsChanges: true)
        vm.scenePresentationTimestampProviderForTesting = { 0 }
        await vm.firstPreload()
        completePausedServerSwitchScene(vm)
        try #require(vm.didFirstPreload)
        try #require(assetsA.map(\.id).contains(vm.safeCurrentAsset?.id ?? ""))
        return ServerSwitchFixture(serverA: serverA, serverB: serverB, player: vm, assetsA: assetsA, assetsB: assetsB)
    }

    private func completePausedServerSwitchScene(_ vm: SlideShowViewModel) {
        completeCurrentScenePresentation(vm)
        // A paused initial photo can become stable without an incoming fade, but still needs a visible tick.
        if let layer = vm.sceneRenderSnapshot.layers.last(where: {
            $0.role == .stable && $0.isPresentationReady && $0.opacity == 1
        }) {
            vm.incomingBecameVisible(vm.scenePresentationLayerIdentity(for: layer))
        }
    }
}
