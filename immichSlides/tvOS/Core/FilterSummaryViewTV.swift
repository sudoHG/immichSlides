//
//  FilterSummaryViewTV.swift
//  immichSlides
//
//  Created by Codex during the tvOS panorama redesign.
//

import SwiftUI

// FocusedValue reports the system's actual focus, since it isn't always in sync with @FocusState.

private struct FilterSummaryFocusedTargetKey: FocusedValueKey {
    typealias Value = String
}

private extension FocusedValues {
    var filterSummaryFocusedTarget: String? {
        get { self[FilterSummaryFocusedTargetKey.self] }
        set { self[FilterSummaryFocusedTargetKey.self] = newValue }
    }
}

// Preview locks where focus lands, to make the matching stage branch easy to inspect.
enum FilterSummaryPreviewFocusTarget {
    case album
    case people
}

struct FilterSummaryViewTV: View {
    @Environment(\.colorScheme) private var colorScheme

    private enum FocusTarget: String, Hashable {
        case albumCard
        case peopleCard
        case startButton
        case backButton
    }

    private enum StageMode {
        case album
        case people
    }

    @ObservedObject var viewModel: FilterViewModel
    let canShowBackToModeSelection: Bool
    let onBackToModeSelection: (() -> Void)?
    var showsOnboardingProgress: Bool = false
    let onStartPlayback: () -> Void
    var previewInitialFocus: FilterSummaryPreviewFocusTarget? = nil
    var stageViewModel: FilterSummaryTVStageViewModel? = nil
    private let currentOnboardingStep: TVOnboardingWizardStep = .refineSelection
    @StateObject private var runtimeStageViewModel = FilterSummaryTVStageViewModel()
    @State private var showAlbumFilter: Bool = false
    @State private var showPeopleFilter: Bool = false
    @State private var activeStageMode: StageMode = .album
    @State private var lastStableFocusTarget: FocusTarget?
    @State private var requestedFocusTarget: FocusTarget?
    @FocusedValue(\.filterSummaryFocusedTarget) private var systemFocusedTargetRawValue: String?
    @FocusState private var focusedTarget: FocusTarget?
    @Namespace private var focusNamespace

    private var shouldExposeUITestReadinessMarkers: Bool {
        ProcessInfo.processInfo.environment["UI_TEST_PREPARE_FILTER_SUMMARY_VISUAL_SELECTIONS"] == "1"
    }

    private var resolvedStageViewModel: FilterSummaryTVStageViewModel {
        stageViewModel ?? runtimeStageViewModel
    }

    private var canStartPlayback: Bool {
        viewModel.selection.isEmpty == false
    }

    private var preferredActionFocusTarget: FocusTarget? {
        if canStartPlayback {
            return .startButton
        }
        if canShowBackToModeSelection {
            return .backButton
        }
        return nil
    }

    /// Preview locks the stage branch so asynchronously loaded images don't change the focus state.
    private var lockedPreviewStageMode: StageMode? {
        switch previewInitialFocus {
        case .album:
            return .album
        case .people:
            return .people
        case nil:
            return nil
        }
    }

    private var currentStageMode: StageMode {
        lockedPreviewStageMode ?? activeStageMode
    }

    private var selectionReloadToken: String {
        let albumPart = viewModel.selection.albumIds.sorted().joined(separator: ",")
        let peoplePart = viewModel.selection.personFilters.map(\.personId).sorted().joined(separator: ",")
        return "\(albumPart)|\(peoplePart)"
    }

    private var albumVisualAuditReady: Bool {
        let hasMatchedAlbumSelection = viewModel.selection.albumIds.contains { selectedID in
            viewModel.albums.contains { $0.id == selectedID }
        }
        return hasMatchedAlbumSelection && viewModel.albumCoverURLs.isEmpty == false
            && resolvedStageViewModel.isAlbumStageReady
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
            && resolvedStageViewModel.isPeopleStageReady
    }

    private var stageTitle: String {
        String(localized: "Set Photo Range")
    }

    private var stageDescription: String {
        // The title uses fixed text and doesn't switch between albums/people with focus.

        return String(localized: "Choose albums or people, then start playback.")
    }

    private var stageAccent: Color {
        currentStageMode == .album
            ? Color(red: 0.39, green: 0.84, blue: 0.93)
            : Color(red: 0.98, green: 0.73, blue: 0.31)
    }

    private var stageSecondaryAccent: Color {
        currentStageMode == .album
            ? Color(red: 0.25, green: 0.62, blue: 0.97)
            : Color(red: 0.94, green: 0.52, blue: 0.27)
    }

