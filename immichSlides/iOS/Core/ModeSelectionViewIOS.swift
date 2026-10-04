//
//  ModeSelectionViewIOS.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI

// The iOS mode screen manages orientation and card layout itself; it does not share a view tree with tvOS focus.

private enum ModeCardLayout {
    static let phoneLandscapeMinimumHeightPoints: CGFloat = 200
    static let phoneLandscapeMaximumHeightPoints: CGFloat = 228
    static let phoneLandscapeHeightRatio: CGFloat = 0.46
    static let compactMinimumHeightPoints: CGFloat = 420
    static let compactMaximumHeightPoints: CGFloat = 560
    static let compactHeightRatio: CGFloat = 0.60
    static let regularMinimumHeightPoints: CGFloat = 340
    static let regularMaximumHeightPoints: CGFloat = 480
    static let regularHeightRatio: CGFloat = 0.46
}

struct ModeSelectionViewIOS: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Binding var selectedMode: SlideMode?
    let shouldShowOnboardingProgress: Bool
    let onSelectMode: (SlideMode) -> Void
    let onContinue: () -> Void

    private var layout: ViewLayoutTraits {
        ViewLayoutTraits(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            userInterfaceIdiom: UIDevice.current.userInterfaceIdiom
        )
    }

    private var isCompact: Bool { layout.isCompactWidth }
    private var isCompactHeight: Bool { layout.isCompactHeight }
    private var isPhoneLandscape: Bool { layout.isPhoneLandscape }
    private var onboardingMetrics: IOSOnboardingVisualMetrics {
        IOSOnboardingVisualMetrics(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            userInterfaceIdiom: UIDevice.current.userInterfaceIdiom
        )
    }

    var body: some View {
        OnboardingPageScaffoldViewIOS(metrics: onboardingMetrics) { size in
            VStack(spacing: contentSpacing) {
                headerView
                cardsContainer(height: cardsContainerHeight(for: size.height))
                continueButton
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func cardsContainer(height: CGFloat) -> some View {
        // The subtitle uses one shared localization key covering albums and faces; it no longer implies places.

        let filteredModeDescription = "Filter the photos to show by album and person."

        if isPhoneLandscape {
            HStack(spacing: 10) {
                modeButton(
                    mode: .random, icon: "photo.stack", title: "Shuffle All Photos",
                    description: "Play all photos in the library in random order and start right away.",
                    cardHeight: height)
                modeButton(
                    mode: .filtered, icon: "photo.badge.plus.fill", title: "Filter slideshow photos",
                    description: filteredModeDescription, cardHeight: height)
            }
            .frame(height: height, alignment: .top)
        } else if isCompact {
            VStack(spacing: isCompactHeight ? 10 : 14) {
                modeButton(
                    mode: .random, icon: "photo.stack", title: "Shuffle All Photos",
                    description: "Play all photos in the library in random order and start right away.",
                    cardHeight: compactCardHeight(from: height))
                modeButton(
                    mode: .filtered, icon: "photo.badge.plus.fill", title: "Filter slideshow photos",
                    description: filteredModeDescription, cardHeight: compactCardHeight(from: height))
            }
            .frame(height: height)
        } else {
            HStack(spacing: 30) {
                modeButton(
                    mode: .random, icon: "photo.stack", title: "Shuffle All Photos",
                    description: "Play all photos in the library in random order and start right away.",
                    cardHeight: height)
                modeButton(
                    mode: .filtered, icon: "photo.badge.plus.fill", title: "Filter slideshow photos",
                    description: filteredModeDescription, cardHeight: height)
            }
            .frame(height: height)
        }
    }

    private func modeButton(
        mode: SlideMode,
        icon: String,
        title: String,
        description: String,
        cardHeight: CGFloat
    ) -> some View {
        Button {
            onSelectMode(mode)
        } label: {
            ModeCardView(
                icon: icon,
                title: title,
                description: description,
                isCompact: isCompact,
                isCompactHeight: isCompactHeight,
                isSelected: selectedMode == mode
            )
            .frame(maxWidth: .infinity)
            .frame(height: cardHeight, alignment: .center)
            .animation(.spring(response: 0.3), value: selectedMode)
        }
        .appButtonRole(.ghost)
        .frame(maxWidth: .infinity)
        // Give the Button the same height as the card so the visible frame and the tap area are equally tall.

        .frame(height: cardHeight, alignment: .center)
        .accessibilityIdentifier(mode == .random ? "mode.random.button" : "mode.filtered.button")
    }

    private var continueButton: some View {
        Button {
            onContinue()
        } label: {
            Text("Continue")
                .font(.system(size: isCompactHeight ? 16 : (onboardingMetrics.isPad ? 19 : 17), weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: onboardingMetrics.primaryButtonMinHeight)
        }
        .appButtonRole(.primary)
        .frame(maxWidth: onboardingMetrics.primaryButtonMaxWidth)
        .disabled(selectedMode == nil)
        .accessibilityIdentifier("mode.continue.button")
    }

    // Title is leading-aligned so iPad and large screens also start reading from the same side.
    private var headerView: some View {
        OnboardingPageHeaderViewIOS(
            step: shouldShowOnboardingProgress ? .choosePlaybackMode : nil,
            title: "Choose Playback Mode",
            subtitle: "Choose whether to shuffle all photos or pick albums and people first.",
            titleAccessibilityIdentifier: "mode.page.title",
            metrics: onboardingMetrics
        )
    }

    private func cardsContainerHeight(for screenHeight: CGFloat) -> CGFloat {
        if isPhoneLandscape {
            return max(
                ModeCardLayout.phoneLandscapeMinimumHeightPoints,
                min(
                    screenHeight * ModeCardLayout.phoneLandscapeHeightRatio,
                    ModeCardLayout.phoneLandscapeMaximumHeightPoints))
        }
        if isCompact {
            return max(
                ModeCardLayout.compactMinimumHeightPoints,
                min(screenHeight * ModeCardLayout.compactHeightRatio, ModeCardLayout.compactMaximumHeightPoints))
        }
        return max(
            ModeCardLayout.regularMinimumHeightPoints,
            min(screenHeight * ModeCardLayout.regularHeightRatio, ModeCardLayout.regularMaximumHeightPoints))
    }

    private var contentSpacing: CGFloat {
        if isPhoneLandscape { return 6 }
        if isCompactHeight { return 12 }
        return onboardingMetrics.pageSectionSpacing
    }

    // Compact vertical layout splits the height evenly between the two cards so they are not squashed.
    private func compactCardHeight(from containerHeight: CGFloat) -> CGFloat {
        let spacing: CGFloat = isCompactHeight ? 10 : 14
        return max(150, (containerHeight - spacing) / 2)
    }

}
