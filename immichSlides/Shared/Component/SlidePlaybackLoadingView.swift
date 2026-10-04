#if os(iOS) || os(tvOS)
//
//  SlidePlaybackLoadingView.swift
//  immichSlides
//

import SwiftUI

enum SlidePlaybackLoadingViewStyle {
    case fullscreen
    // overMedia is only for compatibility and Previews; the production playback wait state must use fullscreen.
    case overMedia
    case slot
    case inline
}

private enum SlidePlaybackLoadingMetrics {
    static let contentSpacingPoints: CGFloat = 12
    static let maximumWidthPoints: CGFloat = 280
}

struct SlidePlaybackLoadingView: View {
    @Environment(\.colorScheme) private var colorScheme

    let message: String
    let accessibilityIdentifier: String
    let style: SlidePlaybackLoadingViewStyle

    init(
        message: String = String(localized: "Loading..."),
        style: SlidePlaybackLoadingViewStyle = .fullscreen,
        accessibilityIdentifier: String = "playback.loading.indicator"
    ) {
        self.message = message
        self.style = style
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        Group {
            switch style {
            case .fullscreen:
                fullscreenLoading
            case .overMedia:
                overMediaLoading
            case .slot:
                slotLoading
            case .inline:
                inlineLoading
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringKey(message)))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var fullscreenLoading: some View {
        VStack(spacing: SlidePlaybackLoadingMetrics.contentSpacingPoints) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.regular)
                .tint(loadingSpinnerColor)

            // The fullscreen wait state only means playback is starting; do not turn it into a tappable button.
            Text(LocalizedStringKey(message))
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(loadingForegroundColor)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: SlidePlaybackLoadingMetrics.maximumWidthPoints)
    }

    private var overMediaLoading: some View {
        VStack(spacing: SlidePlaybackLoadingMetrics.contentSpacingPoints) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.regular)
                .tint(loadingSpinnerColor)

            Text(LocalizedStringKey(message))
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(loadingForegroundColor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .frame(maxWidth: SlidePlaybackLoadingMetrics.maximumWidthPoints)
        .background(loadingSurfaceColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(loadingBorderColor, lineWidth: 1)
        )
    }

    private var slotLoading: some View {
        ZStack {
            loadingSurfaceColor
                .overlay(
                    Rectangle()
                        .stroke(loadingBorderColor, lineWidth: 1)
                )

            VStack(spacing: 6) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(loadingSpinnerColor)

                Text(LocalizedStringKey(message))
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(loadingForegroundColor)
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inlineLoading: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(loadingSpinnerColor)

            Text(LocalizedStringKey(message))
                .font(inlineTextFont)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .multilineTextAlignment(.leading)
                .foregroundStyle(loadingForegroundColor)
        }
    }

    private var inlineTextFont: Font {
        #if os(tvOS)
        .system(size: 24, weight: .medium)
        #else
        .footnote
        #endif
    }

    private var loadingForegroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.86) : Color.black.opacity(0.74)
    }

    private var loadingSpinnerColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.90) : Color.black.opacity(0.62)
    }

    private var loadingSurfaceColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.26) : Color.white.opacity(0.72)
    }

    private var loadingBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }
}

#Preview {
    ZStack {
        Color.black
        VStack(spacing: 40) {
            SlidePlaybackLoadingView()
            SlidePlaybackLoadingView(message: "Loading media...", style: .overMedia)
            SlidePlaybackLoadingView(style: .slot)
                .frame(width: 180, height: 120)
                .border(.white.opacity(0.18))
            SlidePlaybackLoadingView(message: "Testing connection...", style: .inline)
        }
    }
}
#endif