    private var secondaryActionAccent: Color {

        if colorScheme == .light {
            return Color(red: 0.21, green: 0.45, blue: 0.84)
        }
        return Color(red: 0.40, green: 0.65, blue: 0.98)
    }

    private var secondaryActionFill: Color {

        if colorScheme == .light {
            return Color(red: 0.94, green: 0.96, blue: 0.99).opacity(0.98)
        }
        return Color(red: 0.22, green: 0.24, blue: 0.28).opacity(0.94)
    }

    private var pageAtmosphereColors: [Color] {
        if colorScheme == .light {
            return [
                Color(red: 0.97, green: 0.98, blue: 1.00),
                Color(red: 0.91, green: 0.95, blue: 0.99),
                Color(red: 0.95, green: 0.94, blue: 0.99)
            ]
        }
        return [
            Color(red: 0.02, green: 0.03, blue: 0.06),
            Color(red: 0.04, green: 0.05, blue: 0.10),
            Color(red: 0.01, green: 0.01, blue: 0.03)
        ]
    }

    private var stageGlowPrimaryOpacity: Double {
        colorScheme == .light ? 0.14 : 0.22
    }

    private var stageGlowSecondaryOpacity: Double {
        colorScheme == .light ? 0.10 : 0.16
    }

    private var stageBorderColor: Color {
        colorScheme == .light ? Color.black.opacity(0.08) : Color.white.opacity(0.08)
    }

    private var stageShadowColor: Color {
        colorScheme == .light ? Color.black.opacity(0.12) : Color.black.opacity(0.34)
    }

    private var stageBottomScrimColors: [Color] {
        if colorScheme == .light {
            return [
                Color.white.opacity(0.02),
                Color.white.opacity(0.12),
                Color.white.opacity(0.32),
                Color.white.opacity(0.84)
            ]
        }
        return [
            Color.black.opacity(0.02),
            Color.black.opacity(0.16),
            Color.black.opacity(0.42),
            Color.black.opacity(0.76)
        ]
    }

    private var stageTitleColor: Color {
        colorScheme == .light ? Color.black.opacity(0.88) : .white
    }

    private var stageDescriptionColor: Color {
        colorScheme == .light ? Color.black.opacity(0.68) : Color.white.opacity(0.8)
    }

    private var stageAmbientColor: Color {
        colorScheme == .light ? Color.black.opacity(0.52) : Color.white.opacity(0.58)
    }

    private var actionBarLabelColor: Color {
        colorScheme == .light ? Color.black.opacity(0.52) : Color.white.opacity(0.65)
    }

    private var actionBarPanelTint: Color {
        colorScheme == .light ? Color.white.opacity(0.42) : Color.white.opacity(0.08)
    }

    private var stageSelectionSummary: String {
        if currentStageMode == .album {
            return LocalizedText.format("Albums: %lld", Int64(viewModel.selectedAlbumCount))
        }
        return LocalizedText.format("People: %lld", Int64(viewModel.selectedPersonCount))
    }

    private var stageAmbientSummary: String {
        if currentStageMode == .album {
            return LocalizedText.format(
                "Albums: %lld · Photos: %lld",
                Int64(viewModel.selectedAlbumCount),
                Int64(viewModel.selectedAlbumAssetsCount)
            )
        }
        return LocalizedText.format(
            "People: %lld · Photos: %lld",
            Int64(viewModel.selectedPersonCount),
            Int64(viewModel.selectedPersonAssetsCount)
        )
    }

    private var requestedFocusedTarget: FocusTarget? {
        requestedFocusTarget
    }

    private var systemFocusedTarget: FocusTarget? {
        guard let systemFocusedTargetRawValue else { return nil }
        return FocusTarget(rawValue: systemFocusedTargetRawValue)
    }

