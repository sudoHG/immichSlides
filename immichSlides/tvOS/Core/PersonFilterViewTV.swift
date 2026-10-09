//
//  PersonFilterViewTV.swift
//  immichSlides
//
//  Created by Codex during tvOS adaptation.
//

import SwiftUI
import UIKit

private enum FocusHandoffTiming {
    static let delayNanoseconds: UInt64 = 180_000_000
}

private struct PersonFilterFocusedPersonIDKey: FocusedValueKey {
    typealias Value = String
}

private extension FocusedValues {
    var personFilterFocusedPersonID: String? {
        get { self[PersonFilterFocusedPersonIDKey.self] }
        set { self[PersonFilterFocusedPersonIDKey.self] = newValue }
    }
}

struct PersonFilterViewTV: View {
    private enum FocusTarget: Hashable {
        case person(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.resetFocus) private var resetFocus
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: FilterViewModel
    @Binding var isLoading: Bool
    @Binding var didFinishInitialLoad: Bool

    @FocusState private var focusedTarget: FocusTarget?

    @FocusedValue(\.personFilterFocusedPersonID) private var systemFocusedPersonID: String?
    @Namespace private var peopleFocusScope

    fileprivate enum Layout {

        static let cardWidth: CGFloat = 320
        static let cardHeight: CGFloat = 470
        static let cardCornerRadius: CGFloat = 30
        static let gridSpacing: CGFloat = 42
        static let horizontalPadding: CGFloat = 44
        static let topPadding: CGFloat = 18
        static let bottomPadding: CGFloat = 42

    }

    private var gridColumnCount: Int {
        let cellFootprint = Layout.cardWidth + Layout.gridSpacing
        let estimatedColumnCount = Int((contentWidth + Layout.gridSpacing) / cellFootprint)
        return max(1, estimatedColumnCount)
    }

    private var contentWidth: CGFloat {
        UIScreen.main.bounds.width - (Layout.horizontalPadding * 2)
    }

    private var fullRowOccupiedWidth: CGFloat {
        let columnCount = CGFloat(gridColumnCount)
        guard columnCount > 0 else { return 0 }

        let totalCardWidth = columnCount * Layout.cardWidth
        let totalSpacing = max(0, columnCount - 1) * Layout.gridSpacing
        return totalCardWidth + totalSpacing
    }

    private var rowSideInset: CGFloat {
        max(0, (contentWidth - fullRowOccupiedWidth) / 2)
    }

    private var topBarAdditionalHorizontalPadding: CGFloat {
        max(0, Layout.horizontalPadding + rowSideInset - 12)
    }

    private var topBarSummary: String {
        LocalizedText.format(
            "%lld people selected · %lld photos",
            Int64(viewModel.selectedPersonCount),
            Int64(viewModel.selectedPersonAssetsCount)
        )
    }

    private var defaultFocusPersonID: String? {
        viewModel.people.first?.id
    }

    private var requestedFocusedPersonID: String? {
        guard case let .person(id)? = focusedTarget else { return nil }
        return id
    }

    private var focusedPersonID: String? {
        systemFocusedPersonID
    }

    private var visualFocusedPersonID: String? {
        focusedPersonID ?? requestedFocusedPersonID
    }

    private var focusedPerson: People? {
        guard let focusedPersonID else { return nil }
        return viewModel.people.first(where: { $0.id == focusedPersonID })
    }

    private var bodyShortcutContext: TVPersonShortcutContext {
        guard let focusedPerson else {
            return .empty
        }

        let personID = focusedPerson.id
        let isSelected = viewModel.isPersonSelected(id: personID)
        let isSoloOnly = viewModel.getPersonMatchMode(id: personID) == .soloOnly

        return .person(
            name: displayName(for: focusedPerson),
            isSelected: isSelected,
            isSoloOnly: isSoloOnly
        )
    }

    private var topBarCommandHints: [FilterTopBarCommandHint] {
        [
            FilterTopBarCommandHint(
                id: "select",
                iconName: "checkmark.circle.fill",
                title: "Select",
                detail: bodyShortcutContext.selectActionText,
                accent: Color.green
            ),
            FilterTopBarCommandHint(
                id: "playPause",
                iconName: "playpause.fill",
                title: "Play/Pause",
                detail: bodyShortcutContext.playPauseActionText,
                accent: bodyShortcutContext.playPauseAccent
            )
        ]
    }

