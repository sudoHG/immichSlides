//
//  ModeCardViewTV.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI

struct ModeCardViewTV: View {
    @Environment(\.colorScheme) private var colorScheme

    let icon: String
    let title: String
    let description: String
    let isSelected: Bool
    let isFocused: Bool

    private enum IconPresentation {
        case random
        case filtered
        case generic
    }

    private var iconSize: CGFloat { 104 }
    private var titleSize: CGFloat { 28 }
    private var descriptionSize: CGFloat { 18 }
    private var contentHorizontalPadding: CGFloat { 30 }
    private var contentVerticalPadding: CGFloat { 22 }
    private var cardCornerRadius: CGFloat { 30 }
    private var cardScale: CGFloat { isFocused ? 1.012 : 1.0 }
    private var cardShadowRadius: CGFloat { isFocused ? 18 : 10 }

    private var cardShadowOpacity: Double {
        if isFocused { return 0.24 }
        return colorScheme == .dark ? 0.26 : 0.12
    }

    private var cardBorderColor: Color {
        if isFocused {
            return colorScheme == .dark
                ? Color(red: 0.35, green: 0.84, blue: 0.97).opacity(0.92)
                : Color(red: 0.00, green: 0.59, blue: 0.84).opacity(0.98)
        }
        if isSelected {
            return colorScheme == .dark
                ? Color(red: 0.54, green: 0.95, blue: 0.82)
                : Color(red: 0.05, green: 0.67, blue: 0.54)
        }
        return PlatformCompat.separator.opacity(colorScheme == .dark ? 0.9 : 0.35)
    }

    private var ornamentGradient: LinearGradient {
        LinearGradient(
            colors: [iconAccentColor, iconSecondaryAccentColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var cardBorderWidth: CGFloat {
        if isFocused { return 2 }
        if isSelected { return 2 }
        return 1
    }

    private var cardSurfaceGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.16, blue: 0.19),
                    Color(red: 0.12, green: 0.12, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.96, blue: 0.98),
                Color(red: 0.90, green: 0.93, blue: 0.97)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var titleColor: Color {
        colorScheme == .dark ? .white : Color.black.opacity(0.88)
    }

    private var descriptionColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(isFocused ? 0.80 : 0.62)
        }
        return Color.black.opacity(isFocused ? 0.58 : 0.48)
    }

    private var iconPlateSize: CGFloat { 142 }
    private var iconPlateCornerRadius: CGFloat { 32 }
    private var artworkCornerRadius: CGFloat { 24 }
    private var artworkHeight: CGFloat { 218 }
    private var titleBottomSpacing: CGFloat { 8 }
    private var subtitleMaxWidth: CGFloat { 360 }

