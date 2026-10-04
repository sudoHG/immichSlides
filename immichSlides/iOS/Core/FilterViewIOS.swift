import SwiftUI

struct FilterViewIOS: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject var viewModel: FilterViewModel

    var showsStartPlaybackButton: Bool = true
    var onStartPlaybackRequested: ((FilterSelection) -> Void)? = nil
    var onDismissRequested: (() -> Void)? = nil

    private var layout: ViewLayoutTraits {
        ViewLayoutTraits(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            userInterfaceIdiom: UIDevice.current.userInterfaceIdiom
        )
    }

    private var onboardingMetrics: IOSOnboardingVisualMetrics {
        IOSOnboardingVisualMetrics(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            userInterfaceIdiom: UIDevice.current.userInterfaceIdiom
        )
    }

    private var isPhone: Bool { layout.isPhone }
    private var isCompact: Bool { layout.isCompactWidth }
    private var isCompactHeight: Bool { layout.isCompactHeight }
    private var isPad: Bool { layout.userInterfaceIdiom == .pad }
    private var isPhonePortrait: Bool { layout.isPhonePortrait }
    private var isPhoneLandscape: Bool { layout.isPhoneLandscape }

    private var canStartPlayback: Bool {
        viewModel.selection.isEmpty == false
    }

    private var shouldExposeUITestReadinessMarkers: Bool {
        ProcessInfo.processInfo.environment["UI_TEST_PREPARE_FILTER_EDITOR_VISUAL_SELECTIONS"] == "1"
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

    private var filterEditorVisualAuditReady: Bool {
        albumVisualAuditReady && peopleVisualAuditReady
    }

    var body: some View {
        IOSOnboardingPageScaffold(metrics: onboardingMetrics) { _ in
            VStack(alignment: .leading, spacing: sectionSpacing) {
                pageHeader
                selectionStage
                bottomSection
            }
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

    private var pageHeader: some View {
        IOSOnboardingPageHeader(
            step: nil,
            title: "Edit Filters",

            subtitle: "Choose albums or people to adjust the default filter range",
            titleAccessibilityIdentifier: "filterEditor.page.title",
            metrics: onboardingMetrics
        )
    }

    private var selectionStage: some View {
        Group {
            if isPhoneLandscape {
                HStack(spacing: 16) {
                    albumSelectionCard
                        .frame(maxWidth: 340)
                    peopleSelectionCard
                        .frame(maxWidth: 340)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else if isCompact == false {
                HStack(alignment: .top, spacing: 16) {
                    albumSelectionCard
                    peopleSelectionCard
                }
            } else {
                VStack(spacing: 16) {
                    albumSelectionCard
                    peopleSelectionCard
                }
            }
        }
    }

    private var albumSelectionCard: some View {
        FilterSummarySelectionCard(
            viewModel: viewModel,
            kind: .album,
            isPhone: isPhone,
            isPhoneLandscape: isPhoneLandscape,
            isPhonePortrait: isPhonePortrait,
            isCompact: isCompact,
            isCompactHeight: isCompactHeight,
            isPad: isPad,
            accessibilityIdentifierOverride: "filter.editor.album.entry"
        )
    }

    private var peopleSelectionCard: some View {
        FilterSummarySelectionCard(
            viewModel: viewModel,
            kind: .people,
            isPhone: isPhone,
            isPhoneLandscape: isPhoneLandscape,
            isPhonePortrait: isPhonePortrait,
            isCompact: isCompact,
            isCompactHeight: isCompactHeight,
            isPad: isPad,
            accessibilityIdentifierOverride: "filter.editor.person.entry"
        )
    }

    @ViewBuilder
    private var bottomSection: some View {
        if showsStartPlaybackButton {

            FilterSummaryActionBar(
                viewModel: viewModel,
                canShowBackToModeSelection: false,
                canStartPlayback: canStartPlayback,
                onBackToModeSelection: nil,
                onStartPlayback: { startFilteredPlayback() },
                isPhone: isPhone,
                isCompact: isCompact,
                isPhoneLandscape: isPhoneLandscape,
                isPhonePortrait: isPhonePortrait
            )
        } else {

            FilterEditorSummaryPanelIOS(
                selectedAlbumCount: viewModel.selectedAlbumCount,
                selectedPersonCount: viewModel.selectedPersonCount,
                totalSelectedAssetCount: viewModel.selectedAlbumAssetsCount + viewModel.selectedPersonAssetsCount,
                isPhone: isPhone,
                isCompact: isCompact,
                isPhoneLandscape: isPhoneLandscape,
                dismissHint: onDismissRequested == nil
                    ? "Changes are saved automatically."
                    : "Changes are saved automatically. Tap Done to return to Settings."
            )
        }
    }

    private var uiTestReadinessMarkers: some View {
        VStack(alignment: .leading, spacing: 1) {
            // localization-audit: ui-test-probe
            Text(verbatim: albumVisualAuditReady ? "ready" : "loading")
                .accessibilityIdentifier("filterEditor.album.ready")
            // localization-audit: ui-test-probe
            Text(verbatim: peopleVisualAuditReady ? "ready" : "loading")
                .accessibilityIdentifier("filterEditor.people.ready")
            // localization-audit: ui-test-probe
            Text(verbatim: filterEditorVisualAuditReady ? "ready" : "loading")
                .accessibilityIdentifier("filterEditor.visual.ready")
        }
        .font(.system(size: 1))
        .foregroundStyle(Color.clear)
        .frame(width: 2, height: 3, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    private func prepareVisualAuditSelectionsForUITestsIfNeeded() async {
        // UI tests only: fill in album and person selections for screenshots without changing the real filter rules.

        await viewModel.getCoverURLs(filterType: .albums, coverLimit: 20, reset: true)
        await viewModel.getCoverURLs(filterType: .people, coverLimit: 20, reset: true)

        for _ in 0..<40 {
            if filterEditorVisualAuditReady {
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

    private func startFilteredPlayback() {
        onStartPlaybackRequested?(viewModel.selection)
    }

    private var sectionSpacing: CGFloat {
        if isCompactHeight { return 14 }
        return onboardingMetrics.pageSectionSpacing
    }
}

private struct FilterEditorSummaryPanelIOS: View {
    let selectedAlbumCount: Int
    let selectedPersonCount: Int
    let totalSelectedAssetCount: Int
    let isPhone: Bool
    let isCompact: Bool
    let isPhoneLandscape: Bool
    let dismissHint: String

    @Environment(\.colorScheme) private var colorScheme

    private var albumTint: Color {
        Color(red: 0.31, green: 0.88, blue: 0.93)
    }

    private var peopleTint: Color {
        Color(red: 1.00, green: 0.73, blue: 0.36)
    }

    private var summaryTint: Color {
        Color(red: 0.29, green: 0.75, blue: 0.96)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : Color.black.opacity(0.92)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.66) : Color(red: 0.34, green: 0.41, blue: 0.49)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isPhone ? 14 : 16) {

            Text("Filter Summary")
                .accessibilityIdentifier("filter.editor.summary.title")
                .font(.system(size: isCompact ? 15 : 16, weight: .heavy))
                .foregroundStyle(primaryTextColor)

            metricsGrid

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(summaryTint)

                Text(LocalizedStringKey(dismissHint))
                    .font(.system(size: isPhone ? 12 : 13, weight: .medium))
                    .foregroundStyle(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, isPhone ? 16 : 22)
        .padding(.vertical, isPhone ? 16 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appIOSOnboardingSurface(cornerRadius: isPhone ? 24 : 28, accent: summaryTint)
    }

    @ViewBuilder
    private var metricsGrid: some View {
        if isPhone {
            ViewThatFits(in: .horizontal) {
                metricRow(spacing: 8)

                compactMetricsFallback
            }
        } else {
            metricRow(spacing: 12)
        }
    }

    @ViewBuilder
    private var compactMetricsFallback: some View {

        if isPhoneLandscape {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    metricTile(value: "\(selectedAlbumCount)", label: "Selected albums", accent: albumTint)
                    metricTile(value: "\(selectedPersonCount)", label: "Selected people", accent: peopleTint)
                }

                metricTile(value: "\(totalSelectedAssetCount)", label: "Photos", accent: summaryTint)
            }
        } else {
            VStack(spacing: 8) {
                metricTile(value: "\(selectedAlbumCount)", label: "Selected albums", accent: albumTint)
                metricTile(value: "\(selectedPersonCount)", label: "Selected people", accent: peopleTint)
                metricTile(value: "\(totalSelectedAssetCount)", label: "Photos", accent: summaryTint)
            }
        }
    }

    private func metricRow(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            metricTile(value: "\(selectedAlbumCount)", label: "Selected albums", accent: albumTint)
            metricTile(value: "\(selectedPersonCount)", label: "Selected people", accent: peopleTint)
            metricTile(value: "\(totalSelectedAssetCount)", label: "Photos", accent: summaryTint)
        }
    }

    private func metricTile(value: String, label: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: isCompact ? 17 : 19, weight: .heavy))
                .foregroundStyle(primaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.88)

            Text(LocalizedStringKey(label))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isCompact ? 10 : 11)
        .padding(.vertical, isCompact ? 9 : 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accent.opacity(colorScheme == .dark ? 0.14 : 0.10))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent.opacity(colorScheme == .dark ? 0.18 : 0.14), lineWidth: 1)
        }
    }
}
