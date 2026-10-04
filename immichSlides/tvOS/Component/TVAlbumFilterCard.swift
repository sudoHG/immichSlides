import SwiftUI

struct TVAlbumFilterCard: View {
    let albumDisplayName: String
    let coverURL: URL?
    let assetCount: Int
    let isSelected: Bool
    let isFocused: Bool
    let isLightAppearance: Bool

    private enum Layout {
        static let cardAspectRatio: CGFloat = 1.34
        static let cardCornerRadius: CGFloat = 32
        static let focusedScale: CGFloat = 1.04
        static let focusedOutlineWidth: CGFloat = 4
        static let selectedOutlineWidth: CGFloat = 2
        static let selectionMarkSize: CGFloat = 28
        static let selectionMarkInset: CGFloat = 16
    }

    private var cardSurfaceColor: Color {
        if isLightAppearance {
            return Color.white.opacity(0.86)
        }
        return Color.white.opacity(0.05)
    }

    private var neutralBorderColor: Color {
        if isLightAppearance {
            return Color.black.opacity(0.10)
        }
        return Color.white.opacity(0.12)
    }

    private var focusOutlineColor: Color {
        if isLightAppearance {
            return Color.black.opacity(0.26)
        }
        return Color.cyan.opacity(0.95)
    }

    private var unselectedIndicatorColor: Color {
        if isLightAppearance {

            return Color.white
        }
        return Color.white.opacity(0.95)
    }

    var body: some View {
        albumArtwork
            .aspectRatio(Layout.cardAspectRatio, contentMode: .fit)
            .background(
                RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                    .fill(cardSurfaceColor)
            )
            .overlay {
                albumSelectionOverlay(isSelected: isSelected, cornerRadius: Layout.cardCornerRadius)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                    .stroke(
                        isFocused ? focusOutlineColor : neutralBorderColor,
                        lineWidth: isFocused ? Layout.focusedOutlineWidth : 1
                    )
            }
            .shadow(color: .black.opacity(isFocused ? 0.38 : 0.18), radius: isFocused ? 24 : 14, x: 0, y: 12)
            .scaleEffect(isFocused ? Layout.focusedScale : 1.0)
            .animation(.easeInOut(duration: 0.18), value: isFocused)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: isSelected)
    }

    @ViewBuilder
    private var albumArtwork: some View {
        if let url = coverURL {
            CoverCardView(
                name: albumDisplayName,
                coverURL: url,
                assetsCount: assetCount
            )
            .clipShape(RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous))
            .shadow(radius: 10)
        } else {
            ZStack(alignment: .bottomLeading) {

                if isLightAppearance {
                    RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.80))
                } else {
                    RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                }

                LinearGradient(
                    colors: [.black.opacity(0.7), .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .clipShape(RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(albumDisplayName)
                        .foregroundColor(.white)
                        .font(.system(size: 21, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text(LocalizedText.format("%lld photos", Int64(assetCount)))
                        .foregroundColor(.white.opacity(0.75))
                        .font(.system(size: 18, weight: .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                    .stroke(isLightAppearance ? Color.black.opacity(0.10) : Color.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(radius: 10)
        }
    }

    @ViewBuilder
    private func albumSelectionOverlay(isSelected: Bool, cornerRadius: CGFloat) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.green, lineWidth: Layout.selectedOutlineWidth)
                .shadow(radius: 5)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: Layout.selectionMarkSize, weight: .bold))
                        .foregroundStyle(Color.green)
                        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
                        .padding(Layout.selectionMarkInset)
                        .transition(.scale.combined(with: .opacity))
                }
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.clear, lineWidth: 0)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "circle")
                        .font(.system(size: Layout.selectionMarkSize, weight: .bold))
                        .foregroundStyle(unselectedIndicatorColor)
                        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
                        .padding(Layout.selectionMarkInset)
                }
        }
    }
}
