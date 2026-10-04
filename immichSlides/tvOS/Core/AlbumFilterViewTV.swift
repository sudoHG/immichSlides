//
//  AlbumFilterViewTV.swift
//  immichSlides
//
//  Created by Codex during tvOS adaptation.
//

import SwiftUI
import UIKit

// FocusedValue reports the system's actual focus, since it isn't always in sync with @FocusState.

private struct AlbumFilterFocusedAlbumIDKey: FocusedValueKey {
    typealias Value = String
}

private extension FocusedValues {
    var albumFilterFocusedAlbumID: String? {
        get { self[AlbumFilterFocusedAlbumIDKey.self] }
        set { self[AlbumFilterFocusedAlbumIDKey.self] = newValue }
    }
}

struct AlbumFilterViewTV: View {
    private enum FocusTarget: Hashable {
        case album(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.resetFocus) private var resetFocus
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: FilterViewModel
    @Binding var isLoading: Bool
    @Binding var didFinishInitialLoad: Bool
    @FocusState private var focusedTarget: FocusTarget?
    // Read the system's actual focus, since it isn't always in sync with @FocusState.

    @FocusedValue(\.albumFilterFocusedAlbumID) private var systemFocusedAlbumID: String?
    @Namespace private var albumsFocusScope

    fileprivate enum Layout {
        static let cardWidth: CGFloat = 320
        static let gridSpacing: CGFloat = 34
        static let horizontalPadding: CGFloat = 44
        static let topPadding: CGFloat = 18
        static let bottomPadding: CGFloat = 40
    }

    private var contentWidth: CGFloat {
        UIScreen.main.bounds.width - (Layout.horizontalPadding * 2)
    }

    private var gridColumnCount: Int {
        let cellFootprint = Layout.cardWidth + Layout.gridSpacing
        let estimatedColumnCount = Int((contentWidth + Layout.gridSpacing) / cellFootprint)
        return max(1, estimatedColumnCount)
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
            "%lld albums selected · %lld photos",
            Int64(viewModel.selectedAlbumCount),
            Int64(viewModel.selectedAlbumAssetsCount)
        )
    }

    private var defaultFocusAlbumID: String? {
        viewModel.albums.first?.id
    }

    private var requestedFocusedAlbumID: String? {
        guard case let .album(id)? = focusedTarget else { return nil }
        return id
    }

    private var focusedAlbumID: String? {
        systemFocusedAlbumID
    }

    private var visualFocusedAlbumID: String? {
        focusedAlbumID ?? requestedFocusedAlbumID
    }

    private var pageBackgroundColors: [Color] {
        if colorScheme == .light {
            return [
                Color(red: 0.95, green: 0.96, blue: 0.99),
                Color(red: 0.90, green: 0.93, blue: 0.98)
            ]
        }

        return [
            Color(red: 0.08, green: 0.09, blue: 0.11),
            Color(red: 0.05, green: 0.06, blue: 0.08)
        ]
    }

    var body: some View {
        rootScene
    }

