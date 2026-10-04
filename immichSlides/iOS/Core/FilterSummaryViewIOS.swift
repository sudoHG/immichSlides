//
//  FilterSummaryViewIOS.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI

struct FilterSummaryViewIOS: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var viewModel: FilterViewModel
    let canShowBackToModeSelection: Bool
    let onBackToModeSelection: (() -> Void)?
    let showsOnboardingProgress: Bool
    let onStartPlayback: () -> Void

    private var layout: ViewLayoutTraits {
        ViewLayoutTraits(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            userInterfaceIdiom: UIDevice.current.userInterfaceIdiom
        )
    }

    private var isCompact: Bool { layout.isCompactWidth }
    private var isCompactHeight: Bool { layout.isCompactHeight }
    private var isPad: Bool { layout.userInterfaceIdiom == .pad }
    private var isPhone: Bool { layout.isPhone }
    private var isPhonePortrait: Bool { layout.isPhonePortrait }
    private var isPhoneLandscape: Bool { layout.isPhoneLandscape }
    private var onboardingMetrics: IOSOnboardingVisualMetrics {
        IOSOnboardingVisualMetrics(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            userInterfaceIdiom: UIDevice.current.userInterfaceIdiom
        )
    }

    private var canStartPlayback: Bool {
        viewModel.selection.isEmpty == false
    }

    // No bottom Back to Mode Selection button, to avoid duplicating the root navigation back;
    // the flag still drives the root back button and height compensation.

    private var shouldShowBottomBackToModeSelectionButton: Bool {
        false
    }

    private var shouldExposeUITestReadinessMarkers: Bool {
        ProcessInfo.processInfo.environment["UI_TEST_PREPARE_FILTER_SUMMARY_VISUAL_SELECTIONS"] == "1"
    }

    private var albumVisualAuditReady: Bool {
        let hasMatchedAlbumSelection = viewModel.selection.albumIds.contains { selectedID in
            viewModel.albums.contains { $0.id == selectedID }
        }
        return hasMatchedAlbumSelection && viewModel.albumCoverURLs.isEmpty == false
    }

    private var peopleVisualAuditReady: Bool {
        let selectedIDs = viewModel.selection.personFilters.map(\.personId)
        let hasMatchedPeopleSelection = selectedIDs.contains { selectedID in
            viewModel.people.contains { $0.id == selectedID }
        }
        let hasLoadedStatsForSelection =
            selectedIDs.isEmpty == false
            && selectedIDs.allSatisfy { selectedID in
                viewModel.personAssetsCountByID[selectedID] != nil
            }
        return hasMatchedPeopleSelection && viewModel.peopleCoverURLs.isEmpty == false && hasLoadedStatsForSelection
    }

    private var filterSummaryVisualAuditReady: Bool {
        albumVisualAuditReady && peopleVisualAuditReady
    }

    var body: some View {
        IOSOnboardingPageScaffold(
            metrics: onboardingMetrics,
            topPaddingAdjustment: onboardingNavigationTopCompensation
        ) { _ in
            contentStack
        }
        .overlay(alignment: .topLeading) {
            if shouldExposeUITestReadinessMarkers {
                uiTestReadinessMarkers
            }
        }
        .task {
            guard shouldExposeUITestReadinessMarkers else { return }
            await prepareVisualAuditSelectionsForUITestsIfNeeded()
        }
    }

    // iPhone landscape puts a tappable Start button first and leaves the extra information to other sizes.

    @ViewBuilder
    private var contentStack: some View {
        if isPhoneLandscape {
            phoneLandscapeContent
        } else {
            VStack(alignment: .leading, spacing: sectionSpacing) {
                pageHeader
                selectionStage
                FilterSummaryActionBar(
                    viewModel: viewModel,
                    canShowBackToModeSelection: shouldShowBottomBackToModeSelectionButton,
                    canStartPlayback: canStartPlayback,
                    onBackToModeSelection: onBackToModeSelection,
                    onStartPlayback: onStartPlayback,
                    isPhone: isPhone,
                    isCompact: isCompact,
                    isPhoneLandscape: isPhoneLandscape,
                    isPhonePortrait: isPhonePortrait
                )
            }
        }
    }

    private var phoneLandscapeContent: some View {
        VStack(alignment: .leading, spacing: phoneLandscapeSectionSpacing) {
            pageHeader

            HStack(spacing: phoneLandscapeColumnSpacing) {
                FilterSummarySelectionCard(
                    viewModel: viewModel,
                    kind: .album,
                    isPhone: isPhone,
                    isPhoneLandscape: isPhoneLandscape,
                    isPhonePortrait: isPhonePortrait,
                    isCompact: isCompact,
                    isCompactHeight: isCompactHeight,
                    isPad: isPad
                )
                .frame(maxWidth: phoneLandscapeCardWidth)
                FilterSummarySelectionCard(
                    viewModel: viewModel,
                    kind: .people,
                    isPhone: isPhone,
                    isPhoneLandscape: isPhoneLandscape,
                    isPhonePortrait: isPhonePortrait,
                    isCompact: isCompact,
                    isCompactHeight: isCompactHeight,
                    isPad: isPad
                )
                .frame(maxWidth: phoneLandscapeCardWidth)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            FilterSummaryActionBar(
                viewModel: viewModel,
                canShowBackToModeSelection: shouldShowBottomBackToModeSelectionButton,
                canStartPlayback: canStartPlayback,
                onBackToModeSelection: onBackToModeSelection,
                onStartPlayback: onStartPlayback,
                isPhone: isPhone,
                isCompact: isCompact,
                isPhoneLandscape: isPhoneLandscape,
                isPhonePortrait: isPhonePortrait
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pageHeader: some View {
        IOSOnboardingPageHeader(
            step: showsOnboardingProgress ? .refineSelection : nil,
            title: "Set Photo Range",
            subtitle: "Choose albums or people, then start playback.",
            titleAccessibilityIdentifier: "filterSummary.page.title",
            metrics: onboardingMetrics
        )
    }

    private var selectionStage: some View {
        Group {
            if isPhoneLandscape {
                HStack(spacing: cardSpacing) {
                    FilterSummarySelectionCard(
                        viewModel: viewModel,
                        kind: .album,
                        isPhone: isPhone,
                        isPhoneLandscape: isPhoneLandscape,
                        isPhonePortrait: isPhonePortrait,
                        isCompact: isCompact,
                        isCompactHeight: isCompactHeight,
                        isPad: isPad
                    )
                    .frame(maxWidth: phoneLandscapeCardWidth)

                    FilterSummarySelectionCard(
                        viewModel: viewModel,
                        kind: .people,
                        isPhone: isPhone,
                        isPhoneLandscape: isPhoneLandscape,
                        isPhonePortrait: isPhonePortrait,
                        isCompact: isCompact,
                        isCompactHeight: isCompactHeight,
                        isPad: isPad
                    )
                    .frame(maxWidth: phoneLandscapeCardWidth)
                }
            } else if isCompact == false {
                HStack(alignment: .top, spacing: cardSpacing) {
                    FilterSummarySelectionCard(
                        viewModel: viewModel,
                        kind: .album,
                        isPhone: isPhone,
                        isPhoneLandscape: isPhoneLandscape,
                        isPhonePortrait: isPhonePortrait,
                        isCompact: isCompact,
                        isCompactHeight: isCompactHeight,
                        isPad: isPad
                    )

                    FilterSummarySelectionCard(
                        viewModel: viewModel,
                        kind: .people,
                        isPhone: isPhone,
                        isPhoneLandscape: isPhoneLandscape,
                        isPhonePortrait: isPhonePortrait,
                        isCompact: isCompact,
                        isCompactHeight: isCompactHeight,
                        isPad: isPad
                    )
                }
            } else {
                VStack(spacing: cardSpacing) {
                    FilterSummarySelectionCard(
                        viewModel: viewModel,
                        kind: .album,
                        isPhone: isPhone,
                        isPhoneLandscape: isPhoneLandscape,
                        isPhonePortrait: isPhonePortrait,
                        isCompact: isCompact,
                        isCompactHeight: isCompactHeight,
                        isPad: isPad
                    )

                    FilterSummarySelectionCard(
                        viewModel: viewModel,
                        kind: .people,
                        isPhone: isPhone,
                        isPhoneLandscape: isPhoneLandscape,
                        isPhonePortrait: isPhonePortrait,
                        isCompact: isCompact,
                        isCompactHeight: isCompactHeight,
                        isPad: isPad
                    )
                }
            }
        }
    }

    private var uiTestReadinessMarkers: some View {
        VStack(alignment: .leading, spacing: 1) {
            // localization-audit: ui-test-probe
            Text(verbatim: albumVisualAuditReady ? "ready" : "loading")
                .accessibilityIdentifier("filterSummary.album.ready")
            // localization-audit: ui-test-probe
            Text(verbatim: peopleVisualAuditReady ? "ready" : "loading")
                .accessibilityIdentifier("filterSummary.people.ready")
            // localization-audit: ui-test-probe
            Text(verbatim: filterSummaryVisualAuditReady ? "ready" : "loading")
                .accessibilityIdentifier("filterSummary.visual.ready")
        }
        .font(.system(size: 1))
        .foregroundStyle(Color.clear)
        .frame(width: 2, height: 3, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    private func prepareVisualAuditSelectionsForUITestsIfNeeded() async {
        await viewModel.getCoverURLs(filterType: .albums, coverLimit: 20, reset: true)
        await viewModel.getCoverURLs(filterType: .people, coverLimit: 20, reset: true)

        for _ in 0..<40 {
            if filterSummaryVisualAuditReady {
                return
            }

            if albumVisualAuditReady == false,
                let firstAlbum = viewModel.albums.first
            {
                await MainActor.run {
                    viewModel.removeAllAlbumSelection()
                    viewModel.toggleAlbum(id: firstAlbum.id)
                }
            }

            if peopleVisualAuditReady == false,
                let firstPerson = viewModel.people.first
            {
                await MainActor.run {
                    viewModel.removeAllPersonSelection()
                    viewModel.togglePerson(id: firstPerson.id)
                }
                await viewModel.loadPersonAssetsCountIfNeeded(id: firstPerson.id)
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private var sectionSpacing: CGFloat {
        if isCompactHeight { return 14 }
        return onboardingMetrics.pageSectionSpacing
    }

    private var cardSpacing: CGFloat {
        isCompactHeight ? 12 : 16
    }

    private var onboardingNavigationTopCompensation: CGFloat {

        guard showsOnboardingProgress, canShowBackToModeSelection else {
            return 0
        }

        return isCompactHeight ? 0 : -38
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : Color.black.opacity(0.92)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.66) : Color(red: 0.34, green: 0.41, blue: 0.49)
    }

    private var tertiaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.52) : Color(red: 0.40, green: 0.48, blue: 0.56)
    }

    private var secondaryButtonFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    private var albumTint: Color { Color(red: 0.31, green: 0.88, blue: 0.93) }
    private var albumTintSecondary: Color { Color(red: 0.23, green: 0.79, blue: 0.73) }
    private var peopleTint: Color { Color(red: 1.00, green: 0.73, blue: 0.36) }
    private var peopleTintSecondary: Color { Color(red: 0.96, green: 0.63, blue: 0.28) }
    private var summaryTint: Color { Color(red: 0.29, green: 0.75, blue: 0.96) }

    private var startButtonGradient: some ShapeStyle {
        AnyShapeStyle(
            LinearGradient(
                colors: [summaryTint, albumTintSecondary],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private var selectionCardMediaHeight: CGFloat {
        if isPhoneLandscape { return 110 }
        if isPhonePortrait { return 180 }
        if isCompactHeight { return 188 }
        if isCompact { return 220 }
        return isPad ? 268 : 238
    }

    private var selectionCardBodyPadding: CGFloat {
        if isPhoneLandscape { return 14 }
        return isCompact ? 18 : 20
    }

    private var selectionCardCornerRadius: CGFloat {
        isCompact ? 28 : 32
    }

    private var selectionCardTitleSize: CGFloat {
        if isPhoneLandscape { return 18 }
        return isCompact ? 22 : 24
    }

    private var selectionCardSurface: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.16, green: 0.17, blue: 0.20),
                        Color(red: 0.12, green: 0.14, blue: 0.17)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.98),
                    Color(red: 0.94, green: 0.97, blue: 0.995)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var selectionCardBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color(red: 0.72, green: 0.81, blue: 0.91).opacity(0.40)
    }

    private var actionButtonWidth: CGFloat {
        if isCompact {
            return 176
        }
        return 188
    }

    private var actionMetricTileWidth: CGFloat {
        if isCompact {
            return 94
        }
        return 104
    }

    private var phoneLandscapeColumnSpacing: CGFloat {
        12
    }

    private var phoneLandscapeSectionSpacing: CGFloat {
        14
    }

    private var actionPanelHorizontalPadding: CGFloat {
        if isPhoneLandscape { return 0 }
        if isPhone { return 16 }
        return isCompact ? 18 : 22
    }

    private var actionPanelVerticalPadding: CGFloat {
        if isPhoneLandscape { return 0 }
        if isPhone { return 16 }
        return isCompact ? 18 : 20
    }

    private var phoneSelectionPreviewWidth: CGFloat {
        isPhoneLandscape ? 56 : 74
    }

    private var phoneSelectionPreviewHeight: CGFloat {
        isPhoneLandscape ? 56 : 74
    }

    private var phoneSelectionCardPadding: CGFloat {
        isPhoneLandscape ? 16 : 12
    }

    private func phoneSelectionCardBackground(tint: Color, secondaryTint: Color) -> some ShapeStyle {
        if isPhone {
            return AnyShapeStyle(
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [
                            Color(red: 0.18, green: 0.20, blue: 0.23),
                            Color(red: 0.14, green: 0.16, blue: 0.19)
                        ]
                        : [
                            Color.white.opacity(0.98),
                            tint.opacity(0.05)
                        ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.18, blue: 0.22),
                    tint.opacity(colorScheme == .dark ? 0.10 : 0.06),
                    secondaryTint.opacity(colorScheme == .dark ? 0.05 : 0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func phoneSelectionCardBorder(tint: Color) -> Color {
        if isPhone {
            return colorScheme == .dark
                ? Color.white.opacity(0.08)
                : Color(red: 0.72, green: 0.81, blue: 0.91).opacity(0.38)
        }
        return tint.opacity(colorScheme == .dark ? 0.20 : 0.18)
    }

    private var phoneSelectionCardHighlight: Color {
        colorScheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.88)
    }

    private var phoneSecondaryButtonFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.90)
    }

    private var phoneDisabledButtonFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color(red: 0.79, green: 0.87, blue: 0.93)
    }

    private var phoneLandscapeCardWidth: CGFloat { 320 }

    private var phoneSingleButtonWidth: CGFloat {
        isPhoneLandscape ? 188 : 140
    }

}
