//
//  FilterViewModel.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/31.
//

import Foundation
import Combine
import SDWebImage

class FilterViewModel: ObservableObject {
    @Published var albums: [Album] = []
    @Published var people: [People] = []
    // Cover URLs are computed live from the byID dictionaries, so they cannot be @Published.
    var albumCoverURLs: [URL] { albums.compactMap { albumCoverURLByID[$0.id] } }
    var peopleCoverURLs: [URL] { people.compactMap { peopleCoverURLByID[$0.id] } }
    @Published var albumCoverURLByID: [String: URL] = [:]
    @Published var peopleCoverURLByID: [String: URL] = [:]

    @Published var albumLoadErrorMessage: String? = nil

    @Published var peopleLoadErrorMessage: String? = nil
    // Preload task handle, to prevent duplicate triggers.
    private var preloadTask: Task<Void, Never>? = nil

    @Published var selection: FilterSelection {
        didSet {
            store.save(selection)
        }
    }

    private let store: FilterSelectionStore = FilterSelectionStore()
    private var selectedAlbumIDs: Set<String> = []
    init() {

        selection = store.load() ?? FilterSelection()
        selectedAlbumIDs = Set(selection.albumIds)
    }

    var selectedAlbumCount: Int {
        return selectedAlbumIDs.count
    }
    var selectedAlbumAssetsCount: Int {

        let selectedSet = selectedAlbumIDs
        return
            albums

            .filter { album in selectedSet.contains(album.id) }

            .reduce(0) { sum, album in sum + album.assetCount }
    }

    var selectedPersonCount: Int {
        return selection.personFilters.count
    }

    var selectedPersonIDs: Set<String> {
        return Set(selection.personFilters.map(\.personId))
    }

    var selectedPersonAssetsCount: Int {
        var total: Int = 0

        for id in selectedPersonIDs {
            let count = personAssetsCountByID[id]
            total += count ?? 0
        }
        return total
    }

    // Read-only from outside so other code cannot change the per-person photo count cache.

    @Published private(set) var personAssetsCountByID: [String: Int] = [:]
    // IDs of people currently being queried, to avoid duplicate requests for the same person.
    private var loadingPersonStatsIDs: Set<String> = []

    // reset clears covers; false reuses them when growing from the warm-up set to the full list.
    // UI tests can force empty data or override with long person names.
    func getCoverURLs(filterType: FilterType, coverLimit: Int?, reset: Bool) async {
        let batchSize: Int = 10
        switch filterType {
        case .albums:
            #if DEBUG
            if shouldForceEmptyFilterData(filterType: .albums) {
                await MainActor.run {
                    self.albumLoadErrorMessage = nil
                    self.albums.removeAll()
                    self.albumCoverURLByID.removeAll()
                }
                return
            }
            #endif

            await MainActor.run {
                self.albumLoadErrorMessage = nil
            }
            if reset {
                await MainActor.run {
                    albums.removeAll()
                    albumCoverURLByID.removeAll()
                }
            }

            let fetchedAlbums: [Album]
            do {
                fetchedAlbums = try await ImmichAPIService.shared.getAllAlbums(size: coverLimit)
            } catch {
                await MainActor.run {
                    self.albumLoadErrorMessage = String(
                        localized: "Unable to load albums. Check your network or server settings.")
                }
                return
            }

            await MainActor.run {
                self.albums = fetchedAlbums
            }

            let existingIDs: Set<String> =
                reset
                ? []
                : await MainActor.run { Set(self.albumCoverURLByID.keys) }

            var newAlbumURLs: [String: URL] = [:]

            for start in stride(from: 0, to: fetchedAlbums.count, by: batchSize) {

                let end = min(start + batchSize, fetchedAlbums.count)

                let batch = fetchedAlbums[start..<end]

                await withTaskGroup(of: (String, URL?).self) { group in
                    for album in batch {
                        let albumID = album.id
                        if existingIDs.contains(albumID) { continue }

                        guard let thumbID = album.albumThumbnailAssetId, !thumbID.isEmpty else {
                            continue
                        }

                        group.addTask {
                            do {

                                let url = try await ImmichAPIService.shared.getThumbnailURL(
                                    id: thumbID, size: .thumbnail)
                                return (albumID, url)
                            } catch {
                                print("Failed to load album cover, id: \(albumID)", error)
                                return (albumID, nil)
                            }
                        }
                    }

                    for await (albumID, url) in group {
                        if let url {
                            newAlbumURLs[albumID] = url
                        }
                    }

                }
            }
            await MainActor.run {
                if reset {

                    albumCoverURLByID = newAlbumURLs
                } else {
                    albumCoverURLByID.merge(newAlbumURLs) { _, new in new }
                }
            }

        case .people:
            #if DEBUG
            if shouldForceEmptyFilterData(filterType: .people) {
                await MainActor.run {

                    self.peopleLoadErrorMessage = nil
                    self.people.removeAll()
                    self.peopleCoverURLByID.removeAll()
                    self.personAssetsCountByID.removeAll()
                }
                return
            }
            #endif

            await MainActor.run {
                self.peopleLoadErrorMessage = nil
            }
            if reset {
                await MainActor.run {
                    people.removeAll()
                    peopleCoverURLByID.removeAll()
                }
            }

            let fetchedPeople: [People]
            do {
                fetchedPeople = try await ImmichAPIService.shared.getAllPeople(size: coverLimit)
            } catch {
                await MainActor.run {
                    self.peopleLoadErrorMessage = String(
                        localized: "Unable to load people list. Check your network or server settings.")
                }
                return
            }

            let preparedPeople = peopleAdjustedForUITesting(fetchedPeople)

            await MainActor.run {
                people = preparedPeople
            }

            let existingPeopleIDs: Set<String> =
                reset
                ? []
                : await MainActor.run { Set(self.peopleCoverURLByID.keys) }

            var newPeopleURLs: [String: URL] = [:]
            for start in stride(from: 0, to: preparedPeople.count, by: batchSize) {
                let end = min(start + batchSize, preparedPeople.count)
                let batch = preparedPeople[start..<end]
                await withTaskGroup(of: (String, URL?).self) { group in
                    for person in batch {
                        if person.id.isEmpty { continue }
                        let peopleID = person.id
                        if existingPeopleIDs.contains(peopleID) { continue }
                        group.addTask {
                            do {
                                let url = try await ImmichAPIService.shared.getPeopleThumbnailURL(id: peopleID)
                                return (peopleID, url)
                            } catch {
                                print("Failed to fetch person thumbnail, id:", person.id, error)
                                return (peopleID, nil)
                            }
                        }
                    }

                    for await (peopleID, url) in group {
                        if let url {
                            newPeopleURLs[peopleID] = url
                        }
                    }

                }
            }
            await MainActor.run {
                if reset {
                    peopleCoverURLByID = newPeopleURLs
                } else {
                    peopleCoverURLByID.merge(newPeopleURLs) { _, new in new }
                }
            }
        }
    }