    private var rootScene: some View {
        ZStack {
            backgroundLayer

            Group {
                if isLoading {
                    SlidePlaybackLoadingView(accessibilityIdentifier: "albumFilter.loading.indicator")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if didFinishInitialLoad,
                    viewModel.albums.isEmpty,
                    let errorMessage = viewModel.albumLoadErrorMessage
                {
                    errorState(message: errorMessage)
                } else if didFinishInitialLoad && viewModel.albums.isEmpty {
                    emptyState
                } else {
                    albumsScopedContent
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            seedInitialFocusIfNeeded(forceIfMissing: true)
        }
        .onChange(of: viewModel.albums.map(\.id)) { _, _ in
            seedInitialFocusIfNeeded(forceIfMissing: true)
        }
        .onChange(of: systemFocusedAlbumID) { _, newValue in
            guard let newValue else { return }
            let nextTarget = FocusTarget.album(newValue)
            guard focusedTarget != nextTarget else { return }
            focusedTarget = nextTarget
        }
    }

    @ViewBuilder
    private var albumsScopedContent: some View {
        if let defaultFocusAlbumID {
            content
                .appTVFocusScope(
                    albumsFocusScope,
                    focused: $focusedTarget,
                    default: .album(defaultFocusAlbumID)
                )
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Layout.gridSpacing) {
                ForEach(Array(albumRows.enumerated()), id: \.offset) { _, rowAlbums in
                    albumRow(rowAlbums)
                }
            }
            .frame(width: contentWidth, alignment: .center)
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.top, Layout.topPadding)
            .padding(.bottom, Layout.bottomPadding)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            FilterTopBarView(
                title: "Filter Albums",
                summary: topBarSummary,
                layout: .init(horizontalSizeClass: .regular, verticalSizeClass: .regular, userInterfaceIdiom: .tv),
                onBack: { dismiss() },
                onSelectAll: { viewModel.selectAllAlbum() },
                onClear: { viewModel.removeAllAlbumSelection() },
                backButtonAccessibilityID: "albumFilter.back.button",
                selectAllButtonAccessibilityID: "albumFilter.selectAll.button",
                clearButtonAccessibilityID: "albumFilter.clear.button"
            )
            .padding(.horizontal, topBarAdditionalHorizontalPadding)
            .padding(.top, 14)

            .appTVFocusSection()
        }
    }

    private var albumRows: [[Album]] {
        let columnCount = gridColumnCount

        return stride(from: 0, to: viewModel.albums.count, by: columnCount).map { startIndex in
            let endIndex = min(startIndex + columnCount, viewModel.albums.count)
            return Array(viewModel.albums[startIndex..<endIndex])
        }
    }

    private func albumRow(_ rowAlbums: [Album]) -> some View {

        HStack(alignment: .top, spacing: Layout.gridSpacing) {
            ForEach(rowAlbums) { album in
                albumCard(album)
            }
        }
        .frame(width: fullRowOccupiedWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .appTVFocusSection()
    }

    private func albumCard(_ album: Album) -> some View {
        let isSelected = viewModel.isAlbumSelected(id: album.id)
        let isFocused = visualFocusedAlbumID == album.id

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                viewModel.toggleAlbum(id: album.id)
                focusedTarget = .album(album.id)
            }
        } label: {
            TVAlbumFilterCard(
                albumDisplayName: displayName(for: album),
                coverURL: viewModel.albumCoverURLByID[album.id],
                assetCount: album.assetCount,
                isSelected: isSelected,
                isFocused: isFocused,
                isLightAppearance: colorScheme == .light
            )
            .frame(width: Layout.cardWidth)
        }
        .buttonStyle(.plain)
        .focused($focusedTarget, equals: .album(album.id))
        .focusedValue(\.albumFilterFocusedAlbumID, album.id)
        .prefersDefaultFocus(album.id == defaultFocusAlbumID, in: albumsFocusScope)
        .appTVDisableDefaultFocusEffect()
        .hoverEffectDisabled(true)
        .accessibilityIdentifier("albumFilter.album.\(album.id).button")
        .accessibilityLabel(displayName(for: album))
        .accessibilityValue(cardAccessibilityValue(isSelected: isSelected, isFocused: isFocused))
        .accessibilityHint("Press Select to toggle album selection.")
    }

    private func cardAccessibilityValue(isSelected: Bool, isFocused: Bool) -> String {
        let baseState = isSelected ? String(localized: "Selected") : String(localized: "Not Selected")
        if isFocused {
            return LocalizedText.format("%@, Focused", baseState)
        }
        return baseState
    }

    private func displayName(for album: Album) -> String {
        let trimmedName = album.albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? String(localized: "Unnamed Album") : trimmedName
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 15) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.yellow)
            Text("Failed to load albums")
                .font(.title)
            Text(LocalizedStringKey(message))
                .font(.headline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task {
                    await MainActor.run { isLoading = true }
                    await viewModel.getCoverURLs(filterType: .albums, coverLimit: nil, shouldReset: false)
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
            Image(systemName: "photo.on.rectangle.angled")
                .foregroundStyle(.secondary)
                .font(.system(size: 42, weight: .regular))

            Text("No albums in Immich yet. Add some albums and come back.")
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
        .accessibilityIdentifier("albumFilter.back.button")
        .appTVFocusSection()
    }

    private func seedInitialFocusIfNeeded(forceIfMissing: Bool) {
        guard let defaultFocusAlbumID else { return }

        if let focusedAlbumID,
            viewModel.albums.contains(where: { $0.id == focusedAlbumID })
        {
            return
        }

        if forceIfMissing || focusedTarget == nil {
            let nextTarget = FocusTarget.album(defaultFocusAlbumID)

            // The top bar gets focus first, so take focus back to the first card in two stages over 180ms.

            Task { @MainActor in
                focusedTarget = nil
                resetFocus(in: albumsFocusScope)

                try? await Task.sleep(nanoseconds: 180_000_000)

                focusedTarget = nextTarget
                resetFocus(in: albumsFocusScope)
            }
        }
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
