// After switching servers, old album/person IDs must disappear from FilterViewModel and the Store; without a
// seed, no fake album may be written.

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.serialized, .sharedRuntimeIsolation)
struct FilterSelectionResetTests {

    @Test(arguments: [false, true])
    func `filtered playback is available only while an album or person remains selected`(isPersonSelection: Bool) {
        let store = InMemoryFilterSelectionStore()
        let viewModel = FilterViewModel(store: store)
        #expect(!viewModel.canStartPlayback)

        if isPersonSelection {
            viewModel.setPersonMatchMode(id: "selected-person", mode: .soloOnly)
        } else {
            viewModel.toggleAlbum(id: "selected-album")
        }
        #expect(viewModel.canStartPlayback)
        #expect(FilterViewModel(store: store).canStartPlayback)

        if isPersonSelection {
            viewModel.removeAllPersonSelection()
        } else {
            viewModel.removeAllAlbumSelection()
        }
        #expect(!viewModel.canStartPlayback)
        #expect(!FilterViewModel(store: store).canStartPlayback)
    }

    @Test(.sharedPlaybackRuntimeIsolation, arguments: ["a", "b"])
    func `playback entry reloads a stored changed album selection`(fixtureName: String)
        async throws
    {
        let fixture = FilterRuleFixture(name: fixtureName)
        var settings = PlaybackSettings()
        settings.defaultPlaybackMode = .filtered
        settings.autoPlayEnabled = false
        PlaybackSettingsStore().save(settings)
        let original = FilterSelection(albumIds: [fixture.targetAlbumID])
        FilterSelectionStore().save(original)
        let viewModel = SlideShowViewModel(source: .filtered(original))
        viewModel.initialPhotoLoadHookForTesting = { _ in }
        viewModel.backgroundPreloadHookForTesting = { _, _, _ in }
        viewModel.loadAssetsHookForTesting = { source in
            guard case .filtered(let selection) = source else {
                Issue.record("Returning from a nonempty filter edit must keep filtered playback")
                return []
            }
            switch selection.albumIds {
            case [fixture.targetAlbumID]: return fixture.targetAlbumAssets
            case ["album-\(fixtureName)-non-target"]: return Array(fixture.assets[3...4])
            default: return []
            }
        }
        await viewModel.loadAssets()
        try #require(viewModel.assets.map(\.id) == fixture.targetAlbumAssets.map(\.id))

        let replacement = FilterSelection(albumIds: ["album-\(fixtureName)-non-target"])
        FilterSelectionStore().save(replacement)
        viewModel.refreshPlaybackRelatedSettings(applyExifVisibility: { _ in }, applyDebugOverlayVisibility: { _ in })
        try #require(
            await waitUntil { !viewModel.isLoading && viewModel.assets.map(\.id) == fixture.assets[3...4].map(\.id) })
        #expect(!viewModel.shouldReloadFilteredSource(for: replacement))
        #expect(viewModel.currentPlaybackMode == .filtered)
    }

    @Test(arguments: ["a", "b"])
    func `album picker toggles and bulk selection persist exact counts across returning`(fixtureName: String) async {
        let fixture = FilterRuleFixture(name: fixtureName)
        let store = InMemoryFilterSelectionStore()
        let api = FilterPickerAPIService(fixture: fixture)
        let viewModel = FilterViewModel(store: store, apiService: api)
        await viewModel.getCoverURLs(filterType: .albums, coverLimit: nil, shouldReset: true)

        #expect(viewModel.albums.map(\.id) == fixture.albums.map(\.id))
        #expect(viewModel.selectedAlbumCount == 0)
        viewModel.toggleAlbum(id: fixture.targetAlbumID)
        #expect(viewModel.isAlbumSelected(id: fixture.targetAlbumID))
        #expect(viewModel.selectedAlbumCount == 1)
        #expect(viewModel.selectedAlbumAssetsCount == (fixtureName == "a" ? 3 : 6))
        #expect(FilterViewModel(store: store, apiService: api).selection.albumIds == [fixture.targetAlbumID])
        viewModel.toggleAlbum(id: fixture.targetAlbumID)
        #expect(!viewModel.isAlbumSelected(id: fixture.targetAlbumID))
        #expect(viewModel.selectedAlbumCount == 0)
        #expect(viewModel.selectedAlbumAssetsCount == 0)
        #expect(store.load()?.albumIds == [])

        viewModel.selectAllAlbum()
        let returned = FilterViewModel(store: store, apiService: api)
        await returned.getCoverURLs(filterType: .albums, coverLimit: nil, shouldReset: true)
        #expect(Set(returned.selection.albumIds) == Set(fixture.albums.map(\.id)))
        #expect(returned.selectedAlbumCount == 3)
        #expect(returned.selectedAlbumAssetsCount == (fixtureName == "a" ? 5 : 8))
        returned.removeAllAlbumSelection()
        #expect(returned.selectedAlbumCount == 0)
        #expect(returned.selectedAlbumAssetsCount == 0)
        #expect(FilterViewModel(store: store, apiService: api).selection.isEmpty)
    }

    @Test(arguments: ["a", "b"])
    func `person picker retains normal and solo modes through select all and returning`(fixtureName: String) async {
        let fixture = FilterRuleFixture(name: fixtureName)
        let store = InMemoryFilterSelectionStore()
        let api = FilterPickerAPIService(fixture: fixture)
        let viewModel = FilterViewModel(store: store, apiService: api)
        await viewModel.getCoverURLs(filterType: .people, coverLimit: nil, shouldReset: true)

        viewModel.togglePerson(id: fixture.normalPersonID)
        viewModel.setPersonMatchMode(id: fixture.soloPersonID, mode: .soloOnly)
        #expect(viewModel.getPersonMatchMode(id: fixture.normalPersonID) == .normal)
        #expect(viewModel.getPersonMatchMode(id: fixture.soloPersonID) == .soloOnly)
        viewModel.selectAllPerson()
        viewModel.selectAllPerson()

        let returned = FilterViewModel(store: store, apiService: api)
        #expect(returned.selectedPersonIDs == Set(fixture.people.map(\.id)))
        #expect(returned.selectedPersonCount == 4)
        #expect(returned.getPersonMatchMode(id: fixture.soloPersonID) == .soloOnly)
        #expect(returned.getPersonMatchMode(id: fixture.normalPersonID) == .normal)
        #expect(returned.getPersonMatchMode(id: fixture.noFacesPersonID) == .normal)

        returned.togglePerson(id: fixture.normalPersonID)
        #expect(!returned.isPersonSelected(id: fixture.normalPersonID))
        #expect(returned.selectedPersonCount == 3)
        returned.togglePerson(id: fixture.normalPersonID)
        #expect(returned.getPersonMatchMode(id: fixture.normalPersonID) == .normal)
        returned.setPersonMatchMode(id: fixture.soloPersonID, mode: .normal)
        #expect(returned.selectedPersonCount == 4)
        #expect(FilterViewModel(store: store, apiService: api).getPersonMatchMode(id: fixture.soloPersonID) == .normal)
        returned.removeAllPersonSelection()
        #expect(returned.selectedPersonCount == 0)
        #expect(FilterViewModel(store: store, apiService: api).selection.isEmpty)
    }

    @Test
    func `person counts use fetched statistics once and sum only selected people`() async {
        let fixture = FilterRuleFixture(name: "a")
        let api = FilterPickerAPIService(fixture: fixture)
        let viewModel = FilterViewModel(store: InMemoryFilterSelectionStore(), apiService: api)
        #expect(viewModel.selectedPersonAssetsCount == 0)
        viewModel.togglePerson(id: fixture.soloPersonID)
        #expect(viewModel.selectedPersonAssetsCount == 0)
        await viewModel.loadPersonAssetsCountIfNeeded(id: fixture.soloPersonID)
        await viewModel.loadPersonAssetsCountIfNeeded(id: fixture.soloPersonID)
        await viewModel.loadPersonAssetsCountIfNeeded(id: fixture.normalPersonID)
        #expect(api.countRequests == [fixture.soloPersonID, fixture.normalPersonID])
        #expect(viewModel.selectedPersonAssetsCount == 3)
        viewModel.togglePerson(id: fixture.normalPersonID)
        #expect(viewModel.selectedPersonAssetsCount == 4)
        viewModel.togglePerson(id: fixture.soloPersonID)
        #expect(viewModel.selectedPersonAssetsCount == 1)
        viewModel.removeAllPersonSelection()
        #expect(viewModel.selectedPersonAssetsCount == 0)
    }

    @Test
    func `reset removes old album and person ids so a new store instance cannot read them`() {
        let snapshot = FilterSelectionDefaultsSnapshot.captureAndClear()
        defer { snapshot.restore() }

        let viewModel = FilterViewModel()
        viewModel.selection = FilterSelection(
            albumIds: ["old-album"],
            personFilters: [PersonFilter(personId: "old-person", matchMode: .normal)]
        )

        #expect(viewModel.selection.albumIds == ["old-album"])
        #expect(viewModel.selection.personFilters.map(\.personId) == ["old-person"])
        #expect(FilterSelectionStore().load()?.albumIds == ["old-album"])
        #expect(FilterSelectionStore().load()?.personFilters.map(\.personId) == ["old-person"])

        viewModel.resetForServerConfigurationChange()

        #expect(viewModel.selection.albumIds == [])
        #expect(viewModel.selection.personFilters == [])

        let loaded = FilterSelectionStore().load()
        #expect(loaded?.albumIds.contains("old-album") != true)
        #expect(loaded?.personFilters.contains(where: { $0.personId == "old-person" }) != true)
    }

    @Test
    func `reset without a seed environment variable does not write back the ui-test-album-id`() {
        let snapshot = FilterSelectionDefaultsSnapshot.captureAndClear()
        defer { snapshot.restore() }

        #expect(ProcessInfo.processInfo.environment["UI_TEST_SEED_FILTER_SELECTION"] != "1")

        let viewModel = FilterViewModel()
        viewModel.selection = FilterSelection(albumIds: ["old-album"])
        viewModel.resetForServerConfigurationChange()

        #expect(!viewModel.selection.albumIds.contains("ui-test-album-id"))
        #expect(FilterSelectionStore().load()?.albumIds.contains("ui-test-album-id") != true)
    }

    @Test
    func `store clear removes the old album id so a new store instance cannot read it`() {
        let snapshot = FilterSelectionDefaultsSnapshot.captureAndClear()
        defer { snapshot.restore() }

        FilterSelectionStore().save(FilterSelection(albumIds: ["old-album"]))
        #expect(FilterSelectionStore().load()?.albumIds.contains("old-album") == true)

        FilterSelectionStore().clear()

        #expect(FilterSelectionStore().load()?.albumIds.contains("old-album") != true)
    }
}

