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

    @ObservedObject var viewModel: FilterViewModel
    let canShowBackToModeSelection: Bool
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
                    canStartPlayback: canStartPlayback,
                    onStartPlayback: onStartPlayback,
                    isPhone: isPhone,
                    isCompact: isCompact,
                    isPhoneLandscape: isPhoneLandscape
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
                canStartPlayback: canStartPlayback,
                onStartPlayback: onStartPlayback,
                isPhone: isPhone,
                isCompact: isCompact,
                isPhoneLandscape: isPhoneLandscape
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
            if isCompact == false {
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
        await viewModel.getCoverURLs(filterType: .albums, coverLimit: 20, shouldReset: true)
        await viewModel.getCoverURLs(filterType: .people, coverLimit: 20, shouldReset: true)

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

    private var phoneLandscapeColumnSpacing: CGFloat {
        12
    }

    private var phoneLandscapeSectionSpacing: CGFloat {
        14
    }

    private var phoneLandscapeCardWidth: CGFloat { 320 }

}
