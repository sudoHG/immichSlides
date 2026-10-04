import SwiftUI
import SDWebImage

// The preview host renders the tvOS page directly, so the shared
// entry point doesn't also have to manage the preview lifecycle.

struct FilterSummaryTVPreviewHost: View {
    @StateObject private var viewModel = FilterViewModel()
    @StateObject private var stageViewModel = FilterSummaryTVStageViewModel()
    @State private var hasStartedPreparingPreview: Bool = false
    let previewInitialFocus: FilterSummaryPreviewFocusTarget

    var body: some View {
        FilterSummaryViewTV(
            viewModel: viewModel,
            canShowBackToModeSelection: true,
            onBackToModeSelection: {},
            onStartPlayback: {},
            previewInitialFocus: previewInitialFocus,
            stageViewModel: stageViewModel
        )
        .task {
            guard hasStartedPreparingPreview == false else { return }
            hasStartedPreparingPreview = true
            await preparePreviewData()
        }
    }

    // The people preview doesn't trust the old local selection;
    // without covers it falls back to the server's first two people.

    private func preparePreviewData() async {
        async let albumCovers: Void = viewModel.getCoverURLs(filterType: .albums, coverLimit: 20, shouldReset: true)
        async let peopleCovers: Void = viewModel.getCoverURLs(filterType: .people, coverLimit: 20, shouldReset: true)
        _ = await (albumCovers, peopleCovers)

        if previewInitialFocus == .album {
            await ensureAlbumSelectionForPreview()
        } else {
            await ensurePeopleSelectionForPreview()
        }

        await stageViewModel.prepare(viewModel: viewModel)

        await prefetchPreviewImages(
            urls: Array(
                (viewModel.albumCoverURLs + viewModel.peopleCoverURLs + stageViewModel.albumPanoramaURLs
                    + stageViewModel.albumSpotlightURLs + stageViewModel.peopleWallURLs
                    + stageViewModel.peopleSpotlightURLs).prefix(60)
            )
        )

        // After prefetch completes, wait a fixed 500 ms so remote images can replace placeholders.

        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    private func ensureAlbumSelectionForPreview() async {
        guard viewModel.selectedAlbumCount == 0 else { return }
        guard let firstAlbum = viewModel.albums.first else { return }
        await MainActor.run {
            viewModel.toggleAlbum(id: firstAlbum.id)
        }
    }

    private func ensurePeopleSelectionForPreview() async {
        let selectedIDs = viewModel.selection.personFilters.map(\.personId)
        let hasSelectedCovers = selectedIDs.contains { viewModel.peopleCoverURLByID[$0] != nil }

        if hasSelectedCovers == false {
            let fallbackPeople = Array(viewModel.people.prefix(2))
            if fallbackPeople.isEmpty == false {
                await MainActor.run {
                    viewModel.selection.personFilters = fallbackPeople.map {
                        PersonFilter(personId: $0.id, matchMode: .normal)
                    }
                }
            }
        }

        for personID in viewModel.selection.personFilters.prefix(2).map(\.personId) {
            await viewModel.loadPersonAssetsCountIfNeeded(id: personID)
        }
    }

    // Prefetch covers before showing, so Preview is less likely to capture blank frames.

    private func prefetchPreviewImages(urls: [URL]) async {
        guard urls.isEmpty == false else { return }
        let context: [SDWebImageContextOption: Any] = {
            if let modifier = ImmichRequestModifier.create() {
                return [.downloadRequestModifier: modifier]
            }
            return [:]
        }()

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
}

#Preview {
    FilterSummaryTVPreviewHost(previewInitialFocus: .album)
}

#Preview {
    FilterSummaryTVPreviewHost(previewInitialFocus: .people)
}
