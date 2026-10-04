//
//  FilterSummaryViewIOS+SelectionCards.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI

enum FilterSummarySelectionCardKind {
    case album
    case people

    var title: String {
        switch self {
        case .album:
            return "Albums"
        case .people:
            return "People"
        }
    }

    var subtitle: String {
        switch self {
        case .album:
            return "Choose which albums to include."
        case .people:
            return "Choose which people to include."
        }
    }

    var iconName: String {
        switch self {
        case .album:
            return "photo.on.rectangle"
        case .people:
            return "person.2.fill"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .album:
            return "filterSummary.album.button"
        case .people:
            return "filterSummary.person.button"
        }
    }

    var selectedLabel: String {
        switch self {
        case .album:
            return "Selected albums"
        case .people:
            return "Selected people"
        }
    }

    var tint: Color {
        switch self {
        case .album:
            return Color(red: 0.31, green: 0.88, blue: 0.93)
        case .people:
            return Color(red: 1.00, green: 0.73, blue: 0.36)
        }
    }

    var secondaryTint: Color {
        switch self {
        case .album:
            return Color(red: 0.23, green: 0.79, blue: 0.73)
        case .people:
            return Color(red: 0.96, green: 0.63, blue: 0.28)
        }
    }

    var mediaStyle: SelectionStageMosaicViewIOS.Style {
        switch self {
        case .album:
            return .album
        case .people:
            return .people
        }
    }
}

// The entry card owns both its navigation destination and its inner layout.

struct FilterSummarySelectionCardViewIOS: View {
    @ObservedObject var viewModel: FilterViewModel
    let kind: FilterSummarySelectionCardKind
    let isPhone: Bool
    let isPhoneLandscape: Bool
    let isPhonePortrait: Bool
    let isCompact: Bool
    let isCompactHeight: Bool
    let isPad: Bool

