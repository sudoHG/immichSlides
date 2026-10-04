import SwiftUI

// FocusedValue reports the system's actual focus, since it isn't always in sync with @FocusState.

private enum VisualAuditPreparation {
    static let coverLimitCount: Int = 40
    static let maximumRetryCount: Int = 40
    static let pollIntervalNanoseconds: UInt64 = 250_000_000
}

private enum StageAtmosphereMetrics {
    static let primaryGlowSizePoints: CGFloat = 720
    static let primaryGlowBlurPoints: CGFloat = 120
    static let primaryGlowOffsetXPoints: CGFloat = -360
    static let primaryGlowOffsetYPoints: CGFloat = -280
    static let secondaryGlowSizePoints: CGFloat = 640
    static let secondaryGlowBlurPoints: CGFloat = 140
    static let secondaryGlowOffsetXPoints: CGFloat = 420
    static let secondaryGlowOffsetYPoints: CGFloat = 260
}

private struct FilterEditorFocusedTargetKey: FocusedValueKey {
    typealias Value = String
}

private extension FocusedValues {
    var filterEditorFocusedTarget: String? {
        get { self[FilterEditorFocusedTargetKey.self] }
        set { self[FilterEditorFocusedTargetKey.self] = newValue }
    }
}

// The Settings filter editor uses the same stage, entry cards, and action
// bar as the summary page, so users don't have to learn another layout.