    private var visualFocusedTarget: FocusTarget? {
        systemFocusedTarget ?? requestedFocusedTarget
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundAtmosphere

                stageCanvas(in: geometry.size)

                stageCopyOverlay(in: geometry.size)

                bottomChrome(in: geometry.size)
            }
            .overlay(alignment: .topLeading) {
                if shouldExposeUITestReadinessMarkers {
                    uiTestReadinessMarkers
                }
            }
            .padding(.horizontal, horizontalScreenPadding(for: geometry.size.width))
            .padding(.vertical, verticalScreenPadding(for: geometry.size.height))
            .ignoresSafeArea()
        }
        .tvOnboardingProgressOverlay(
            currentStep: currentOnboardingStep,
            accessibilityIdentifier: "filterSummary.onboarding.title",
            isVisible: showsOnboardingProgress
        )
        .toolbar(.hidden, for: .navigationBar)
        .focusScope(focusNamespace)
        .onAppear {
            initializeFocusIfNeeded()
        }
        .task {
            await resolvedStageViewModel.prepare(viewModel: viewModel)
            if shouldExposeUITestReadinessMarkers {
                await prepareVisualAuditSelectionsForUITestsIfNeeded()
            }
            initializeFocusIfNeeded()
        }
        .onChange(of: selectionReloadToken) { _, _ in
            Task {
                await resolvedStageViewModel.refreshAlbumStageIfNeeded(viewModel: viewModel)
                await resolvedStageViewModel.refreshPeopleStageIfNeeded(viewModel: viewModel)
            }
        }
        .onChange(of: systemFocusedTargetRawValue) { _, newRawValue in
            let newValue = newRawValue.flatMap(FocusTarget.init(rawValue:))
            if let newValue {
                lastStableFocusTarget = newValue
                requestedFocusTarget = nil
                if focusedTarget != newValue {
                    focusedTarget = newValue
                }
            } else {
                repairFocusIfNeeded()
            }

            guard lockedPreviewStageMode == nil else { return }
            switch newValue {
            case .albumCard:
                activeStageMode = .album
            case .peopleCard:
                activeStageMode = .people
            default:
                break
            }
        }
        .navigationDestination(isPresented: $showAlbumFilter) {
            AlbumFilterView(viewModel: viewModel)
        }
        .navigationDestination(isPresented: $showPeopleFilter) {
            PersonFilterView(viewModel: viewModel)
        }
    }

    private func initializeFocusIfNeeded() {
        guard systemFocusedTarget == nil else { return }

        switch previewInitialFocus {
        case .album:
            activeStageMode = .album
            moveFocus(to: .albumCard)
        case .people:
            activeStageMode = .people
            moveFocus(to: .peopleCard)
        case nil:
            activeStageMode = .album
            moveFocus(to: .albumCard)
        }
    }

    private func repairFocusIfNeeded() {
        guard lockedPreviewStageMode == nil else { return }

        let fallbackTarget: FocusTarget?
        if let requestedFocusTarget, isFocusTargetAvailable(requestedFocusTarget) {

            fallbackTarget = requestedFocusTarget
        } else {
            switch lastStableFocusTarget {
            case .startButton:
                fallbackTarget =
                    canStartPlayback ? .startButton : (canShowBackToModeSelection ? .backButton : .peopleCard)
            case .backButton:
                fallbackTarget =
                    canShowBackToModeSelection ? .backButton : (canStartPlayback ? .startButton : .peopleCard)
            case .peopleCard:
                fallbackTarget = .peopleCard
            case .albumCard:
                fallbackTarget = .albumCard
            case nil:
                fallbackTarget = nil
            }
        }

        guard let fallbackTarget else { return }
        DispatchQueue.main.async {
            if systemFocusedTarget == nil {
                moveFocus(to: fallbackTarget)
            }
        }
    }

    private func moveFocus(to target: FocusTarget) {

        requestedFocusTarget = target
        focusedTarget = target
    }

    private func isFocusTargetAvailable(_ target: FocusTarget) -> Bool {
        switch target {
        case .albumCard, .peopleCard:
            return true
        case .startButton:
            return canStartPlayback
        case .backButton:
            return canShowBackToModeSelection
        }
    }

    // For visual audits, the page exposes a ready marker, so the test side doesn't have to wait blindly.

    private func prepareVisualAuditSelectionsForUITestsIfNeeded() async {
        for _ in 0..<40 {
            if albumVisualAuditReady && peopleVisualAuditReady {
                return
            }

            if albumVisualAuditReady == false,
                let firstAlbum = viewModel.albums.first
            {
                await MainActor.run {
                    viewModel.removeAllAlbumSelection()
                    viewModel.toggleAlbum(id: firstAlbum.id)
                }
                await resolvedStageViewModel.refreshAlbumStageIfNeeded(viewModel: viewModel, force: true)
            }

            if peopleVisualAuditReady == false,
                let firstPerson = viewModel.people.first
            {
                let selectedIDs = viewModel.selection.personFilters.map(\.personId)
                if selectedIDs.contains(firstPerson.id) == false {
                    await MainActor.run {
                        viewModel.selection.personFilters = [
                            PersonFilter(personId: firstPerson.id, matchMode: .normal)
                        ]
                    }
                }

                for personID in viewModel.selection.personFilters.prefix(1).map(\.personId) {
                    await viewModel.loadPersonAssetsCountIfNeeded(id: personID)
                }
                await resolvedStageViewModel.refreshPeopleStageIfNeeded(viewModel: viewModel, force: true)
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private var backgroundAtmosphere: some View {
        ZStack {
            LinearGradient(
                colors: pageAtmosphereColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(stageAccent.opacity(stageGlowPrimaryOpacity))
                .frame(width: 720, height: 720)
                .blur(radius: 120)
                .offset(x: -360, y: -280)

            Circle()
                .fill(stageSecondaryAccent.opacity(stageGlowSecondaryOpacity))
                .frame(width: 640, height: 640)
                .blur(radius: 140)
                .offset(x: 420, y: 260)
        }
        .ignoresSafeArea()
    }

    private func stageCanvas(in size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if currentStageMode == .album {
                    AlbumPanoramaStage(
                        panoramaURLs: resolvedStageViewModel.albumPanoramaURLs,
                        spotlightURLs: resolvedStageViewModel.albumSpotlightURLs,
                        accent: stageAccent,
                        selectedSummary: stageSelectionSummary
                    )
                } else {
                    PeopleConstellationStage(
                        wallURLs: resolvedStageViewModel.peopleWallURLs,
                        spotlightURLs: resolvedStageViewModel.peopleSpotlightURLs,
                        accent: stageAccent,
                        selectedSummary: stageSelectionSummary
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: stageCornerRadius, style: .continuous))

            stageBottomScrim
                .clipShape(RoundedRectangle(cornerRadius: stageCornerRadius, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: stageCornerRadius, style: .continuous)
                .stroke(stageBorderColor, lineWidth: 1)
        }
        .shadow(color: stageShadowColor, radius: 42, x: 0, y: 30)
    }

    private var stageBottomScrim: some View {
        LinearGradient(
            colors: stageBottomScrimColors,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func stageCopyOverlay(in size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            stageEyebrow
            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                Text(stageTitle)
                    .font(.system(size: titleSize(for: size.width), weight: .heavy, design: .rounded))
                    .foregroundStyle(stageTitleColor)
                    .frame(maxWidth: copyColumnWidth(for: size.width), alignment: .leading)
                    .accessibilityIdentifier("filterSummary.page.title")

                Text(stageDescription)

                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(stageDescriptionColor)
                    .frame(maxWidth: copyColumnWidth(for: size.width), alignment: .leading)

                Text(stageAmbientSummary)

                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(stageAmbientColor)
                    .frame(maxWidth: copyColumnWidth(for: size.width), alignment: .leading)
            }
        }
        .padding(.top, 34)
        .padding(.leading, 40)
        .padding(.bottom, dockHeight + 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var stageEyebrow: some View {

        Color.clear
            .frame(height: 34)
    }

    private func bottomChrome(in size: CGSize) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            selectionDock
                .frame(width: 900, alignment: .leading)
                .appTVFocusSection()

            Spacer(minLength: 24)

            actionBar
                .frame(width: actionBarWidth(for: size.width), alignment: .trailing)
                .appTVFocusSection()
        }
        .padding(.leading, 40)
        .padding(.trailing, 52)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var selectionDock: some View {
        HStack(spacing: 20) {
            albumCard
            peopleCard
        }
        .contentShape(Rectangle())
    }

    private var albumCard: some View {
        Button {
            showAlbumFilter = true
        } label: {
            FloatingSelectionCard(
                title: "Filter Albums",
                subtitle: "Choose albums to add to the slideshow pool.",
                summary: LocalizedText.format(
                    "%lld albums · %lld photos",
                    Int64(viewModel.selectedAlbumCount),
                    Int64(viewModel.selectedAlbumAssetsCount)
                ),
                accent: Color(red: 0.37, green: 0.84, blue: 0.93),
                previewURLs: resolvedStageViewModel.albumSpotlightURLs.isEmpty
                    ? viewModel.albumCoverURLs
                    : resolvedStageViewModel.albumSpotlightURLs,
                isFocused: visualFocusedTarget == .albumCard
            )
        }
        .buttonStyle(.plain)
        .focused($focusedTarget, equals: .albumCard)

        .focusedValue(\.filterSummaryFocusedTarget, FocusTarget.albumCard.rawValue)
        .appTVDisableDefaultFocusEffect()
        .hoverEffectDisabled(true)
        .accessibilityIdentifier("filterSummary.album.button")
        .appTVOnMoveCommand { direction in
            switch direction {
            case .right:
                moveFocus(to: .peopleCard)
            case .down:
                moveFocus(to: preferredActionFocusTarget ?? .albumCard)
            default:
                break
            }
        }
    }

    private var peopleCard: some View {
        Button {
            showPeopleFilter = true
        } label: {
            FloatingSelectionCard(
                title: "Filter People",
                subtitle: "Choose people to add to the slideshow pool.",
                summary: LocalizedText.format(
                    "%lld people · %lld photos",
                    Int64(viewModel.selectedPersonCount),
                    Int64(viewModel.selectedPersonAssetsCount)
                ),
                accent: Color(red: 0.98, green: 0.72, blue: 0.31),
                previewURLs: resolvedStageViewModel.peopleSpotlightURLs.isEmpty
                    ? viewModel.peopleCoverURLs
                    : resolvedStageViewModel.peopleSpotlightURLs,
                isFocused: visualFocusedTarget == .peopleCard
            )
        }
        .buttonStyle(.plain)
        .focused($focusedTarget, equals: .peopleCard)
        .focusedValue(\.filterSummaryFocusedTarget, FocusTarget.peopleCard.rawValue)
        .appTVDisableDefaultFocusEffect()
        .hoverEffectDisabled(true)
        .accessibilityIdentifier("filterSummary.person.button")
        .appTVOnMoveCommand { direction in
            switch direction {
            case .left:
                moveFocus(to: .albumCard)
            case .right:
                moveFocus(to: preferredActionFocusTarget ?? .peopleCard)
            case .down:
                moveFocus(to: preferredActionFocusTarget ?? .peopleCard)
            default:
                break
            }
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Playback")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .kerning(1.2)
                .foregroundStyle(actionBarLabelColor)

            VStack(alignment: .leading, spacing: 12) {
                startPlaybackButton

                if canShowBackToModeSelection {
                    backToModeSelectionButton
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
        .modifier(TVGlassPanelModifier(cornerRadius: 28, tint: actionBarPanelTint))
    }

    private var startPlaybackButton: some View {
        Button {
            onStartPlayback()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("Start Playback")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .modifier(
                TVActionButtonBackgroundModifier(isFocused: visualFocusedTarget == .startButton, accent: stageAccent))
        }
        .buttonStyle(.plain)
        .disabled(!canStartPlayback)
        .focused($focusedTarget, equals: .startButton)
        .focusedValue(\.filterSummaryFocusedTarget, FocusTarget.startButton.rawValue)
        .appTVDisableDefaultFocusEffect()
        .hoverEffectDisabled(true)
        .appTVDisabledEmphasis(canStartPlayback)
        .accessibilityIdentifier("filterSummary.startPlayback.button")
        .appTVOnMoveCommand { direction in
            switch direction {
            case .up:
                moveFocus(to: currentStageMode == .album ? .albumCard : .peopleCard)
            case .left:
                moveFocus(to: .peopleCard)
            case .down:
                if canShowBackToModeSelection {
                    moveFocus(to: .backButton)
                }
            default:
                break
            }
        }
    }

    private var backToModeSelectionButton: some View {
        Button {
            onBackToModeSelection?()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .bold))
                Text("Back to Mode Selection")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .modifier(
                TVActionButtonBackgroundModifier(
                    isFocused: visualFocusedTarget == .backButton,
                    accent: secondaryActionAccent,
                    fillColor: secondaryActionFill,
                    usesFillFocusEmphasis: false
                )
            )
        }
        .buttonStyle(.plain)
        .focused($focusedTarget, equals: .backButton)
        .focusedValue(\.filterSummaryFocusedTarget, FocusTarget.backButton.rawValue)
        .appTVDisableDefaultFocusEffect()
        .hoverEffectDisabled(true)
        .accessibilityIdentifier("filterSummary.backToMode.button")
        .appTVOnMoveCommand { direction in
            switch direction {
            case .up:
                moveFocus(to: canStartPlayback ? .startButton : .peopleCard)
            case .left:
                moveFocus(to: .peopleCard)
            default:
                break
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
        }
        .font(.system(size: 1))
        .foregroundStyle(Color.clear)
        .frame(width: 2, height: 2, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    private var stageCornerRadius: CGFloat { 0 }
    private var dockHeight: CGFloat { 286 }

    private func horizontalScreenPadding(for width: CGFloat) -> CGFloat {
        0
    }

    private func verticalScreenPadding(for height: CGFloat) -> CGFloat {
        0
    }

    private func titleSize(for width: CGFloat) -> CGFloat {
        width > 1700 ? 54 : 46
    }

    private func copyColumnWidth(for width: CGFloat) -> CGFloat {
        min(680, width * 0.4)
    }

    private func actionBarWidth(for width: CGFloat) -> CGFloat {
        min(392, width * 0.27)
    }
}
