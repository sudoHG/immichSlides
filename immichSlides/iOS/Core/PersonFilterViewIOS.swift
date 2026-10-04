//
//  PersonFilterViewIOS.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI

struct PersonFilterViewIOS: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var viewModel: FilterViewModel
    @Binding var isLoading: Bool
    @Binding var didFinishInitialLoad: Bool

    private var layout: ViewLayoutTraits {
        ViewLayoutTraits(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            userInterfaceIdiom: UIDevice.current.userInterfaceIdiom
        )
    }

    private var gridColumns: [GridItem] {
        let minimumWidth: CGFloat = layout.isPhone ? (layout.isCompactHeight ? 150 : 160) : 220
        let maximumWidth: CGFloat = layout.isPhone ? 220 : 300
        return [GridItem(.adaptive(minimum: minimumWidth, maximum: maximumWidth), spacing: gridSpacing)]
    }

    private var horizontalPadding: CGFloat { layout.isPhone ? 16 : 24 }
    private var gridSpacing: CGFloat { layout.isCompactHeight ? 14 : 18 }

    var body: some View {
        Group {
            if isLoading {
                SlidePlaybackLoadingView(accessibilityIdentifier: "personFilter.loading.indicator")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if didFinishInitialLoad, viewModel.people.isEmpty,
                let errorMessage = viewModel.peopleLoadErrorMessage
            {
                errorState(message: errorMessage)
            } else if didFinishInitialLoad && viewModel.people.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .background(backgroundLayer)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var content: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: gridSpacing) {
                ForEach(viewModel.people) { person in
                    personCard(person)
                        .task(id: person.id) {
                            await viewModel.loadPersonAssetsCountIfNeeded(id: person.id)
                        }
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            FilterTopBarView(
                title: "Filter People",
                // The summary uses a stable %lld template so changing numbers do not create new localization keys.
                summary: LocalizedText.format(
                    "Selected people: %lld, photos: %lld",
                    Int64(viewModel.selectedPersonCount),
                    Int64(viewModel.selectedPersonAssetsCount)
                ),
                layout: layout,
                onBack: { dismiss() },
                onSelectAll: { viewModel.selectAllPerson() },
                onClear: { viewModel.removeAllPersonSelection() },

                backButtonAccessibilityID: "personFilter.back.button",
                selectAllButtonAccessibilityID: "personFilter.selectAll.button",
                clearButtonAccessibilityID: "personFilter.clear.button"
            )
        }
    }

    private func personCard(_ person: People) -> some View {
        PersonFilterCardView(
            personName: displayName(for: person),
            personCoverURL: viewModel.peopleCoverURLByID[person.id],
            personAssetsCount: viewModel.personAssetsCountByID[person.id],
            isSelected: Binding(
                get: { viewModel.isPersonSelected(id: person.id) },
                set: { newValue in
                    let currentValue = viewModel.isPersonSelected(id: person.id)
                    if newValue != currentValue {
                        viewModel.togglePerson(id: person.id)
                    }
                }
            ),
            matchMode: Binding(
                get: { viewModel.getPersonMatchMode(id: person.id) ?? .normal },
                set: { newMode in
                    viewModel.setPersonMatchMode(id: person.id, mode: newMode)
                }
            )
        )
        .accessibilityIdentifier("personFilter.person.\(person.id).button")
    }

    private func displayName(for person: People) -> String {
        let trimmedName = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? String(localized: "Unnamed Person") : trimmedName
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 15) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.yellow)
            Text("Failed to load people")
                .font(.title3.weight(.semibold))
            Text(LocalizedStringKey(message))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Retry") {
                Task {
                    await MainActor.run { isLoading = true }
                    await viewModel.getCoverURLs(filterType: .people, coverLimit: nil, reset: false)
                    await MainActor.run {
                        didFinishInitialLoad = true
                        isLoading = false
                    }
                }
            }
            .appButtonRole(.primary)
            stateBackButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundLayer)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.fill.questionmark")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No people in Immich yet")
                .font(.title3.weight(.semibold))
            Text("Come back and configure people filters after the server finishes recognition.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            stateBackButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundLayer)
    }

    private var stateBackButton: some View {

        Button {
            dismiss()
        } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .appButtonRole(.secondary)
        .accessibilityIdentifier("personFilter.back.button")
    }

    private var backgroundLayer: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.09, green: 0.08, blue: 0.11), Color(red: 0.06, green: 0.05, blue: 0.08)]
                : [Color(red: 0.98, green: 0.97, blue: 1.0), Color(red: 0.95, green: 0.94, blue: 0.99)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
