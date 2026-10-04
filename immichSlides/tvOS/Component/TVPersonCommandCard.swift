import SwiftUI
import SDWebImageSwiftUI
import SDWebImage

struct TVPersonCommandCard: View {
    let personName: String
    let personCoverURL: URL?
    let personAssetsCount: Int?
    let isSelected: Bool
    let isSoloOnly: Bool
    let isFocused: Bool
    let isLightAppearance: Bool
    let playPauseHintText: String
    let playPauseHintAccent: Color

    private let requestContext: [SDWebImageContextOption: Any] = {
        if let modifier = ImmichRequestModifier.create() {
            return [.downloadRequestModifier: modifier]
        }
        return [:]
    }()

    private enum Layout {
        static let cornerRadius: CGFloat = 30
        static let badgeHorizontalInset: CGFloat = 12
        static let badgeVerticalInset: CGFloat = 7
        static let topBadgeInset: CGFloat = 16
        static let selectionOutlineWidth: CGFloat = 2
        static let focusedOutlineWidth: CGFloat = 4
        static let focusedScale: CGFloat = 1.04
        static let selectionMarkSize: CGFloat = 28
        static let selectionMarkInset: CGFloat = 16
        static let placeholderIconSize: CGFloat = 84
        static let infoPanelHorizontalInset: CGFloat = 20
        static let infoPanelCollapsedTopInset: CGFloat = 14
        static let infoPanelExpandedTopInset: CGFloat = 18
        static let infoPanelBottomInset: CGFloat = 18
        static let infoPanelTextSpacing: CGFloat = 4
        static let infoPanelExpandedSpacing: CGFloat = 12
        static let titleSize: CGFloat = 22
        static let subtitleSize: CGFloat = 15
        static let commandTrayHorizontalInset: CGFloat = 14
        static let commandTrayVerticalInset: CGFloat = 12
        static let commandTrayCornerRadius: CGFloat = 18
        static let commandIconSize: CGFloat = 34
        static let commandTitleSize: CGFloat = 14
        static let commandDetailSize: CGFloat = 17
    }

    // Light mode doesn't just switch the whole card to a white background; the base,
    // stroke, panel, and hint bar have separate colors, and the appearance is passed in
    // by the parent so the focus container doesn't read the wrong local environment.

    private var cardSurfaceColor: Color {
        if isLightAppearance {
            return Color(red: 0.97, green: 0.98, blue: 1.00)
        }
        return Color(red: 0.18, green: 0.18, blue: 0.20)
    }

    private var focusOutlineColor: Color {
        if isLightAppearance {
            return Color.black.opacity(0.26)
        }
        return Color.white.opacity(0.94)
    }

    private var cardShadowColor: Color {
        if isLightAppearance {
            return Color.black.opacity(isFocused ? 0.14 : 0.08)
        }
        return Color.black.opacity(isFocused ? 0.34 : 0.16)
    }

    private var artworkScrimColors: [Color] {
        if isLightAppearance {
            return [
                .clear,
                Color.black.opacity(isFocused ? 0.08 : 0.04),
                Color.black.opacity(isFocused ? 0.18 : 0.10)
            ]
        }

        return [
            .clear,
            Color.black.opacity(isFocused ? 0.16 : 0.08),
            Color.black.opacity(isFocused ? 0.46 : 0.30)
        ]
    }

    private var primaryTextColor: Color {
        if isLightAppearance {
            return Color(red: 0.12, green: 0.14, blue: 0.18)
        }
        return .white
    }

    private var secondaryTextColor: Color {
        if isLightAppearance {
            return Color.black.opacity(0.62)
        }
        return Color.white.opacity(0.76)
    }

    private var neutralBorderColor: Color {
        if isLightAppearance {
            return Color.black.opacity(0.10)
        }
        return Color.white.opacity(0.12)
    }

    private var selectionIndicatorColor: Color {
        if isSelected {
            return selectionAccentColor
        }
        if isLightAppearance {
            // In light mode, the unselected hollow circle is white so it stands
            // out on dark hair; the selected green/orange stays unchanged.

            return Color.white
        }
        return Color.white.opacity(0.95)
    }

    private var selectionIndicatorShadowColor: Color {
        if isLightAppearance {
            return Color.black.opacity(0.14)
        }
        return Color.black.opacity(0.28)
    }

    private var infoPanelBaseColor: Color {
        if isLightAppearance {
            return Color.white.opacity(isFocused ? 0.88 : 0.78)
        }
        return Color.black.opacity(isFocused ? 0.54 : 0.42)
    }

    private var infoPanelWashColor: Color {
        if isSelected {
            return selectionAccentColor.opacity(isLightAppearance ? 0.12 : 0.16)
        }

        if isLightAppearance {
            return Color.black.opacity(0.03)
        }
        return Color.white.opacity(0.04)
    }

    private var infoPanelSeparatorColor: Color {
        if isLightAppearance {
            return Color.black.opacity(isFocused ? 0.10 : 0.06)
        }
        return Color.white.opacity(isFocused ? 0.12 : 0.06)
    }

    private var commandTrayBackgroundColor: Color {
        if isLightAppearance {
            return Color.white.opacity(0.74)
        }
        return Color.black.opacity(0.22)
    }

    private var commandTrayTextColor: Color {
        if isLightAppearance {
            return Color.black.opacity(0.86)
        }
        return Color.white.opacity(0.96)
    }

