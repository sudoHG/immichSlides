//
//  FilterSummaryViewIOS+Actions.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI

// Filter summary bottom bar: buttons and stats; the main page decides where it goes.

struct FilterSummaryActionBarViewIOS: View {
    @ObservedObject var viewModel: FilterViewModel
    let canStartPlayback: Bool
    let onStartPlayback: () -> Void
    let isPhone: Bool
    let isCompact: Bool
    let isPhoneLandscape: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if isPhone {
                phoneCompactButtonsSection
            } else if isCompact {
                VStack(alignment: .leading, spacing: 16) {
                    actionSummaryPanel

                    VStack(alignment: .leading, spacing: 12) {
                        startPlaybackButton
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 28) {
                    actionSummaryPanel
                        .frame(maxWidth: .infinity, alignment: .leading)

                    buttonCluster
                }
            }
        }
        .padding(.horizontal, actionPanelHorizontalPadding)
        .padding(.vertical, actionPanelVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(
            OptionalOnboardingSurfaceModifier(
                isEnabled: !isPhone,
                cornerRadius: 24,
                accent: summaryTint
            )
        )
    }

    // The iPhone bottom bar keeps only Start Playback.
    private var phoneCompactButtonsSection: some View {
        startPlaybackButton
            .frame(width: phoneSingleButtonWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // On iPad and other non-iPhone devices, the bottom bar shows filter stats.
    private var actionSummaryPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Filter Summary")
                    .font(.system(size: isCompact ? 15 : 16, weight: .heavy))
                    .foregroundStyle(primaryTextColor)
            }

            if isCompact {
                VStack(spacing: 8) {
                    actionMetricRow
                }
            } else {
                actionMetricRow
            }
        }
    }

    private var startPlaybackButton: some View {
        Button {
            onStartPlayback()
        } label: {
            if isPhone {
                phoneActionButtonLabel(
                    systemName: "play.fill",
                    title: "Start Playback",
                    subtitle: "",
                    foreground: .white,
                    background: canStartPlayback
                        ? AnyShapeStyle(startButtonGradient)
                        : AnyShapeStyle(phoneDisabledButtonFill)
                )
            } else {
                actionButtonLabel(
                    systemName: "play.fill",
                    title: "Start Playback",
                    foreground: .white,
                    background: AnyShapeStyle(startButtonGradient)
                )
            }
        }
        .buttonStyle(.plain)
        .disabled(!canStartPlayback)
        .accessibilityIdentifier("filterSummary.startPlayback.button")
    }

    private func actionButtonLabel(
        systemName: String,
        title: String,
        foreground: Color,
        background: AnyShapeStyle
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 16, alignment: .center)

            Text(LocalizedStringKey(title))
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .frame(width: actionButtonWidth, alignment: .center)
        .padding(.horizontal, 20)
        .frame(minHeight: 50)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func phoneActionButtonLabel(
        systemName: String,
        title: String,
        subtitle: String,
        foreground: Color,
        background: AnyShapeStyle
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(foreground.opacity(0.92))

            VStack(alignment: .center, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(foreground)
                if subtitle.isEmpty == false {
                    Text(LocalizedStringKey(subtitle))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(foreground.opacity(0.72))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var actionMetricRow: some View {
        Group {
            if isPhoneLandscape {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        actionMetricTile(
                            value: "\(viewModel.selectedAlbumCount)", label: "Selected albums", accent: albumTint)
                        actionMetricTile(
                            value: "\(viewModel.selectedPersonCount)", label: "Selected people", accent: peopleTint)
                    }

                    actionMetricTile(value: "\(totalSelectedAssetCount)", label: "Photos", accent: summaryTint)
                }
            } else {
                HStack(spacing: 12) {
                    actionMetricTile(
                        value: "\(viewModel.selectedAlbumCount)", label: "Selected albums", accent: albumTint)
                    actionMetricTile(
                        value: "\(viewModel.selectedPersonCount)", label: "Selected people", accent: peopleTint)
                    actionMetricTile(value: "\(totalSelectedAssetCount)", label: "Photos", accent: summaryTint)
                }
            }
        }
    }

    private func actionMetricTile(value: String, label: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: isCompact ? 17 : 19, weight: .heavy))
                .foregroundStyle(primaryTextColor)

            Text(LocalizedStringKey(label))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
        }
        .frame(width: actionMetricTileWidth, alignment: .leading)
        .padding(.horizontal, isCompact ? 10 : 11)
        .padding(.vertical, isCompact ? 9 : 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accent.opacity(colorScheme == .dark ? 0.14 : 0.10))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent.opacity(colorScheme == .dark ? 0.18 : 0.14), lineWidth: 1)
        }
    }

    private var buttonCluster: some View {
        VStack(alignment: .trailing, spacing: 12) {
            startPlaybackButton
        }
        .frame(minWidth: actionButtonWidth + 16, alignment: .trailing)
    }

    private var totalSelectedAssetCount: Int {
        viewModel.selectedAlbumAssetsCount + viewModel.selectedPersonAssetsCount
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : Color.black.opacity(0.92)
    }

    private var albumTint: Color {
        Color(red: 0.31, green: 0.88, blue: 0.93)
    }

    private var albumTintSecondary: Color {
        Color(red: 0.23, green: 0.79, blue: 0.73)
    }

    private var peopleTint: Color {
        Color(red: 1.00, green: 0.73, blue: 0.36)
    }

    private var summaryTint: Color {
        Color(red: 0.29, green: 0.75, blue: 0.96)
    }

    private var startButtonGradient: some ShapeStyle {
        AnyShapeStyle(
            LinearGradient(
                colors: [summaryTint, albumTintSecondary],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private var phoneDisabledButtonFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color(red: 0.79, green: 0.87, blue: 0.93)
    }

    private var actionButtonWidth: CGFloat {
        isCompact ? 176 : 188
    }

    private var actionMetricTileWidth: CGFloat {
        isCompact ? 94 : 104
    }

    private var phoneSingleButtonWidth: CGFloat {
        isPhoneLandscape ? 188 : 140
    }

    private var actionPanelHorizontalPadding: CGFloat {
        if isPhoneLandscape { return 0 }
        if isPhone { return 16 }
        return isCompact ? 18 : 22
    }

    private var actionPanelVerticalPadding: CGFloat {
        if isPhoneLandscape { return 0 }
        if isPhone { return 16 }
        return isCompact ? 18 : 20
    }
}

private struct OptionalOnboardingSurfaceModifier: ViewModifier {
    let isEnabled: Bool
    let cornerRadius: CGFloat
    let accent: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.appIOSOnboardingSurface(cornerRadius: cornerRadius, accent: accent)
        } else {
            content
        }
    }
}