    var accessibilityIdentifierOverride: String? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationLink {
            destinationView
        } label: {
            Group {
                if isPhone {
                    phoneSelectionCard
                } else {
                    selectionStageCard
                }
            }
        }
        .appButtonRole(.ghost)
        .accessibilityIdentifier(accessibilityIdentifierOverride ?? kind.accessibilityIdentifier)
    }

    @ViewBuilder
    private var destinationView: some View {
        switch kind {
        case .album:
            AlbumFilterView(viewModel: viewModel)
        case .people:
            PersonFilterView(viewModel: viewModel)
        }
    }

    private var coverURLs: [URL] {
        switch kind {
        case .album:
            return viewModel.albumCoverURLs
        case .people:
            return viewModel.peopleCoverURLs
        }
    }

    private var selectedCount: Int {
        switch kind {
        case .album:
            return viewModel.selectedAlbumCount
        case .people:
            return viewModel.selectedPersonCount
        }
    }

    private var assetCount: Int {
        switch kind {
        case .album:
            return viewModel.selectedAlbumAssetsCount
        case .people:
            return viewModel.selectedPersonAssetsCount
        }
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : Color.black.opacity(0.92)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.66) : Color(red: 0.34, green: 0.41, blue: 0.49)
    }

    private var tertiaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.52) : Color(red: 0.40, green: 0.48, blue: 0.56)
    }

    private var surfaceShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.28) : Color(red: 0.39, green: 0.49, blue: 0.59).opacity(0.14)
    }

    private var summaryTint: Color {
        Color(red: 0.29, green: 0.75, blue: 0.96)
    }

    private var selectionCardSurface: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.16, green: 0.17, blue: 0.20),
                        Color(red: 0.12, green: 0.14, blue: 0.17)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.98),
                    Color(red: 0.94, green: 0.97, blue: 0.995)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var selectionCardBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color(red: 0.72, green: 0.81, blue: 0.91).opacity(0.40)
    }

    private var selectionCardMediaHeight: CGFloat {
        if isPhoneLandscape { return 110 }
        if isPhonePortrait { return 180 }
        if isCompactHeight { return 188 }
        if isCompact { return 220 }
        return isPad ? 268 : 238
    }

    private var selectionCardBodyPadding: CGFloat {
        if isPhoneLandscape { return 14 }
        return isCompact ? 18 : 20
    }

    private var selectionCardCornerRadius: CGFloat {
        isCompact ? 24 : 28
    }

    private var selectionCardTitleSize: CGFloat {
        if isPhoneLandscape { return 18 }
        return isCompact ? 22 : 24
    }

    private var phoneSelectionPreviewWidth: CGFloat {
        isPhoneLandscape ? 56 : 74
    }

    private var phoneSelectionPreviewHeight: CGFloat {
        isPhoneLandscape ? 56 : 74
    }

    private var phoneSelectionCardPadding: CGFloat {
        isPhoneLandscape ? 16 : 12
    }

    private var phoneSelectionCardHighlight: Color {
        colorScheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.88)
    }

    private var phoneLandscapeCardCornerRadius: CGFloat {
        isPhoneLandscape ? 24 : 26
    }

    @ViewBuilder
    private var phoneSelectionCard: some View {
        if isPhoneLandscape {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    phoneSelectionPreview

                    VStack(alignment: .leading, spacing: 3) {
                        Text(LocalizedStringKey(kind.title))
                            .font(.system(size: 19, weight: .heavy))
                            .foregroundStyle(primaryTextColor)

                        Text(LocalizedStringKey(kind.subtitle))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    chevronBadge(size: 28, iconSize: 12)
                }

                HStack(spacing: 8) {
                    phoneSelectionInfoPill(
                        title: kind.selectedLabel,
                        value: "\(selectedCount)",
                        tint: kind.tint
                    )
                    phoneSelectionInfoPill(
                        title: "Photos",
                        value: "\(assetCount)",
                        tint: summaryTint
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(phoneSelectionCardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appIOSOnboardingSurface(
                cornerRadius: phoneLandscapeCardCornerRadius,
                accent: kind.tint
            )
        } else {
            HStack(spacing: 12) {
                phoneSelectionPreview

                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(kind.title))
                            .font(.system(size: 22, weight: .heavy))
                            .foregroundStyle(primaryTextColor)

                        Text(LocalizedStringKey(kind.subtitle))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        phoneSelectionInfoPill(
                            title: kind.selectedLabel,
                            value: "\(selectedCount)",
                            tint: kind.tint
                        )
                        phoneSelectionInfoPill(
                            title: "Photos",
                            value: "\(assetCount)",
                            tint: summaryTint
                        )
                    }
                }

                Spacer(minLength: 8)

                chevronBadge(size: 34, iconSize: 14)
            }
            .padding(phoneSelectionCardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appIOSOnboardingSurface(
                cornerRadius: 24,
                accent: kind.tint
            )
        }
    }

    private var phoneSelectionPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    kind.tint.opacity(colorScheme == .dark ? (isPhonePortrait ? 0.16 : 0.14) : 0.12)
                )

            Image(systemName: kind.iconName)
                .font(.system(size: isPhoneLandscape ? 22 : 24, weight: .semibold))
                .foregroundStyle(kind.tint)
        }
        .frame(width: phoneSelectionPreviewWidth, height: phoneSelectionPreviewHeight)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if isPhonePortrait == false {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.66), lineWidth: 1)
            }
        }
    }

    private var phoneSelectionCardBackground: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.20, blue: 0.23),
                        Color(red: 0.14, green: 0.16, blue: 0.19)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.98),
                    kind.tint.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var phoneSelectionCardBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color(red: 0.72, green: 0.81, blue: 0.91).opacity(0.38)
    }

    private func phoneSelectionInfoPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(primaryTextColor)

            Text(LocalizedStringKey(title))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.04 : 0.54))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(colorScheme == .dark ? 0.18 : 0.22), lineWidth: 1)
        }
    }

    private func chevronBadge(size: CGFloat, iconSize: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.70))

            Image(systemName: "chevron.right")
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(primaryTextColor.opacity(size > 30 ? 0.88 : 0.78))
        }
        .frame(width: size, height: size)
    }

    private var selectionStageCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            selectionStageMedia
                .frame(height: selectionCardMediaHeight)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [kind.tint, kind.secondaryTint],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )

                            Image(systemName: kind.iconName)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.black.opacity(0.62))
                        }
                        .frame(width: 40, height: 40)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(LocalizedStringKey(kind.title))
                                .font(.system(size: selectionCardTitleSize, weight: .bold))
                                .foregroundStyle(primaryTextColor)

                            Text(LocalizedStringKey(kind.subtitle))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(tertiaryTextColor)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(tertiaryTextColor)
                }
            }
            .padding(selectionCardBodyPadding)
        }

        .appIOSOnboardingSurface(
            cornerRadius: selectionCardCornerRadius,
            accent: kind.tint
        )
    }

    private var selectionStageMedia: some View {
        ZStack {
            if coverURLs.isEmpty {
                LinearGradient(
                    colors: [
                        kind.tint.opacity(colorScheme == .dark ? 0.32 : 0.26),
                        kind.secondaryTint.opacity(colorScheme == .dark ? 0.22 : 0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.24))
                    .frame(width: 110, height: 138)
                    .rotationEffect(.degrees(-6))
                    .offset(x: -54, y: 6)

                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.16 : 0.08))
                    .frame(width: 102, height: 126)
                    .rotationEffect(.degrees(6))
                    .offset(x: 64, y: -8)
            } else {
                SelectionStageMosaicViewIOS(urls: coverURLs, style: kind.mediaStyle)
            }

            LinearGradient(
                colors: [
                    Color.black.opacity(0.01),
                    Color.black.opacity(colorScheme == .dark ? 0.08 : 0.03)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}