    private var commandTrayShadowColor: Color {
        if isLightAppearance {
            return Color.black.opacity(0.10)
        }
        return Color.black.opacity(0.18)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            coverLayer

            HStack(alignment: .top) {
                if isSelected {
                    stateBadge
                }

                Spacer(minLength: 0)

                selectionIndicator
            }
            .padding(.horizontal, Layout.topBadgeInset)
            .padding(.top, Layout.topBadgeInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                .fill(cardSurfaceColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                .stroke(stateBorderColor, lineWidth: isSelected ? Layout.selectionOutlineWidth : 1)
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                    .stroke(focusOutlineColor, lineWidth: Layout.focusedOutlineWidth)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous))
        .shadow(
            color: cardShadowColor,
            radius: isFocused ? 22 : 12,
            x: 0,
            y: 12
        )
        .scaleEffect(isFocused ? Layout.focusedScale : 1.0)
        .animation(.easeInOut(duration: 0.18), value: isFocused)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: isSelected)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: isSoloOnly)
    }

    @ViewBuilder
    private var coverLayer: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                artworkBackground(size: geometry.size)

                LinearGradient(
                    colors: artworkScrimColors,
                    startPoint: .top,
                    endPoint: .bottom
                )

                bottomInformationPanel
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    @ViewBuilder
    private func artworkBackground(size: CGSize) -> some View {
        if let personCoverURL {
            WebImage(url: personCoverURL, context: requestContext)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)

                Image(systemName: "person.fill")
                    .font(.system(size: Layout.placeholderIconSize, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var personAssetsDescription: String {
        if let personAssetsCount {
            return LocalizedText.format("%lld photos", Int64(personAssetsCount))
        }
        return String(localized: "Photo count unavailable")
    }

    private var selectionIndicator: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: Layout.selectionMarkSize, weight: .bold))
            .foregroundStyle(selectionIndicatorColor)
            .shadow(color: selectionIndicatorShadowColor, radius: 10, x: 0, y: 4)
    }

    private var stateBadge: some View {
        Text(LocalizedStringKey(isSoloOnly ? "Solo" : "Chosen"))
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(stateBadgeTextColor)
            .padding(.horizontal, Layout.badgeHorizontalInset)
            .padding(.vertical, Layout.badgeVerticalInset)
            .background(
                Capsule()
                    .fill(stateBadgeBackgroundColor)
            )
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
    }

    private var stateBadgeBackgroundColor: Color {
        selectionAccentColor.opacity(isSoloOnly ? 0.92 : 0.86)
    }

    private var stateBadgeTextColor: Color {
        return Color.black.opacity(0.88)
    }

    private var stateBorderColor: Color {
        if isSelected {
            return selectionAccentColor.opacity(isSoloOnly ? 0.86 : 0.82)
        }
        return neutralBorderColor
    }

    private var selectionAccentColor: Color {
        isSoloOnly ? Color.orange : Color.green
    }

    private var bottomInformationPanel: some View {
        // On focus, the bottom panel grows taller than the Play/Pause bar
        // and the name rises with it, with no separate floating layer.

        VStack(alignment: .leading, spacing: isFocused ? Layout.infoPanelExpandedSpacing : 0) {
            VStack(alignment: .leading, spacing: Layout.infoPanelTextSpacing) {
                Text(personName)
                    .foregroundStyle(primaryTextColor)
                    .font(.system(size: Layout.titleSize, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                Text(personAssetsDescription)
                    .foregroundStyle(secondaryTextColor)
                    .font(.system(size: Layout.subtitleSize, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            if isFocused {
                focusCommandTray
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Layout.infoPanelHorizontalInset)
        .padding(.top, isFocused ? Layout.infoPanelExpandedTopInset : Layout.infoPanelCollapsedTopInset)
        .padding(.bottom, Layout.infoPanelBottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(infoPanelBaseColor)

                Rectangle()
                    .fill(infoPanelWashColor)
            }
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(infoPanelSeparatorColor)
                .frame(height: 1)
        }
    }

    private var focusCommandTray: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(playPauseHintAccent.opacity(0.18))

                Image(systemName: "playpause.fill")
                    // The icon scales up with the text so the keycap isn't too small.

                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(playPauseHintAccent)
            }
            .frame(width: Layout.commandIconSize, height: Layout.commandIconSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("Play/Pause"))
                    .foregroundStyle(playPauseHintAccent.opacity(0.96))
                    // Key name font size is 14; the old value of 11 was too small at viewing distance.

                    .font(.system(size: Layout.commandTitleSize, weight: .bold, design: .rounded))

                Text(playPauseHintText)
                    // Action description font size is 17; long English text relies on minimumScaleFactor as a fallback.

                    .font(.system(size: Layout.commandDetailSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(commandTrayTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.commandTrayHorizontalInset)
        .padding(.vertical, Layout.commandTrayVerticalInset)
        .background(
            RoundedRectangle(cornerRadius: Layout.commandTrayCornerRadius, style: .continuous)
                .fill(commandTrayBackgroundColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Layout.commandTrayCornerRadius, style: .continuous)
                .stroke(playPauseHintAccent.opacity(0.34), lineWidth: 1.2)
        }
        .shadow(color: commandTrayShadowColor, radius: 10, x: 0, y: 6)
    }
}