// The public A/B fixtures differ by three person-free photos in B's target album.
struct FilterRuleFixture {
    let name: String
    var targetAlbumID: String { "album-\(name)-target" }
    var normalPersonID: String { "person-\(name)-normal" }
    var soloPersonID: String { "person-\(name)-solo" }
    var noFacesPersonID: String { "person-\(name)-no-faces" }
    var people: [People] {
        ["normal", "solo", "other", "no-faces"].map {
            People(id: "person-\(name)-\($0)", name: $0, isHidden: false, isFavorite: false)
        }
    }
    var albums: [Album] {
        [
            Album(
                id: targetAlbumID, albumName: "Target", albumThumbnailAssetId: nil,
                assetCount: name == "a" ? 3 : 6, assets: []),
            Album(
                id: "album-\(name)-non-target", albumName: "Other", albumThumbnailAssetId: nil,
                assetCount: 2, assets: []),
            Album(
                id: "album-\(name)-empty", albumName: "Empty", albumThumbnailAssetId: nil,
                assetCount: 0, assets: [])
        ]
    }
    var assets: [Asset] {
        let memberships = [[0], [1], [1, 2], [3], [1]] + (name == "b" ? [[], [], []] : [])
        return memberships.enumerated().map { index, members in
            Asset(
                id: "asset-\(name)-\(index + 1)", type: "IMAGE", isFavorite: false,
                isTrashed: false, isArchived: false, exifInfo: nil,
                people: members.map { people[$0] }, tags: nil, livePhotoVideoID: nil,
                unassignedFaces: index == 4 ? [UnassignedFace(id: "unassigned-\(name)")] : []
            )
        }
    }
    var targetAlbumAssets: [Asset] { Array(assets.prefix(3)) + Array(assets.dropFirst(5)) }
}