    private var artworkBackgroundGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.09),
                    Color.white.opacity(0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                Color.white.opacity(0.96),
                Color(red: 0.90, green: 0.94, blue: 0.99)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var artworkGlowColor: Color {
        if colorScheme == .dark {
            return iconAccentColor.opacity(isFocused ? 0.22 : 0.12)
        }
        return iconAccentColor.opacity(isFocused ? 0.10 : 0.05)
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
            return Color(red: 0.32, green: 0.91, blue: 0.92)
        case .filtered:
            return Color(red: 0.35, green: 0.84, blue: 0.97)
        case .generic:
            return Color(red: 0.38, green: 0.87, blue: 0.95)
        }
    }

    private var iconSecondaryAccentColor: Color {
        switch iconPresentation {
        case .random:
            return Color(red: 0.22, green: 0.79, blue: 0.89)
        case .filtered:
            return Color(red: 0.28, green: 0.82, blue: 0.76)
        case .generic:
            return Color(red: 0.28, green: 0.82, blue: 0.76)
        }
    }

    private var symbolAnimationOptions: SymbolEffectOptions {
        // The symbol animation loops at a low frequency to avoid constant jitter on TV.
        .repeat(.periodic(delay: 3.0)).speed(0.6)
    }

    var body: some View {
        // TV cards carry both content and focus feedback, so their layering is heavier than on iOS.
        VStack(spacing: 18) {
            artworkSection

            VStack(spacing: titleBottomSpacing) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: titleSize, weight: .bold))
                    .foregroundStyle(titleColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 6)

                Text(LocalizedStringKey(description))
                    .font(.system(size: descriptionSize, weight: .light))
                    .foregroundStyle(descriptionColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: subtitleMaxWidth)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.vertical, contentVerticalPadding)
        .background(cardSurfaceGradient)
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius)
                .stroke(cardBorderColor, lineWidth: cardBorderWidth)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(
                    colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.85),
                    lineWidth: 1
                )
                .padding(1)
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .stroke(
                        colorScheme == .dark
                            ? Color.cyan.opacity(0.24)
                            : Color(red: 0.00, green: 0.63, blue: 0.92).opacity(0.28),
                        lineWidth: 5
                    )
                    .blur(radius: 8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius))
        .overlay(alignment: .topTrailing) {
            selectionBadge
        }
        .cornerRadius(cardCornerRadius)
        .scaleEffect(cardScale)
        .shadow(
            color: colorScheme == .dark
                ? Color.black.opacity(cardShadowOpacity)
                : Color.black.opacity(isFocused ? 0.12 : 0.08),
            radius: cardShadowRadius,
            x: 0,
            y: 14
        )
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isSelected {
            // The checkmark means selected, not currently focused.
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32, weight: .heavy))
                .foregroundStyle(
                    colorScheme == .dark
                        ? Color(red: 0.60, green: 0.98, blue: 0.85)
                        : Color(red: 0.03, green: 0.68, blue: 0.55)
                )
                .padding(18)
                .transition(.scale.combined(with: .opacity))
        }
    }

    // The icon gets its own stage so it's recognizable from a distance.
    private var artworkSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous)
                .fill(artworkBackgroundGradient)
                .overlay {
                    RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous)
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.10)
                                : Color.black.opacity(0.05),
                            lineWidth: 1
                        )
                }

            Circle()
                .fill(artworkGlowColor)
                .frame(width: iconPlateSize * 1.18, height: iconPlateSize * 1.18)
                .blur(radius: isFocused ? 18 : 10)

            RoundedRectangle(cornerRadius: iconPlateCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            colorScheme == .dark
                                ? Color.white.opacity(0.10)
                                : Color.white.opacity(0.72),
                            colorScheme == .dark
                                ? Color.white.opacity(0.02)
                                : Color(red: 0.90, green: 0.94, blue: 0.99)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: iconPlateSize, height: iconPlateSize)
                .overlay {
                    RoundedRectangle(cornerRadius: iconPlateCornerRadius, style: .continuous)
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.08)
                                : Color.black.opacity(0.05),
                            lineWidth: 1
                        )
                }

            iconArtwork
        }
        .frame(maxWidth: .infinity)
        .frame(height: artworkHeight)
    }

    @ViewBuilder
    private var iconArtwork: some View {
        // Compose the icon per mode, so different SF Symbols don't lose a consistent visual hierarchy on TV.
        switch iconPresentation {
        case .random:
            animatedRandomIcon
        case .filtered:
            animatedFilteredIcon
        case .generic:
            animatedGenericIcon
        }
    }

    private var animatedRandomIcon: some View {
        Image(systemName: "photo.stack")
            .font(.system(size: iconSize))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(ornamentGradient)
            .symbolEffect(.bounce.up.byLayer, options: symbolAnimationOptions, isActive: true)
    }

    private var animatedFilteredIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "photo")
                .font(.system(size: iconSize * 0.88, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconAccentColor)
                .symbolEffect(.bounce.up.byLayer, options: symbolAnimationOptions, isActive: true)

            Circle()
                .fill(ornamentGradient)
                .frame(width: iconSize * 0.38, height: iconSize * 0.38)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: iconSize * 0.18, weight: .bold))
                        .foregroundStyle(colorScheme == .dark ? Color.black.opacity(0.72) : .white)
                        .symbolEffect(.bounce.up.wholeSymbol, options: symbolAnimationOptions, isActive: true)
                }
                .offset(x: iconSize * 0.06, y: iconSize * 0.03)
        }
    }

    private var animatedGenericIcon: some View {
        Image(systemName: icon)
            .font(.system(size: iconSize))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(ornamentGradient)
            .symbolEffect(.bounce.up.byLayer, options: symbolAnimationOptions, isActive: true)
    }
}
