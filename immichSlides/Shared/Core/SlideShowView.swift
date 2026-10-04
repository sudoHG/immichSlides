//
//  SlideShowView.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI

// The shared entry only forwards data and callbacks; iOS and tvOS each implement interaction, so focus changes
// on one platform cannot break the other.

struct SlideShowView: View {

    @ObservedObject var viewModel: SlideShowViewModel

    // Navigation to Settings is handled by the root route above.
    var onOpenSettings: (() -> Void)? = nil

    // Only marks whether we came from onboarding; the tvOS screen decides whether to actually show the hint.

    var shouldShowOnboardingPlaybackHint: Bool = false

    var body: some View {
        Group {
            #if os(tvOS)
            // tvOS opens Settings from its control bar; the shared view has no playback back handler.

            SlideShowViewTV(
                viewModel: viewModel,
                onOpenSettings: onOpenSettings,
                showsOnboardingPlaybackHint: shouldShowOnboardingPlaybackHint
            )
            #else

            SlideShowViewIOS(
                viewModel: viewModel,
                onOpenSettings: onOpenSettings,
                showsOnboardingPlaybackHint: shouldShowOnboardingPlaybackHint
            )
            #endif
        }
    }
}

#Preview {
    SlideShowView(viewModel: SlideShowViewModel())
}
