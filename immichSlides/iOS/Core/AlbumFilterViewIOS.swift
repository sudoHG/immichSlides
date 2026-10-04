//
//  AlbumFilterViewIOS.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI

struct AlbumFilterViewIOS: View {
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
        let minimumWidth: CGFloat = layout.isPhone ? (layout.isCompactHeight ? 160 : 170) : 230
        let maximumWidth: CGFloat = layout.isPhone ? 240 : 310
        return [GridItem(.adaptive(minimum: minimumWidth, maximum: maximumWidth), spacing: gridSpacing)]
    }

    private var horizontalPadding: CGFloat { layout.isPhone ? 16 : 24 }
    private var gridSpacing: CGFloat { layout.isCompactHeight ? 14 : 18 }

    var body: some View {
        Group {
            if isLoading {
                SlidePlaybackLoadingView(accessibilityIdentifier: "albumFilter.loading.indicator")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if didFinishInitialLoad, viewModel.albums.isEmpty, let errorMessage = viewModel.albumLoadErrorMessage
            {
                errorState(message: errorMessage)
            } else if didFinishInitialLoad && viewModel.albums.isEmpty {
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
                ForEach(viewModel.albums) { album in
                    albumCard(album)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            FilterTopBarView(
                title: "Filter Albums",
                // The summary uses a stable %lld template so changing numbers do not create new localization keys.

                summary: LocalizedText.format(
                    "Selected albums: %lld, photos: %lld",
                    Int64(viewModel.selectedAlbumCount),
                    Int64(viewModel.selectedAlbumAssetsCount)
                ),
                layout: layout,
                onBack: { dismiss() },
                onSelectAll: { viewModel.selectAllAlbum() },
                onClear: { viewModel.removeAllAlbumSelection() },
                // The custom back button has a stable accessibilityIdentifier so UI tests do not rely on the title.

                backButtonAccessibilityID: "albumFilter.back.button",
                selectAllButtonAccessibilityID: "albumFilter.selectAll.button",
                clearButtonAccessibilityID: "albumFilter.clear.button"
            )
        }
    }

    private func albumCard(_ album: Album) -> some View {
        let isSelected = viewModel.isAlbumSelected(id: album.id)

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                viewModel.toggleAlbum(id: album.id)
            }
        } label: {
            Group {
                if let url = viewModel.albumCoverURLByID[album.id] {
                    CoverCardView(
                        name: album.albumName,
                        coverURL: url,
                        assetsCount: album.assetCount
                    )
                } else {
                    albumPlaceholder(album)
                }
            }
            .aspectRatio(layout.isCompactHeight ? 1.18 : 1.34, contentMode: .fit)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(cardBackgroundColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(isSelected ? Color.green.opacity(0.82) : cardBorderColor, lineWidth: isSelected ? 2.5 : 1)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: layout.isCompactHeight ? 22 : 26, weight: .bold))
                    .foregroundStyle(isSelected ? Color.green : Color.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
                    .padding(layout.isCompactHeight ? 10 : 14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 16, x: 0, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("albumFilter.album.\(album.id).button")
    }

    private func albumPlaceholder(_ album: Album) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)

            LinearGradient(
                colors: [.black.opacity(0.72), .clear],
                startPoint: .bottom,
                endPoint: .top
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(album.albumName)
                    .foregroundStyle(.white)
                    .font(.system(size: layout.isPhone ? 18 : 21, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(LocalizedText.format("%lld photos", Int64(album.assetCount)))
                    .foregroundStyle(.white.opacity(0.74))
                    .font(.system(size: layout.isPhone ? 13 : 16, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 15) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.yellow)
            Text("Failed to load albums")
                .font(.title3.weight(.semibold))
            Text(LocalizedStringKey(message))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Retry") {
                Task {
                    await MainActor.run { isLoading = true }
                    await viewModel.getCoverURLs(filterType: .albums, coverLimit: nil, shouldReset: false)
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
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No albums in Immich yet")
                .font(.title3.weight(.semibold))
            Text("Add some albums on the server, then come back to set up filters.")
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
        // Empty/error states have no top bar and the system nav bar is hidden; add our own Back or users are stuck.

        Button {
            dismiss()
        } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .appButtonRole(.secondary)
        .accessibilityIdentifier("albumFilter.back.button")
    }

    private var backgroundLayer: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.08, green: 0.09, blue: 0.11), Color(red: 0.05, green: 0.06, blue: 0.08)]
                : [Color(red: 0.96, green: 0.98, blue: 1.0), Color(red: 0.93, green: 0.96, blue: 0.99)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var cardBackgroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.white.opacity(0.92)
    }

    private var cardBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.08)
    }
}