    private var pageBackgroundColors: [Color] {
        if colorScheme == .light {
            return [
                Color(red: 0.95, green: 0.96, blue: 0.99),
                Color(red: 0.89, green: 0.92, blue: 0.97)
            ]
        }

        return [
            Color(red: 0.09, green: 0.08, blue: 0.11),
            Color(red: 0.06, green: 0.05, blue: 0.08)
        ]
    }

    @ViewBuilder
    var body: some View {
        rootScene
    }

    private var rootScene: some View {
        ZStack {
            backgroundLayer

            Group {
                if isLoading {
                    SlidePlaybackLoadingView(accessibilityIdentifier: "personFilter.loading.indicator")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if didFinishInitialLoad,
                    viewModel.people.isEmpty,
                    let errorMessage = viewModel.peopleLoadErrorMessage
                {
                    errorState(message: errorMessage)
                } else if didFinishInitialLoad && viewModel.people.isEmpty {
                    emptyState
                } else {
                    peopleScopedContent
                }
            }

        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            seedInitialFocusIfNeeded(shouldForceInitialFocus: true)
        }
        .onChange(of: viewModel.people.map(\.id)) { _, _ in

            seedInitialFocusIfNeeded(shouldForceInitialFocus: true)
        }
        .onChange(of: systemFocusedPersonID) { _, newValue in
            guard let newValue else { return }

            let nextTarget = FocusTarget.person(newValue)

            guard focusedTarget != nextTarget else { return }
            focusedTarget = nextTarget
        }
        .onPlayPauseCommand {

            handlePlayPauseCommand()
        }
    }

    @ViewBuilder
    private var peopleScopedContent: some View {
        if let defaultFocusPersonID {
            content
                .appTVFocusScope(
                    peopleFocusScope,
                    focused: $focusedTarget,
                    default: .person(defaultFocusPersonID)
                )
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Layout.gridSpacing) {
                ForEach(Array(personRows.enumerated()), id: \.offset) { _, rowPeople in
                    personRow(rowPeople)
                }
            }

            .frame(width: contentWidth, alignment: .center)
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.top, Layout.topPadding)
            .padding(.bottom, Layout.bottomPadding)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            FilterTopBarView(
                title: "Filter People",
                summary: topBarSummary,
                layout: .init(horizontalSizeClass: .regular, verticalSizeClass: .regular, userInterfaceIdiom: .tv),
                onBack: { dismiss() },
                onSelectAll: { viewModel.selectAllPerson() },
                onClear: { viewModel.removeAllPersonSelection() },
                backButtonAccessibilityID: "personFilter.back.button",
                selectAllButtonAccessibilityID: "personFilter.selectAll.button",
                clearButtonAccessibilityID: "personFilter.clear.button",
                commandHintSummary: bodyShortcutContext.summaryText,
                commandHints: topBarCommandHints,
                commandHintAccessibilityID: "personFilter.shortcuts.bar"
            )
            .padding(.horizontal, topBarAdditionalHorizontalPadding)
            .padding(.top, 14)
            .appTVFocusSection()
        }
    }

    private var personRows: [[People]] {
        let columnCount = gridColumnCount

        return stride(from: 0, to: viewModel.people.count, by: columnCount).map { startIndex in
            let endIndex = min(startIndex + columnCount, viewModel.people.count)
            return Array(viewModel.people[startIndex..<endIndex])
        }
    }

