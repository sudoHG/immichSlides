import Foundation
import Combine

/// Data layer for the tvOS filter summary stage; doesn't handle focus or navigation.

private enum StageSamplingLimits {
    static let coverCount: Int = 40
    static let selectedAlbumCount: Int = 4
    static let libraryAssetCount: Int = 18
    static let albumSpotlightSourceCount: Int = 6
    static let albumPanoramaCount: Int = 30
    static let albumSpotlightFallbackCount: Int = 4
    static let albumSpotlightOutputCount: Int = 8
    static let selectedPersonCount: Int = 4
    static let fallbackPersonCount: Int = 6
    static let peopleAssetCount: Int = 14
    static let peopleWallCount: Int = 40
    static let peopleSpotlightOutputCount: Int = 12
}

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
        async let albumCovers: Void = viewModel.getCoverURLs(
            filterType: .albums, coverLimit: StageSamplingLimits.coverCount, shouldReset: false)
        async let peopleCovers: Void = viewModel.getCoverURLs(
            filterType: .people, coverLimit: StageSamplingLimits.coverCount, shouldReset: false)
        _ = await (albumCovers, peopleCovers)

        await refreshAlbumStageIfNeeded(viewModel: viewModel, shouldForceRefresh: albumPanoramaURLs.isEmpty)
        await refreshPeopleStageIfNeeded(viewModel: viewModel, shouldForceRefresh: peopleWallURLs.isEmpty)
    }

    func refreshAlbumStageIfNeeded(viewModel: FilterViewModel, shouldForceRefresh: Bool = false) async {
        let selectionKey = viewModel.selection.albumIds.sorted().joined(separator: ",")
        guard shouldForceRefresh || selectionKey != lastAlbumSelectionKey else { return }
        lastAlbumSelectionKey = selectionKey

        let selectedAlbumIDs = Array(viewModel.selection.albumIds.prefix(StageSamplingLimits.selectedAlbumCount))
        async let selectedAssetsTask: [Asset] = {
            guard selectedAlbumIDs.isEmpty == false else { return [] }
            return (try? await ImmichAPIService.shared.getRandomAsset(size: 10, albumIds: selectedAlbumIDs)) ?? []
        }()

        let libraryAssets: [Asset]
        #if DEBUG
        if let fixedReplayAssets = await fixedReplayAssetsForTesting(limit: StageSamplingLimits.libraryAssetCount),
            fixedReplayAssets.isEmpty == false
        {
            libraryAssets = fixedReplayAssets
        } else {
            libraryAssets =
                (try? await ImmichAPIService.shared.getRandomAsset(size: StageSamplingLimits.libraryAssetCount)) ?? []
        }
        #else
        libraryAssets =
            (try? await ImmichAPIService.shared.getRandomAsset(size: StageSamplingLimits.libraryAssetCount)) ?? []
        #endif

        let selectedAssets = await selectedAssetsTask
        let panoramaURLs = await thumbnailURLs(for: libraryAssets + selectedAssets, size: .preview)
        let spotlightURLs = await thumbnailURLs(
            for: Array(selectedAssets.prefix(StageSamplingLimits.albumSpotlightSourceCount)), size: .fullsize)
        let fallbackPanorama = panoramaURLs + viewModel.albumCoverURLs

        albumPanoramaURLs = deduplicated(fallbackPanorama, limit: StageSamplingLimits.albumPanoramaCount)
        albumSpotlightURLs = deduplicated(
            spotlightURLs + Array(albumPanoramaURLs.prefix(StageSamplingLimits.albumSpotlightFallbackCount)),
            limit: StageSamplingLimits.albumSpotlightOutputCount)
        isAlbumStageReady = albumPanoramaURLs.isEmpty == false
    }

    func refreshPeopleStageIfNeeded(viewModel: FilterViewModel, shouldForceRefresh: Bool = false) async {
        let selectionKey = viewModel.selection.personFilters
            .map(\.personId)
            .sorted()
            .joined(separator: ",")
        guard shouldForceRefresh || selectionKey != lastPeopleSelectionKey else { return }
        lastPeopleSelectionKey = selectionKey

        let selectedPersonIDs: [String] = {
            let explicitSelection = Array(
                viewModel.selection.personFilters.prefix(StageSamplingLimits.selectedPersonCount).map(\.personId))
            if explicitSelection.isEmpty == false {
                return explicitSelection
            }
            return Array(viewModel.people.prefix(StageSamplingLimits.fallbackPersonCount).map(\.id))
        }()

        let peopleAssets: [Asset]
        if selectedPersonIDs.isEmpty {
            peopleAssets = []
        } else {
            peopleAssets =
                (try? await ImmichAPIService.shared.getRandomAsset(
                    size: StageSamplingLimits.peopleAssetCount, personIds: selectedPersonIDs)) ?? []
        }

        let spotlightURLs = await thumbnailURLs(for: peopleAssets, size: .preview)
        let baseWallURLs = deduplicated(viewModel.peopleCoverURLs, limit: StageSamplingLimits.peopleWallCount)

        peopleWallURLs = baseWallURLs
        peopleSpotlightURLs = deduplicated(spotlightURLs, limit: StageSamplingLimits.peopleSpotlightOutputCount)
        isPeopleStageReady = peopleWallURLs.isEmpty == false
    }

    #if DEBUG
    /// Only under XCTest does a fixed replay lock the stage assets; normal builds still use the random data source.
    private func fixedReplayAssetsForTesting(limit: Int) async -> [Asset]? {
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
