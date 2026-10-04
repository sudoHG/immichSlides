//
//  ModeCardViewIOS.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI

// The iOS card handles touch layout; it does not handle remote focus.

struct ModeCardViewIOS: View {
    @Environment(\.colorScheme) private var colorScheme

    let icon: String
    let title: String
    let description: String
    let isCompact: Bool
    let isCompactHeight: Bool
    let isSelected: Bool

    private var iconSize: CGFloat {
        if isCompactHeight { return 40 }
        return isCompact ? 56 : 84
    }

    private var titleSize: CGFloat {
        if isCompactHeight { return 16 }
        return isCompact ? 18 : 26
    }

    private var descriptionSize: CGFloat {
        if isCompactHeight { return 12 }
        return isCompact ? 14 : 17
    }

    private var contentHorizontalPadding: CGFloat {
        if isCompactHeight { return 8 }
        return isCompact ? 16 : 32
    }

    private var contentVerticalPadding: CGFloat {
        // Extra vertical padding in iPhone landscape so the card does not look flat.
        if isCompactHeight { return 26 }
        return isCompact ? 16 : 32
    }

    private var textBlockMinHeight: CGFloat {
        // Text areas share a minimum height so both cards match; English or large type can still grow taller.

        if isCompactHeight { return 48 }
        return isCompact ? 58 : 74
    }

    private var cardCornerRadius: CGFloat {
        isCompact ? 24 : 28
    }

    private enum IconPresentation {
        case random
        case filtered
        case generic
    }

    private var iconPresentation: IconPresentation {
        switch icon {
        case "photo.stack":
            return .random
        case "photo.badge.plus.fill":
            return .filtered
        default:
            return .generic
        }
    }

    private var iconAccentColor: Color {
        switch iconPresentation {
        case .random:
            return Color(red: 0.31, green: 0.88, blue: 0.93)
        case .filtered:
            return Color(red: 0.32, green: 0.82, blue: 0.97)
        case .generic:
            return Color(red: 0.34, green: 0.84, blue: 0.94)
        }
    }

    private var iconSecondaryAccentColor: Color {
        switch iconPresentation {
        case .random:
            return Color(red: 0.25, green: 0.80, blue: 0.87)
        case .filtered:
            return Color(red: 0.23, green: 0.79, blue: 0.73)
        case .generic:
            return Color(red: 0.23, green: 0.79, blue: 0.73)
        }
    }

    private var titleColor: Color {
        colorScheme == .dark ? .white : Color.black.opacity(0.90)
    }

    private var descriptionColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.62)
        }
        return Color(red: 0.34, green: 0.42, blue: 0.50)
    }

    private var artworkBackgroundGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.white.opacity(0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                Color.white.opacity(0.98),
                Color(red: 0.91, green: 0.95, blue: 0.995)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var artworkBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.05)
    }

    private var artworkGlowColor: Color {
        colorScheme == .dark
            ? iconAccentColor.opacity(0.16)
            : iconAccentColor.opacity(0.10)
    }

    private var selectionBadgeColor: Color {
        colorScheme == .dark
            ? Color(red: 0.60, green: 0.98, blue: 0.85)
            : Color(red: 0.02, green: 0.67, blue: 0.57)
    }

    private var artworkCornerRadius: CGFloat {
        isCompact ? 20 : 24
    }

    private var iconPlateCornerRadius: CGFloat {
        isCompact ? 20 : 28
    }

    private var iconGradient: LinearGradient {
        LinearGradient(
            colors: [iconAccentColor, iconSecondaryAccentColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {

        VStack(spacing: isCompactHeight ? 10 : (isCompact ? 12 : 18)) {
            artworkSection
            textSection
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.vertical, contentVerticalPadding)
        // Fill the parent height before drawing the surface so the backgrounds are truly equal in height.

        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .appIOSOnboardingSurface(
            cornerRadius: cardCornerRadius,
            accent: isSelected ? iconAccentColor : nil
        )
        .overlay(alignment: .topTrailing) {
            selectionBadge
        }
    }

    private var textSection: some View {
        VStack(spacing: isCompactHeight ? 4 : 8) {
            Text(LocalizedStringKey(title))
                .font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.center)
                .lineLimit(isCompactHeight ? 2 : 1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 4)

            Text(LocalizedStringKey(description))
                .font(.system(size: descriptionSize, weight: .light))
                .foregroundStyle(descriptionColor)
                .multilineTextAlignment(.center)
                .lineLimit(isCompactHeight ? 2 : (isCompact ? 2 : 3))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: textBlockMinHeight, alignment: .top)
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isSelected {
            // The checkmark only means selected, not focused.
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: isCompactHeight ? 20 : (isCompact ? 22 : 28), weight: .heavy))
                .foregroundStyle(selectionBadgeColor)
                .padding(isCompactHeight ? 9 : (isCompact ? 12 : 18))
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var artworkSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous)
                .fill(artworkBackgroundGradient)
                .overlay {
                    RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous)
                        .stroke(artworkBorderColor, lineWidth: 1)
                }

            Circle()
                .fill(artworkGlowColor)
                .frame(width: iconSize * 2.0, height: iconSize * 2.0)
                .blur(radius: isCompact ? 16 : 24)

            RoundedRectangle(cornerRadius: iconPlateCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            colorScheme == .dark
                                ? Color.white.opacity(0.10)
                                : Color.white.opacity(0.82),
                            colorScheme == .dark
                                ? Color.white.opacity(0.03)
                                : Color(red: 0.90, green: 0.95, blue: 0.995)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: iconSize * 1.65, height: iconSize * 1.65)
                .overlay {
                    RoundedRectangle(cornerRadius: iconPlateCornerRadius, style: .continuous)
                        .stroke(artworkBorderColor, lineWidth: 1)
                }

            iconArtwork
        }
        .frame(maxWidth: .infinity)
        .frame(height: isCompactHeight ? 72 : (isCompact ? 120 : 176))
    }

    @ViewBuilder
    private var iconArtwork: some View {
        switch iconPresentation {
        case .random:
            randomIconArtwork
        case .filtered:
            filteredIconArtwork
        case .generic:
            genericIconArtwork
        }
    }

    private var randomIconArtwork: some View {
        Image(systemName: "photo.stack")
            .font(.system(size: iconSize))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconGradient)
    }

    private var filteredIconArtwork: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "photo")
                .font(.system(size: iconSize * 0.9, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconAccentColor)

            Circle()
                .fill(iconGradient)
                .frame(width: iconSize * 0.42, height: iconSize * 0.42)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: iconSize * 0.18, weight: .bold))
                        .foregroundStyle(colorScheme == .dark ? Color.black.opacity(0.72) : .white)
                }
                .offset(x: iconSize * 0.06, y: iconSize * 0.03)
        }
    }

    private var genericIconArtwork: some View {
        Image(systemName: icon)
            .font(.system(size: iconSize))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconGradient)
    }
}