    private func personRow(_ rowPeople: [People]) -> some View {
        HStack(spacing: 0) {

            Spacer(minLength: 0)

            HStack(alignment: .top, spacing: Layout.gridSpacing) {
                ForEach(rowPeople) { person in
                    personCard(person)
                        .task(id: person.id) {

                            await viewModel.loadPersonAssetsCountIfNeeded(id: person.id)
                        }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)

        .appTVFocusSection()
    }

    private func personCard(_ person: People) -> some View {
        let personID = person.id
        let isSelected = viewModel.isPersonSelected(id: personID)
        let isSoloOnly = viewModel.getPersonMatchMode(id: personID) == .soloOnly
        let isFocused = visualFocusedPersonID == personID

        return Button {

            togglePersonSelection(id: personID)
        } label: {
            TVPersonCommandCard(
                personName: displayName(for: person),
                personCoverURL: viewModel.peopleCoverURLByID[personID],
                personAssetsCount: viewModel.personAssetsCountByID[personID],
                isSelected: isSelected,
                isSoloOnly: isSoloOnly,
                isFocused: isFocused,
                isLightAppearance: colorScheme == .light,
                playPauseHintText: playPauseActionText(isSelected: isSelected, isSoloOnly: isSoloOnly),
                playPauseHintAccent: playPauseActionAccent(isSelected: isSelected, isSoloOnly: isSoloOnly)
            )
            .frame(width: Layout.cardWidth, height: Layout.cardHeight)
            .contentShape(RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focusedTarget, equals: .person(personID))

        .focusedValue(\.personFilterFocusedPersonID, personID)
        .prefersDefaultFocus(personID == defaultFocusPersonID, in: peopleFocusScope)

        .appTVDisableDefaultFocusEffect()
        .hoverEffectDisabled(true)
        .accessibilityIdentifier("personFilter.person.\(personID).button")
        .accessibilityLabel(displayName(for: person))
        .accessibilityValue(
            cardAccessibilityValue(
                isSelected: isSelected,
                isSoloOnly: isSoloOnly,
                isFocused: isFocused
            )
        )
        .accessibilityHint("Press Select to toggle selection, and Play/Pause to toggle solo mode.")
    }

    private func togglePersonSelection(id: String) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            viewModel.togglePerson(id: id)
            focusedTarget = .person(id)
        }
    }

    private func setPersonNormalMode(id: String) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            viewModel.setPersonMatchMode(id: id, mode: .normal)
            focusedTarget = .person(id)
        }
    }

    private func setPersonSoloMode(id: String) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            viewModel.setPersonMatchMode(id: id, mode: .soloOnly)
            focusedTarget = .person(id)
        }
    }

    private func handlePlayPauseCommand() {
        guard let focusedPersonID else { return }

        switch viewModel.getPersonMatchMode(id: focusedPersonID) {
        case .none:

            setPersonSoloMode(id: focusedPersonID)
        case .some(.normal):
            setPersonSoloMode(id: focusedPersonID)
        case .some(.soloOnly):
            setPersonNormalMode(id: focusedPersonID)
        }
    }

    private func playPauseActionText(isSelected: Bool, isSoloOnly: Bool) -> String {

        if isSelected == false {
            return String(localized: "Set to Solo Mode")
        }
        return isSoloOnly
            ? String(localized: "Switch to Normal Mode")
            : String(localized: "Switch to Solo Mode")
    }

    private func playPauseActionAccent(isSelected: Bool, isSoloOnly: Bool) -> Color {

        return Color.orange
    }

    private func seedInitialFocusIfNeeded(shouldForceInitialFocus: Bool) {
        guard let defaultFocusPersonID else { return }

        // On refresh, keep focus if the current person is still present, instead of jumping back to the first card.

        if let focusedPersonID,
            viewModel.people.contains(where: { $0.id == focusedPersonID })
        {
            return
        }

        // Fall back to the first card only when there is no valid focus.

        if shouldForceInitialFocus || focusedTarget == nil {
            let nextTarget = FocusTarget.person(defaultFocusPersonID)

            // The top bar gets focus first, so take focus back to the first card in two stages over 180ms.

            Task { @MainActor in
                focusedTarget = nil
                resetFocus(in: peopleFocusScope)

                try? await Task.sleep(nanoseconds: FocusHandoffTiming.delayNanoseconds)

                focusedTarget = nextTarget
                resetFocus(in: peopleFocusScope)
            }
        }
    }

    private func cardAccessibilityValue(isSelected: Bool, isSoloOnly: Bool, isFocused: Bool) -> String {
        // hasFocus is unreliable on a custom focusable, so write the focus state into accessibilityValue for UI tests.

        let baseState: String
        if isSelected {
            baseState =
                isSoloOnly
                ? String(localized: "Selected, Solo Mode")
                : String(localized: "Selected, Normal Mode")
        } else {
            baseState = String(localized: "Not Selected")
        }

        if isFocused {
            return LocalizedText.format("%@, Focused", baseState)
        }
        return baseState
    }

    private func displayName(for person: People) -> String {
        let trimmedName = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? String(localized: "Unnamed Person") : trimmedName
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 15) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.yellow)

            Text("Failed to load people list")
                .font(.title)

            Text(LocalizedStringKey(message))
                .font(.headline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task {
                    await MainActor.run { isLoading = true }
                    await viewModel.getCoverURLs(filterType: .people, coverLimit: nil, shouldReset: false)
                    await MainActor.run {
                        didFinishInitialLoad = true
                        isLoading = false
                    }
                }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
            }
            .appButtonRole(.primary)

            stateBackButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 15) {
            Image(systemName: "person.fill.questionmark")
                .foregroundStyle(.secondary)
                .font(.system(size: 42, weight: .regular))

            Text("No people in Immich yet")
                .font(.title3.weight(.semibold))

            Text("Come back and configure people filters after the server finishes recognition.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            stateBackButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stateBackButton: some View {

        Button {
            dismiss()
        } label: {
            Label("Back", systemImage: "chevron.left.circle.fill")
                .font(.system(size: 18, weight: .semibold))
        }
        .appButtonRole(.secondary)
        .accessibilityIdentifier("personFilter.back.button")
        .appTVFocusSection()
    }

    private var backgroundLayer: some View {
        LinearGradient(
            colors: pageBackgroundColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private enum TVPersonShortcutContext {
    case empty
    case person(name: String, isSelected: Bool, isSoloOnly: Bool)

    var summaryText: String {
        switch self {
        case .empty:
            return String(localized: "Move focus to a person card to use remote shortcuts.")
        case let .person(name, isSelected, isSoloOnly):
            let state: String
            if isSelected {

                state =
                    isSoloOnly
                    ? String(localized: "Solo Mode · Excludes group photos")
                    : String(localized: "Normal Mode · Includes group photos")
            } else {
                state = String(localized: "Not Selected")
            }
            return LocalizedText.format("Current person: %@ · %@", name, state)
        }
    }

    var selectActionText: String {
        switch self {
        case .empty:
            return String(localized: "Select Person")
        case let .person(_, isSelected, _):
            return isSelected ? String(localized: "Deselect") : String(localized: "Select Person")
        }
    }

    var playPauseActionText: String {
        switch self {
        case .empty:
            return String(localized: "Set to Solo Mode")
        case let .person(_, isSelected, isSoloOnly):
            if isSelected == false {
                return String(localized: "Set to Solo Mode")
            }
            return isSoloOnly
                ? String(localized: "Switch to Normal Mode")
                : String(localized: "Switch to Solo Mode")
        }
    }

    var playPauseAccent: Color {
        Color.orange
    }
}

private struct PersonFilterTVPreviewHost: View {

    private let storedSelectionBeforePreview: FilterSelection?

    @StateObject private var viewModel: FilterViewModel

    @State private var isLoading: Bool = false
    @State private var didFinishInitialLoad: Bool = true

    init() {

        let previewStore = FilterSelectionStore()
        let storedSelection = previewStore.load()

        self.storedSelectionBeforePreview = storedSelection
        _viewModel = StateObject(wrappedValue: FilterViewModel.personFilterTVPreviewModel())
    }

    var body: some View {
        NavigationStack {
            PersonFilterViewTV(
                viewModel: viewModel,
                isLoading: $isLoading,
                didFinishInitialLoad: $didFinishInitialLoad
            )
        }
        .onDisappear {
            restoreStoredSelectionIfNeeded()
        }
    }

    private func restoreStoredSelectionIfNeeded() {

        let previewStore = FilterSelectionStore()

        if let storedSelectionBeforePreview {
            previewStore.save(storedSelectionBeforePreview)
        } else {
            previewStore.clear()
        }
    }
}

#Preview {
    PersonFilterTVPreviewHost()
}
