//
//  AlbumFilterView.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI

struct AlbumFilterView: View {
    @ObservedObject var viewModel: FilterViewModel

    @State private var isLoading: Bool = true
    @State private var didFinishInitialLoad: Bool = false

    var body: some View {
        Group {
            #if os(tvOS)
            AlbumFilterViewTV(
                viewModel: viewModel,
                isLoading: $isLoading,
                didFinishInitialLoad: $didFinishInitialLoad
            )
            #else
            AlbumFilterViewIOS(
                viewModel: viewModel,
                isLoading: $isLoading,
                didFinishInitialLoad: $didFinishInitialLoad
            )
            #endif
        }
        .task {
            await loadAlbumsIfNeeded()
        }
    }

    @MainActor
    private func loadAlbumsIfNeeded() async {
        guard isLoading || didFinishInitialLoad == false else { return }

        isLoading = true
        await viewModel.getCoverURLs(filterType: .albums, coverLimit: nil, reset: false)
        didFinishInitialLoad = true
        isLoading = false
    }
}

#Preview {
    NavigationStack {
        AlbumFilterView(viewModel: FilterViewModel())
    }
}
