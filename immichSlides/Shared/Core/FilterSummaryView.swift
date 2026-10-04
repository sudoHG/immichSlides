//
//  FilterSummaryView.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/29.
//

import SwiftUI

struct FilterSummaryView: View {
    @ObservedObject var viewModel: FilterViewModel
    // In the onboarding flow this goes back to mode selection; the regular flow passes nothing and it is hidden.
    var onBackToModeSelection: (() -> Void)? = nil
    // On iOS and tvOS, first-time onboarding shows setup progress; it does not change filter logic.

    var onboardingOnly: Bool = false

    var onStartPlaybackRequested: ((FilterSelection) -> Void)? = nil

    // Once playback starts, going back to mode selection is not allowed.
    @State private var allowBackToModeSelection: Bool = true

    @State private var isAccessProtectionEnabled: Bool = AccessProtectionStore.shared.isEnabled

    // With PIN enabled, hide the back-to-mode-selection action so protection cannot be bypassed.
    private var canShowBackToModeSelection: Bool {
        onBackToModeSelection != nil && allowBackToModeSelection && !isAccessProtectionEnabled
    }

    var body: some View {
        Group {
            #if os(tvOS)
            FilterSummaryViewTV(
                viewModel: viewModel,
                canShowBackToModeSelection: canShowBackToModeSelection,
                onBackToModeSelection: onBackToModeSelection,
                showsOnboardingProgress: onboardingOnly,
                onStartPlayback: { startFilteredPlayback() }
            )
            #else
            FilterSummaryViewIOS(
                viewModel: viewModel,
                canShowBackToModeSelection: canShowBackToModeSelection,
                showsOnboardingProgress: onboardingOnly,
                onStartPlayback: { startFilteredPlayback() }
            )
            #endif
        }
        .onAppear {
            syncAccessProtectionState()
            allowBackToModeSelection = true
            if viewModel.albumCoverURLs.isEmpty || viewModel.peopleCoverURLs.isEmpty {
                viewModel.preloadCovers(coverLimit: 20, reset: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessProtectionStateDidChange)) { _ in
            syncAccessProtectionState()
        }
    }

    private func startFilteredPlayback() {
        allowBackToModeSelection = false
        onStartPlaybackRequested?(viewModel.selection)
    }

    private func syncAccessProtectionState() {
        isAccessProtectionEnabled = AccessProtectionStore.shared.isEnabled
    }
}

#Preview {
    #if os(tvOS)
    FilterSummaryTVPreviewHost(previewInitialFocus: .album)
    #else
    FilterSummaryView(
        viewModel: FilterViewModel(),
        onBackToModeSelection: {}
    )
    #endif
}
#Preview {
    #if os(tvOS)
    FilterSummaryTVPreviewHost(previewInitialFocus: .people)
    #else
    FilterSummaryView(
        viewModel: FilterViewModel(),
        onBackToModeSelection: {}
    )
    #endif
}