    #if DEBUG
    private func shouldForceEmptyFilterData(filterType: FilterType) -> Bool {

        let rawValue = ProcessInfo.processInfo.environment["UI_TEST_FORCE_EMPTY_FILTER_DATA"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let rawValue, rawValue.isEmpty == false else { return false }

        if rawValue == "1" || rawValue == "all" {
            return true
        }

        switch filterType {
        case .albums:
            return rawValue == "album" || rawValue == "albums"
        case .people:
            return rawValue == "person" || rawValue == "people"
        }
    }
    #endif

    private func peopleAdjustedForUITesting(_ people: [People]) -> [People] {

        guard ProcessInfo.processInfo.environment["UI_TEST_FORCE_LONG_PERSON_NAMES"] == "1" else {
            return people
        }

        let longNames: [String] = [
            "小王在京都岚山的秋天旅行纪念相册主角",
            "和外婆一起在青岛海边看日落的那个夏天",
            "毕业旅行里总是背着胶片相机的同学",
            "跨年夜在外滩等烟花的时候认识的新朋友"
        ]

        return people.enumerated().map { index, person in
            guard longNames.indices.contains(index) else { return person }

            var updatedPerson = person
            updatedPerson.name = longNames[index]
            return updatedPerson
        }
    }

    func preloadCovers(coverLimit: Int?, reset: Bool) {
        guard preloadTask == nil else { return }
        preloadTask = Task {
            defer { self.preloadTask = nil }
            async let a: Void = self.getCoverURLs(filterType: .albums, coverLimit: coverLimit, reset: reset)
            async let p: Void = self.getCoverURLs(filterType: .people, coverLimit: coverLimit, reset: reset)
            _ = await (a, p)
            if let coverLimit {
                let urls: [URL] = Array(albumCoverURLs.prefix(coverLimit)) + Array(peopleCoverURLs.prefix(coverLimit))
                await self.prefetchToSDWebImageCache(urls: urls)
            } else {
                let urls: [URL] = albumCoverURLs + peopleCoverURLs
                await self.prefetchToSDWebImageCache(urls: urls)
            }
        }

    }

    func isAlbumSelected(id: String) -> Bool {
        if selectedAlbumIDs.contains(id) {
            return true
        } else {
            return false
        }
    }

    func isPersonSelected(id: String) -> Bool {

        return selection.personFilters.contains { filter in
            filter.personId == id
        }
    }

    func getPersonMatchMode(id: String) -> PersonMatchMode? {

        let matchedFilter = selection.personFilters.first { filter in
            filter.personId == id
        }
        return matchedFilter?.matchMode
    }

    func setPersonMatchMode(id: String, mode: PersonMatchMode = .normal) {

        if let personIndex = selection.personFilters.firstIndex(where: { filter in
            filter.personId == id
        }) {
            selection.personFilters[personIndex].matchMode = mode
        } else {
            selection.personFilters.append(PersonFilter(personId: id, matchMode: mode))
        }
    }

    func toggleAlbum(id: String) {
        if selectedAlbumIDs.contains(id) {
            selectedAlbumIDs.remove(id)
        } else {
            selectedAlbumIDs.insert(id)
        }
        selection.albumIds = Array(selectedAlbumIDs).sorted()
    }

    func togglePerson(id: String) {

        if let personIndex = selection.personFilters.firstIndex(where: { filter in
            filter.personId == id
        }) {
            selection.personFilters.remove(at: personIndex)
        } else {
            selection.personFilters.append(PersonFilter(personId: id, matchMode: .normal))
        }
    }

    func removeAllAlbumSelection() {
        selectedAlbumIDs.removeAll()
        selection.albumIds.removeAll()
    }

    func selectAllAlbum() {

        let ids = Set(albums.map(\.id))
        selectedAlbumIDs = ids
        selection.albumIds = Array(selectedAlbumIDs).sorted()
    }

    func removeAllPersonSelection() {
        selection.personFilters.removeAll()
    }

    func selectAllPerson() {
        // Keep existing soloOnly when selecting all people.
        var existingModeByID: [String: PersonMatchMode] = [:]
        for filter in selection.personFilters {
            existingModeByID[filter.personId] = filter.matchMode
        }

        var allFilters: [PersonFilter] = []
        for person in people {
            guard !person.id.isEmpty else { continue }
            let mode = existingModeByID[person.id] ?? .normal
            allFilters.append(PersonFilter(personId: person.id, matchMode: mode))
        }

        selection.personFilters = allFilters
    }

    @MainActor
    func loadPersonAssetsCountIfNeeded(id: String) async {

        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        guard personAssetsCountByID[id] == nil else { return }

        guard loadingPersonStatsIDs.contains(id) == false else { return }
        loadingPersonStatsIDs.insert(id)
        do {
            defer { loadingPersonStatsIDs.remove(id) }
            let count = try await ImmichAPIService.shared.getPersonAssetsCount(id: id)
            personAssetsCountByID[id] = count
        } catch {
            if error is CancellationError { return }
            if let urlError = error as? URLError, urlError.code == .cancelled { return }
            print("Failed to load person asset count, id: \(id), error: \(error)")
        }
    }

    private func prefetchToSDWebImageCache(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard let modifier = ImmichRequestModifier.create() else { return }
        let context: [SDWebImageContextOption: Any] = [.downloadRequestModifier: modifier]
        await withCheckedContinuation { continuation in
            SDWebImagePrefetcher.shared.prefetchURLs(
                urls,
                options: [],
                context: context,
                progress: nil
            ) { _, _ in
                continuation.resume()
            }
        }
    }

    func resetForServerConfigurationChange() {
        preloadTask?.cancel()
        preloadTask = nil
        store.clear()

        // Switching servers must clear filters; the UI test seed is restored after clearing so the start button
        // is not disabled by mistake.

        if let seededSelection = store.seedUITestSelectionIfRequested() {
            selectedAlbumIDs = Set(seededSelection.albumIds)
            selection = seededSelection
        } else {
            selectedAlbumIDs.removeAll()
            selection = FilterSelection()
        }

        albums.removeAll()
        people.removeAll()
        albumCoverURLByID.removeAll()
        peopleCoverURLByID.removeAll()
        personAssetsCountByID.removeAll()
        loadingPersonStatsIDs.removeAll()
        albumLoadErrorMessage = nil
        peopleLoadErrorMessage = nil
    }
}

// The Preview factory lives in this file because of private(set); it backs up and restores UserDefaults
// so the real filter selection is not polluted.
extension FilterViewModel {
    static func personFilterTVPreviewModel() -> FilterViewModel {
        let previewStore = FilterSelectionStore()
        let storedSelectionBeforePreview = previewStore.load()

        let previewSelection = FilterSelection(
            personFilters: [
                PersonFilter(personId: "preview-person-1", matchMode: .soloOnly),
                PersonFilter(personId: "preview-person-2", matchMode: .normal)
            ]
        )

        let viewModel = FilterViewModel()

        viewModel.people = [
            People(id: "preview-person-1", name: "Sample Person 1", isHidden: false, isFavorite: true),
            People(id: "preview-person-2", name: "Sample Person 2", isHidden: false, isFavorite: false),
            People(
                id: "preview-person-3", name: "Sample Person With a Longer Name", isHidden: false, isFavorite: false),
            People(id: "preview-person-4", name: "Sample Person 4", isHidden: false, isFavorite: false)
        ]

        viewModel.peopleCoverURLByID = [
            "preview-person-1": URL(string: "https://example.invalid/preview/j6dG19_DY-.jpg"),
            "preview-person-2": URL(string: "https://example.invalid/preview/Zf0Chqcxd0.jpg"),
            "preview-person-3": URL(string: "https://example.invalid/preview/yOo0W4yrKB.jpg"),
            "preview-person-4": URL(string: "https://example.invalid/preview/7wrghkr_N3.jpg")
        ]
        .compactMapValues { $0 }

        viewModel.personAssetsCountByID = [
            "preview-person-1": 128,
            "preview-person-2": 42,
            "preview-person-3": 305,
            "preview-person-4": 19
        ]

        viewModel.selection = previewSelection

        if let storedSelectionBeforePreview {
            previewStore.save(storedSelectionBeforePreview)
        } else {
            previewStore.clear()
        }

        return viewModel
    }
}