private final class InMemoryFilterSelectionStore: FilterSelectionStoring {
    private var selection: FilterSelection?
    func save(_ selection: FilterSelection) { self.selection = selection }
    func load() -> FilterSelection? { selection }
    func clear() { selection = nil }
    func seedUITestSelectionIfRequestedForTesting() -> FilterSelection? { nil }
}

private final class FilterPickerAPIService: FilterAPIService {
    let fixture: FilterRuleFixture
    var countRequests: [String] = []
    init(fixture: FilterRuleFixture) { self.fixture = fixture }
    func getAllAlbums(size: Int?) async throws -> [Album] { Array(fixture.albums.prefix(size ?? fixture.albums.count)) }
    func getAllPeople(size: Int?) async throws -> [People] {
        Array(fixture.people.prefix(size ?? fixture.people.count))
    }
    func getThumbnailURL(id: String, size: ThumbnailSize) async throws -> URL { throw URLError(.unsupportedURL) }
    func getPeopleThumbnailURL(id: String) async throws -> URL { throw URLError(.unsupportedURL) }
    func getPersonAssetsCount(id: String) async throws -> Int {
        countRequests.append(id)
        return fixture.assets.filter { $0.people?.contains(where: { $0.id == id }) == true }.count
    }
}

/// Backs up and restores the `filterSelection` key and UI test seed environment variables so parallel test runs
/// remain isolated.
private struct FilterSelectionDefaultsSnapshot {
    private static let defaultsKey = "filterSelection"
    private static let seedEnvKey = "UI_TEST_SEED_FILTER_SELECTION"
    private static let seedJSONEnvKey = "UI_TEST_FILTER_SELECTION_JSON"

    let storedFilterSelectionData: Data?
    let previousSeed: String?
    let previousSeedJSON: String?

    static func captureAndClear() -> FilterSelectionDefaultsSnapshot {
        let snapshot = FilterSelectionDefaultsSnapshot(
            storedFilterSelectionData: UserDefaults.standard.data(forKey: defaultsKey),
            previousSeed: getenv(seedEnvKey).map { String(cString: $0) },
            previousSeedJSON: getenv(seedJSONEnvKey).map { String(cString: $0) }
        )
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        unsetenv(seedEnvKey)
        unsetenv(seedJSONEnvKey)
        return snapshot
    }

    func restore() {
        if let storedFilterSelectionData {
            UserDefaults.standard.set(storedFilterSelectionData, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
        restoreEnv(Self.seedEnvKey, previousSeed)
        restoreEnv(Self.seedJSONEnvKey, previousSeedJSON)
    }

    private func restoreEnv(_ key: String, _ value: String?) {
        if let value {
            _ = setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}
