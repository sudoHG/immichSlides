//
//  PersonFilterView.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI

struct PersonFilterView: View {
    @ObservedObject var viewModel: FilterViewModel

    @State private var isLoading: Bool = true
    @State private var didFinishInitialLoad: Bool = false

    var body: some View {
        Group {
            #if os(tvOS)
            PersonFilterViewTV(
                viewModel: viewModel,
                isLoading: $isLoading,
                didFinishInitialLoad: $didFinishInitialLoad
            )
            #else
            PersonFilterViewIOS(
                viewModel: viewModel,
                isLoading: $isLoading,
                didFinishInitialLoad: $didFinishInitialLoad
            )
            #endif
        }
        .task {
            await loadPeopleIfNeeded()
        }
    }

    @MainActor
    private func loadPeopleIfNeeded() async {
        guard isLoading || didFinishInitialLoad == false else { return }

        isLoading = true
        await viewModel.getCoverURLs(filterType: .people, coverLimit: nil, shouldReset: false)
        didFinishInitialLoad = true
        isLoading = false
    }
}

#Preview {
    NavigationStack {
        PersonFilterView(viewModel: FilterViewModel())
    }
}
