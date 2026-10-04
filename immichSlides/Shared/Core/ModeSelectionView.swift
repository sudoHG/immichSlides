//
//  ModeSelectionView.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/11.
//

import SwiftUI

struct ModeSelectionView: View {
    @State var selectedMode: SlideMode?
    private let previewFocusedModeOverride: SlideMode?
    var onboardingOnly: Bool = false
    var onOnboardingDone: ((SlideMode) -> Void)? = nil

    @StateObject private var filterVM = FilterViewModel()
    @StateObject private var randomVM = SlideShowViewModel()

    init(
        selectedMode: SlideMode? = nil,
        onboardingOnly: Bool = false,
        onOnboardingDone: ((SlideMode) -> Void)? = nil,
        previewFocusedModeOverride: SlideMode? = nil
    ) {
        _selectedMode = State(initialValue: selectedMode)
        self.onboardingOnly = onboardingOnly
        self.onOnboardingDone = onOnboardingDone
        self.previewFocusedModeOverride = previewFocusedModeOverride
    }

    var body: some View {
        Group {
            #if os(tvOS)
            ModeSelectionViewTV(
                selectedMode: $selectedMode,
                previewFocusedModeOverride: previewFocusedModeOverride,
                showsOnboardingProgress: onboardingOnly,
                onSelectMode: selectMode,
                onContinue: onContinueTapped
            )
            #else
            ModeSelectionViewIOS(
                selectedMode: $selectedMode,
                showsOnboardingProgress: onboardingOnly,
                onSelectMode: selectMode,
                onContinue: onContinueTapped
            )
            #endif
        }
        // Preselect random when entering from onboarding, saving the user one step.
        .onAppear {
            if onboardingOnly, selectedMode == nil {
                selectedMode = .random
            }
        }
    }

    // Selecting warms up this screen's own VM; the next screen actually uses the root-level object.
    private func selectMode(_ mode: SlideMode) {
        switch mode {
        case .random:
            selectedMode = .random
            Task { await randomVM.firstPreload() }
        case .filtered:
            selectedMode = .filtered
            filterVM.preloadCovers(coverLimit: 20, shouldReset: true)
        }
    }

    // Persist the default mode before advancing so the next screen reads the saved choice.
    private func onContinueTapped() {
        guard let selectedMode else { return }
        let store = PlaybackSettingsStore()
        var settings = store.load() ?? PlaybackSettings()
        settings.defaultPlaybackMode = (selectedMode == .filtered) ? .filtered : .random
        store.save(settings)
        onOnboardingDone?(selectedMode)
    }
}

#Preview {
    ModeSelectionView()
}
