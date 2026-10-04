import Foundation
import Combine

/// Data layer for the tvOS filter summary stage; doesn't handle focus or navigation.

@MainActor
final class FilterSummaryTVStageViewModel: ObservableObject {
    @Published private(set) var albumPanoramaURLs: [URL] = []
    @Published private(set) var albumSpotlightURLs: [URL] = []
    @Published private(set) var peopleWallURLs: [URL] = []
    @Published private(set) var peopleSpotlightURLs: [URL] = []
    @Published private(set) var isAlbumStageReady: Bool = false
    @Published private(set) var isPeopleStageReady: Bool = false

    private var lastAlbumSelectionKey: String = ""
    private var lastPeopleSelectionKey: String = ""

    func prepare(viewModel: FilterViewModel) async {
        async let albumCovers: Void = viewModel.getCoverURLs(filterType: .albums, coverLimit: 40, shouldReset: false)
        async let peopleCovers: Void = viewModel.getCoverURLs(filterType: .people, coverLimit: 40, shouldReset: false)
        _ = await (albumCovers, peopleCovers)

        await refreshAlbumStageIfNeeded(viewModel: viewModel, force: albumPanoramaURLs.isEmpty)
        await refreshPeopleStageIfNeeded(viewModel: viewModel, force: peopleWallURLs.isEmpty)
    }

    func refreshAlbumStageIfNeeded(viewModel: FilterViewModel, force: Bool = false) async {
        let selectionKey = viewModel.selection.albumIds.sorted().joined(separator: ",")
        guard force || selectionKey != lastAlbumSelectionKey else { return }
        lastAlbumSelectionKey = selectionKey

        let selectedAlbumIDs = Array(viewModel.selection.albumIds.prefix(4))
        async let selectedAssetsTask: [Asset] = {
            guard selectedAlbumIDs.isEmpty == false else { return [] }
            return (try? await ImmichAPIService.shared.getRandomAsset(size: 10, albumIds: selectedAlbumIDs)) ?? []
        }()

        let libraryAssets: [Asset]
        #if DEBUG
        if let fixedReplayAssets = await fixedReplayAssetsForUITest(limit: 18),
            fixedReplayAssets.isEmpty == false
        {
            libraryAssets = fixedReplayAssets
        } else {
            libraryAssets = (try? await ImmichAPIService.shared.getRandomAsset(size: 18)) ?? []
        }
        #else
        libraryAssets = (try? await ImmichAPIService.shared.getRandomAsset(size: 18)) ?? []
        #endif

        let selectedAssets = await selectedAssetsTask
        let panoramaURLs = await thumbnailURLs(for: libraryAssets + selectedAssets, size: .preview)
        let spotlightURLs = await thumbnailURLs(for: Array(selectedAssets.prefix(6)), size: .fullsize)
        let fallbackPanorama = panoramaURLs + viewModel.albumCoverURLs

        albumPanoramaURLs = deduplicated(fallbackPanorama, limit: 30)
        albumSpotlightURLs = deduplicated(spotlightURLs + Array(albumPanoramaURLs.prefix(4)), limit: 8)
        isAlbumStageReady = albumPanoramaURLs.isEmpty == false
    }

    func refreshPeopleStageIfNeeded(viewModel: FilterViewModel, force: Bool = false) async {
        let selectionKey = viewModel.selection.personFilters
            .map(\.personId)
            .sorted()
            .joined(separator: ",")
        guard force || selectionKey != lastPeopleSelectionKey else { return }
        lastPeopleSelectionKey = selectionKey

        let selectedPersonIDs: [String] = {
            let explicitSelection = Array(viewModel.selection.personFilters.prefix(4).map(\.personId))
            if explicitSelection.isEmpty == false {
                return explicitSelection
            }
            return Array(viewModel.people.prefix(6).map(\.id))
        }()

        let peopleAssets: [Asset]
        if selectedPersonIDs.isEmpty {
            peopleAssets = []
        } else {
            peopleAssets =
                (try? await ImmichAPIService.shared.getRandomAsset(size: 14, personIds: selectedPersonIDs)) ?? []
        }

        let spotlightURLs = await thumbnailURLs(for: peopleAssets, size: .preview)
        let baseWallURLs = deduplicated(viewModel.peopleCoverURLs, limit: 40)

        peopleWallURLs = baseWallURLs
        peopleSpotlightURLs = deduplicated(spotlightURLs, limit: 12)
        isPeopleStageReady = peopleWallURLs.isEmpty == false
    }

    #if DEBUG
    /// Only under XCTest does a fixed replay lock the stage assets; normal builds still use the random data source.
    private func fixedReplayAssetsForUITest(limit: Int) async -> [Asset]? {
        guard ImmichServer.isRunningXCTest,
            let replayConfiguration = try? PlaybackPoolResolver.assetIDReplayConfigurationForTesting()
        else {
            return nil
        }
        let requestedIDs = Array(replayConfiguration.orderedAssetIDs.prefix(limit))
        guard requestedIDs.isEmpty == false else { return nil }
        return try? await ImmichAPIService.shared.getAssets(ids: requestedIDs)
    }
    #endif

    private func thumbnailURLs(for assets: [Asset], size: ThumbnailSize) async -> [URL] {
        guard assets.isEmpty == false else { return [] }

        return await withTaskGroup(of: URL?.self, returning: [URL].self) { group in
            for asset in assets where asset.type == AssetTypes.IMAGE.rawValue {
                let assetID = asset.id
                group.addTask {
                    try? await ImmichAPIService.shared.getThumbnailURL(id: assetID, size: size)
                }
            }

            var urls: [URL] = []
            for await url in group {
                if let url {
                    urls.append(url)
                }
            }
            return urls
        }
    }

    private func deduplicated(_ urls: [URL], limit: Int) -> [URL] {
        var seen: Set<URL> = []
        var result: [URL] = []

        for url in urls where seen.contains(url) == false {
            seen.insert(url)
            result.append(url)
            if result.count >= limit {
                break
            }
        }
        return result
    }
}