struct FilterViewTV: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: FilterViewModel

    // true: start playback; false: finish and return to Settings.

    var shouldShowStartPlaybackButton: Bool = true
    var onStartPlaybackRequested: ((FilterSelection) -> Void)? = nil
    var onDismissRequested: (() -> Void)? = nil

    // Reuse the summary page's stage data layer, so the editor and first launch share asset preparation.

    @StateObject private var stageViewModel = FilterSummaryTVStageViewModel()

    @State private var isAlbumFilterPresented: Bool = false
    @State private var isPeopleFilterPresented: Bool = false
    @State private var activeStageMode: StageMode = .album
    @State private var lastStableFocusTarget: FocusTarget?
    @State private var requestedFocusTarget: FocusTarget?
    @FocusedValue(\.filterEditorFocusedTarget) private var systemFocusedTargetRawValue: String?
    @FocusState private var focusedTarget: FocusTarget?
    @Namespace private var focusNamespace

    private enum FocusTarget: String, Hashable {
        case albumCard
        case peopleCard
        case primaryAction
    }

    private enum StageMode {
        case album
        case people
    }

    private var shouldShowDismissButton: Bool {
        shouldShowStartPlaybackButton == false && onDismissRequested != nil
    }

    // With no filter, Start Playback is still shown but disabled, and can't be the default focus.

    private var shouldRenderPrimaryActionButton: Bool {
        shouldShowStartPlaybackButton || shouldShowDismissButton
    }

    private var canStartPlayback: Bool {
        viewModel.selection.isEmpty == false
    }

    private var preferredActionFocusTarget: FocusTarget? {
        if shouldShowDismissButton {
            return .primaryAction
        }
        if shouldShowStartPlaybackButton && canStartPlayback {
            return .primaryAction
        }
        return nil
    }

    private var shouldExposeUITestReadinessMarkers: Bool {
        ProcessInfo.processInfo.environment["UI_TEST_PREPARE_FILTER_EDITOR_VISUAL_SELECTIONS"] == "1"
    }

    private var selectionReloadToken: String {
        let albumPart = viewModel.selection.albumIds.sorted().joined(separator: ",")
        let peoplePart = viewModel.selection.personFilters.map(\.personId).sorted().joined(separator: ",")
        return "\(albumPart)|\(peoplePart)"
    }

    private var isAlbumVisualAuditReady: Bool {
        let hasMatchedAlbumSelection = viewModel.selection.albumIds.contains { selectedID in
            viewModel.albums.contains { $0.id == selectedID }
        }
        return hasMatchedAlbumSelection && viewModel.albumCoverURLs.isEmpty == false && stageViewModel.isAlbumStageReady
    }

    private var isPeopleVisualAuditReady: Bool {
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
            && stageViewModel.isPeopleStageReady
    }

    private var isFilterEditorVisualAuditReady: Bool {
        isAlbumVisualAuditReady && isPeopleVisualAuditReady
    }

    private var currentStageMode: StageMode {
        activeStageMode
    }

    private var stageTitle: String {
        if shouldShowDismissButton {
            return String(localized: "Edit Filters")
        }
        return String(localized: "Set Photo Range")
    }

    private var stageDescription: String {
        if shouldShowDismissButton {
            return String(
                localized:
                    "Use the album and people cards to adjust the default filtered playback range, then return to Playback Settings."
            )
        }
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

    private var doneAccent: Color {
        if colorScheme == .light {
            return Color(red: 0.21, green: 0.45, blue: 0.84)
        }
        return Color(red: 0.40, green: 0.65, blue: 0.98)
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
        colorScheme == .light ? Color.black.opacity(0.68) : Color.white.opacity(0.80)
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

    private var actionBarSectionTitle: LocalizedStringKey {
        shouldShowDismissButton ? "Editor" : "Playback"
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

                stageCanvas

                stageCopyOverlay(in: geometry.size)

                bottomChrome(in: geometry.size)
            }
            .overlay(alignment: .topLeading) {
                if shouldExposeUITestReadinessMarkers {
                    uiTestReadinessMarkers
                }
            }
            .ignoresSafeArea()
        }
        .toolbar(.hidden, for: .navigationBar)
        .focusScope(focusNamespace)
        .onAppear {
            initializeFocusIfNeeded()
        }
        .task {
            await stageViewModel.prepare(viewModel: viewModel)
            if shouldExposeUITestReadinessMarkers {
                await prepareVisualAuditSelectionsForUITestsIfNeeded()
            }
            initializeFocusIfNeeded()
        }
        .onChange(of: selectionReloadToken) { _, _ in
            Task {
                await stageViewModel.refreshAlbumStageIfNeeded(viewModel: viewModel)
                await stageViewModel.refreshPeopleStageIfNeeded(viewModel: viewModel)
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

            switch newValue {
            case .albumCard:
                activeStageMode = .album
            case .peopleCard:
                activeStageMode = .people
            default:
                break
            }
        }
        .navigationDestination(isPresented: $isAlbumFilterPresented) {
            AlbumFilterView(viewModel: viewModel)
        }
        .navigationDestination(isPresented: $isPeopleFilterPresented) {
            PersonFilterView(viewModel: viewModel)
        }
    }

    private func initializeFocusIfNeeded() {
        guard systemFocusedTarget == nil else { return }
        activeStageMode = .album
        moveFocus(to: .albumCard)
    }

    private func repairFocusIfNeeded() {

        guard isAlbumFilterPresented == false, isPeopleFilterPresented == false else { return }

        let fallbackTarget: FocusTarget?
        if let requestedFocusTarget, isFocusTargetAvailable(requestedFocusTarget) {
            fallbackTarget = requestedFocusTarget
        } else {
            switch lastStableFocusTarget {
            case .primaryAction:
                fallbackTarget = preferredActionFocusTarget ?? .peopleCard
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
        case .primaryAction:
            return preferredActionFocusTarget == .primaryAction
        }
    }

    private func prepareVisualAuditSelectionsForUITestsIfNeeded() async {
        await viewModel.getCoverURLs(
            filterType: .albums, coverLimit: VisualAuditPreparation.coverLimitCount, shouldReset: true)
        await viewModel.getCoverURLs(
            filterType: .people, coverLimit: VisualAuditPreparation.coverLimitCount, shouldReset: true)
        await stageViewModel.prepare(viewModel: viewModel)

        for _ in 0..<VisualAuditPreparation.maximumRetryCount {
            if isFilterEditorVisualAuditReady {
                return
            }

            if isAlbumVisualAuditReady == false,
                let firstAlbum = viewModel.albums.first
            {
                await MainActor.run {
                    viewModel.removeAllAlbumSelection()
                    viewModel.toggleAlbum(id: firstAlbum.id)
                }
                await stageViewModel.refreshAlbumStageIfNeeded(viewModel: viewModel, shouldForceRefresh: true)
            }

            if isPeopleVisualAuditReady == false,
                let firstPerson = viewModel.people.first
            {
                let selectedIDs = viewModel.selection.personFilters.map(\.personId)
                if selectedIDs.contains(firstPerson.id) == false {
                    await MainActor.run {
                        viewModel.removeAllPersonSelection()
                        viewModel.togglePerson(id: firstPerson.id)
                    }
                }

                for personID in viewModel.selection.personFilters.prefix(1).map(\.personId) {
                    await viewModel.loadPersonAssetsCountIfNeeded(id: personID)
                }
                await stageViewModel.refreshPeopleStageIfNeeded(viewModel: viewModel, shouldForceRefresh: true)
            }

            try? await Task.sleep(nanoseconds: VisualAuditPreparation.pollIntervalNanoseconds)
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
                .frame(
                    width: StageAtmosphereMetrics.primaryGlowSizePoints,
                    height: StageAtmosphereMetrics.primaryGlowSizePoints
                )
                .blur(radius: StageAtmosphereMetrics.primaryGlowBlurPoints)
                .offset(
                    x: StageAtmosphereMetrics.primaryGlowOffsetXPoints,
                    y: StageAtmosphereMetrics.primaryGlowOffsetYPoints)

            Circle()
                .fill(stageSecondaryAccent.opacity(stageGlowSecondaryOpacity))
                .frame(
                    width: StageAtmosphereMetrics.secondaryGlowSizePoints,
                    height: StageAtmosphereMetrics.secondaryGlowSizePoints
                )
                .blur(radius: StageAtmosphereMetrics.secondaryGlowBlurPoints)
                .offset(
                    x: StageAtmosphereMetrics.secondaryGlowOffsetXPoints,
                    y: StageAtmosphereMetrics.secondaryGlowOffsetYPoints)
        }
        .ignoresSafeArea()
    }

    private var stageCanvas: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if currentStageMode == .album {
                    AlbumPanoramaStageViewTV(
                        panoramaURLs: stageViewModel.albumPanoramaURLs,
                        spotlightURLs: stageViewModel.albumSpotlightURLs,
                        accent: stageAccent,
                        selectedSummary: stageSelectionSummary
                    )
                } else {
                    PeopleConstellationStageViewTV(
                        wallURLs: stageViewModel.peopleWallURLs,
                        spotlightURLs: stageViewModel.peopleSpotlightURLs,
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
                Text(verbatim: stageTitle)
                    .font(.system(size: titleSize(for: size.width), weight: .heavy, design: .rounded))
                    .foregroundStyle(stageTitleColor)
                    .frame(maxWidth: copyColumnWidth(for: size.width), alignment: .leading)
                    .accessibilityIdentifier("filterEditor.page.title")

                Text(verbatim: stageDescription)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(stageDescriptionColor)
                    .frame(maxWidth: copyColumnWidth(for: size.width), alignment: .leading)

                Text(verbatim: stageAmbientSummary)
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
            isAlbumFilterPresented = true
        } label: {
            FloatingSelectionCardViewTV(
                title: "Filter Albums",
                subtitle: "Choose albums to add to the slideshow pool.",
                summary: LocalizedText.format(
                    "%lld albums · %lld photos",
                    Int64(viewModel.selectedAlbumCount),
                    Int64(viewModel.selectedAlbumAssetsCount)
                ),
                accent: Color(red: 0.37, green: 0.84, blue: 0.93),
                previewURLs: stageViewModel.albumSpotlightURLs.isEmpty
                    ? viewModel.albumCoverURLs
                    : stageViewModel.albumSpotlightURLs,
                isFocused: visualFocusedTarget == .albumCard
            )
        }
        .buttonStyle(.plain)
        .focused($focusedTarget, equals: .albumCard)

        .focusedValue(\.filterEditorFocusedTarget, FocusTarget.albumCard.rawValue)
        .appTVDisableDefaultFocusEffect()
        .hoverEffectDisabled(true)
        .accessibilityIdentifier("filter.editor.album.entry")
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
            isPeopleFilterPresented = true
        } label: {
            FloatingSelectionCardViewTV(
                title: "Filter People",
                subtitle: "Choose people to add to the slideshow pool.",
                summary: LocalizedText.format(
                    "%lld people · %lld photos",
                    Int64(viewModel.selectedPersonCount),
                    Int64(viewModel.selectedPersonAssetsCount)
                ),
                accent: Color(red: 0.98, green: 0.72, blue: 0.31),
                previewURLs: stageViewModel.peopleSpotlightURLs.isEmpty
                    ? viewModel.peopleCoverURLs
                    : stageViewModel.peopleSpotlightURLs,
                isFocused: visualFocusedTarget == .peopleCard
            )
        }
        .buttonStyle(.plain)
        .focused($focusedTarget, equals: .peopleCard)
        .focusedValue(\.filterEditorFocusedTarget, FocusTarget.peopleCard.rawValue)
        .appTVDisableDefaultFocusEffect()
        .hoverEffectDisabled(true)
        .accessibilityIdentifier("filter.editor.person.entry")
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
            Text(actionBarSectionTitle)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .kerning(1.2)
                .foregroundStyle(actionBarLabelColor)

            if shouldRenderPrimaryActionButton {
                primaryActionButton
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
        .modifier(TVGlassPanelModifier(cornerRadius: 28, tint: actionBarPanelTint))
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if shouldShowDismissButton {
            Button {
                onDismissRequested?()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                    Text("Done")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .modifier(
                    TVActionButtonBackgroundModifier(
                        isFocused: visualFocusedTarget == .primaryAction,
                        accent: doneAccent
                    )
                )
            }
            .buttonStyle(.plain)
            .focused($focusedTarget, equals: .primaryAction)
            .focusedValue(\.filterEditorFocusedTarget, FocusTarget.primaryAction.rawValue)
            .appTVDisableDefaultFocusEffect()
            .hoverEffectDisabled(true)
            .accessibilityIdentifier("filter.editor.done.button")
            .appTVOnMoveCommand { direction in
                switch direction {
                case .up, .left:
                    moveFocus(to: .peopleCard)
                default:
                    break
                }
            }
        } else {
            Button {
                startFilteredPlayback()
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
                    TVActionButtonBackgroundModifier(
                        isFocused: visualFocusedTarget == .primaryAction,
                        accent: stageAccent
                    )
                )
            }
            .buttonStyle(.plain)
            .disabled(!canStartPlayback)
            .focused($focusedTarget, equals: .primaryAction)
            .focusedValue(\.filterEditorFocusedTarget, FocusTarget.primaryAction.rawValue)
            .appTVDisableDefaultFocusEffect()
            .hoverEffectDisabled(true)
            .appTVDisabledEmphasis(canStartPlayback)
            .accessibilityIdentifier("filter.editor.startPlayback.button")
            .appTVOnMoveCommand { direction in
                switch direction {
                case .up, .left:
                    moveFocus(to: currentStageMode == .album ? .albumCard : .peopleCard)
                default:
                    break
                }
            }
        }
    }

    private var uiTestReadinessMarkers: some View {
        VStack(alignment: .leading, spacing: 1) {
            // localization-audit: ui-test-probe
            Text(verbatim: isAlbumVisualAuditReady ? "ready" : "loading")
                .accessibilityIdentifier("filterEditor.album.ready")
                // localization-audit: ui-test-probe
                .accessibilityValue(Text(verbatim: isAlbumVisualAuditReady ? "ready" : "loading"))
            // localization-audit: ui-test-probe
            Text(verbatim: isPeopleVisualAuditReady ? "ready" : "loading")
                .accessibilityIdentifier("filterEditor.people.ready")
                // localization-audit: ui-test-probe
                .accessibilityValue(Text(verbatim: isPeopleVisualAuditReady ? "ready" : "loading"))
            // localization-audit: ui-test-probe
            Text(verbatim: isFilterEditorVisualAuditReady ? "ready" : "loading")
                .accessibilityIdentifier("filterEditor.visual.ready")
                // localization-audit: ui-test-probe
                .accessibilityValue(Text(verbatim: isFilterEditorVisualAuditReady ? "ready" : "loading"))
        }
        .font(.system(size: 1))
        .foregroundStyle(Color.clear)
        .frame(width: 2, height: 3, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    private func startFilteredPlayback() {
        onStartPlaybackRequested?(viewModel.selection)
    }

    private var stageCornerRadius: CGFloat { 0 }
    private var dockHeight: CGFloat { 286 }

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
