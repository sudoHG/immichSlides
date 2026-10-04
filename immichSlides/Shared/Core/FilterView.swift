import SwiftUI

struct FilterView: View {
    @ObservedObject var viewModel: FilterViewModel

    // true shows Start Playback for mode selection; false is edit-only for Settings.

    var showsStartPlaybackButton: Bool = true
    var onStartPlaybackRequested: ((FilterSelection) -> Void)? = nil
    // Used by Settings to close the full-screen filter editor.

    var onDismissRequested: (() -> Void)? = nil

    var body: some View {
        platformContent
            .navigationTitle("Edit Filters")
            .appNavigationBarTitleDisplayModeInline()
            .onAppear {
                // Preload only when covers are empty, to avoid repeating requests on every visit.

                if viewModel.albumCoverURLs.isEmpty || viewModel.peopleCoverURLs.isEmpty {
                    viewModel.preloadCovers(coverLimit: 20, shouldReset: true)
                }
            }
    }

    @ViewBuilder
    private var platformContent: some View {
        #if os(tvOS)
        FilterViewTV(
            viewModel: viewModel,
            showsStartPlaybackButton: showsStartPlaybackButton,
            onStartPlaybackRequested: onStartPlaybackRequested,
            onDismissRequested: onDismissRequested
        )
        #else
        FilterViewIOS(
            viewModel: viewModel,
            showsStartPlaybackButton: showsStartPlaybackButton,
            onStartPlaybackRequested: onStartPlaybackRequested,
            onDismissRequested: onDismissRequested
        )
        #endif
    }
}

#Preview {
    NavigationStack {
        FilterView(viewModel: FilterViewModel(), showsStartPlaybackButton: false)
    }
}
