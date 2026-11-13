import Foundation
import SDWebImage
import Testing
@testable import immichSlides

extension SlideShowViewModelStartupTests {
    private var fixtureKey: String { LateLoadRealPathFixture.fixtureCredential }

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

        fixture.serverA.releaseAll()
        await pendingReload?.value
        // These are the production playback-entry and Settings-dismissal callbacks, without SwiftUI.
        vm.refreshPlaybackRelatedSettings(applyExifVisibility: { _ in }, applyDebugOverlayVisibility: { _ in })
        await vm.firstPreload()
        await vm.forceReloadCurrentAssetAfterCacheClear()
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
        await vm.firstPreload()
        await vm.forceReloadCurrentAssetAfterCacheClear()

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
