import SwiftUI
import SDWebImageSwiftUI
import SDWebImage

struct FloatingSelectionCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String
    let summary: String
    let accent: Color
    let previewURLs: [URL]
    let isFocused: Bool

    private var primaryTextColor: Color {
        colorScheme == .light ? Color.black.opacity(0.86) : .white
    }

    private var secondaryTextColor: Color {
        colorScheme == .light ? Color.black.opacity(0.62) : Color.white.opacity(0.78)
    }

    private var cardBorderColor: Color {
        if isFocused {
            return accent.opacity(0.95)
        }
        return colorScheme == .light ? Color.black.opacity(0.08) : Color.white.opacity(0.08)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(primaryTextColor)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(accent)
            }

            previewStrip
                .frame(height: 94)

            Text(LocalizedStringKey(subtitle))

                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)

            Text(verbatim: summary)

                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(width: 424, height: 262, alignment: .topLeading)
        .modifier(TVGlassPanelModifier(cornerRadius: 30, tint: accent.opacity(0.18)))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(cardBorderColor, lineWidth: isFocused ? 2.2 : 1)
        }
        .shadow(color: accent.opacity(isFocused ? 0.12 : 0.0), radius: 18, x: 0, y: 10)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: isFocused)
    }

    private var previewStrip: some View {
        HStack(spacing: 10) {
            ForEach(Array(displayPreviewURLs.enumerated()), id: \.offset) { _, url in
                TVStageImage(url: url)
                    .frame(width: 100, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var displayPreviewURLs: [URL] {
        let photos = CoverMosaicLayout.distinct(previewURLs)
        return Array(photos.prefix(CoverMosaicLayout.stripPhotoCount(photoCount: photos.count)))
    }
}

struct AlbumPanoramaStage: View {
    @Environment(\.colorScheme) private var colorScheme

    let panoramaURLs: [URL]
    let spotlightURLs: [URL]
    let accent: Color
    let selectedSummary: String

    private var baseGradientColors: [Color] {
        if colorScheme == .light {
            return [
                Color(red: 0.89, green: 0.94, blue: 0.99),
                Color(red: 0.79, green: 0.88, blue: 0.97)
            ]
        }
        return [
            Color(red: 0.03, green: 0.06, blue: 0.11),
            Color(red: 0.04, green: 0.09, blue: 0.18)
        ]
    }

    private var radialGlowOpacity: Double {
        colorScheme == .light ? 0.18 : 0.26
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: baseGradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if stagePhotos.wall.isEmpty {
                    AlbumStageFallback(accent: accent, selectedSummary: selectedSummary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    AlbumPanoramaMosaic(
                        urls: stagePhotos.wall,
                        spotlightURLs: stagePhotos.spotlights,
                        size: geometry.size
                    )
                }

                RadialGradient(
                    colors: [
                        accent.opacity(radialGlowOpacity),
                        accent.opacity(0.0)
                    ],
                    center: .center,
                    startRadius: 40,
                    endRadius: 520
                )
            }
        }
    }

    private var stagePhotos: CoverMosaicLayout.StagePhotos {
        CoverMosaicLayout.stagePhotos(
            wall: panoramaURLs,
            spotlights: spotlightURLs.isEmpty ? Array(panoramaURLs.prefix(4)) : spotlightURLs,
            wallCapacity: CoverMosaicLayout.albumWallCapacity,
            spotlightCapacity: CoverMosaicLayout.albumSpotlightCapacity
        )
    }
}

struct PeopleConstellationStage: View {
    @Environment(\.colorScheme) private var colorScheme

    let wallURLs: [URL]
    let spotlightURLs: [URL]
    let accent: Color
    let selectedSummary: String

    private var baseGradientColors: [Color] {
        if colorScheme == .light {
            return [
                Color(red: 0.99, green: 0.95, blue: 0.91),
                Color(red: 0.97, green: 0.90, blue: 0.84),
                Color(red: 0.95, green: 0.88, blue: 0.82)
            ]
        }
        return [
            Color(red: 0.11, green: 0.06, blue: 0.03),
            Color(red: 0.15, green: 0.08, blue: 0.08),
            Color(red: 0.07, green: 0.04, blue: 0.02)
        ]
    }

    private var radialGlowOpacity: Double {
        colorScheme == .light ? 0.20 : 0.30
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: baseGradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if stagePhotos.wall.isEmpty {
                    PeopleStageFallback(accent: accent, selectedSummary: selectedSummary)
                } else {
                    PeopleConstellationMosaic(
                        wallURLs: stagePhotos.wall,
                        spotlightURLs: stagePhotos.spotlights,
                        size: geometry.size
                    )
                }

                RadialGradient(
                    colors: [
                        accent.opacity(radialGlowOpacity),
                        accent.opacity(0.0)
                    ],
                    center: .center,
                    startRadius: 30,
                    endRadius: 440
                )
                .blendMode(.screen)
            }
        }
    }

    private var stagePhotos: CoverMosaicLayout.StagePhotos {
        CoverMosaicLayout.stagePhotos(
            wall: wallURLs.isEmpty ? displaySpotlights : wallURLs,
            spotlights: displaySpotlights,
            wallCapacity: CoverMosaicLayout.peopleWallCapacity,
            spotlightCapacity: CoverMosaicLayout.peopleSpotlightCapacity
        )
    }

    private var displaySpotlights: [URL] {
        if spotlightURLs.isEmpty == false {
            return Array(spotlightURLs.prefix(6))
        }
        return Array(wallURLs.prefix(6))
    }

}

private struct AlbumPanoramaMosaic: View {
    let urls: [URL]
    let spotlightURLs: [URL]
    let size: CGSize

    var body: some View {
        let plan = CoverMosaicLayout.albumWallPlan(photoCount: urls.count)
        let spotlightScale = CoverMosaicLayout.spotlightScale(
            photoCount: spotlightURLs.count, capacity: CoverMosaicLayout.albumSpotlightCapacity)

        ZStack {
            HStack(spacing: 22) {
                ForEach(0..<plan.topCount, id: \.self) { index in
                    TVStageImage(url: urls[index])
                        .frame(
                            width: size.width * 0.16 * plan.tileScale, height: size.height * 0.2 * plan.tileScale
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .rotationEffect(.degrees(-4))
                        .opacity(0.78)
                }
            }
            .offset(x: size.width * 0.0, y: -size.height * 0.25)

            HStack(spacing: 26) {
                ForEach(plan.topCount..<(plan.topCount + plan.bottomCount), id: \.self) { index in
                    TVStageImage(url: urls[index])
                        .frame(
                            width: size.width * 0.18 * plan.tileScale, height: size.height * 0.28 * plan.tileScale
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                        .rotationEffect(.degrees(7))
                        .opacity(0.64)
                }
            }
            .offset(x: size.width * 0.02, y: size.height * 0.14)

            VStack(spacing: 18) {
                ForEach(0..<spotlightURLs.count, id: \.self) { index in
                    TVStageImage(url: spotlightURLs[index])
                        .frame(
                            width: size.width * (index == 0 ? 0.24 : 0.18) * spotlightScale,
                            height: size.height * (index == 0 ? 0.28 : 0.19) * spotlightScale
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .rotationEffect(.degrees(index == 1 ? 6 : -6))
                        .shadow(color: Color.black.opacity(0.24), radius: 22, x: 0, y: 14)
                }
            }
            .offset(x: size.width * 0.1, y: -size.height * 0.03)
        }
    }
}

private struct PeopleConstellationMosaic: View {
    let wallURLs: [URL]
    let spotlightURLs: [URL]
    let size: CGSize

    var body: some View {
        let plan = CoverMosaicLayout.peopleWallPlan(photoCount: wallURLs.count)
        let spotlightScale = CoverMosaicLayout.spotlightScale(
            photoCount: spotlightURLs.count, capacity: CoverMosaicLayout.peopleSpotlightCapacity)
        let tileSide = size.width * 0.11 * plan.tileScale
        let emphasizedRow = plan.rowCounts.count / 2

        ZStack {
            VStack(spacing: 16) {
                ForEach(0..<plan.rowCounts.count, id: \.self) { row in
                    let firstIndex = plan.rowCounts[..<row].reduce(0, +)
                    HStack(spacing: 16) {
                        ForEach(0..<plan.rowCounts[row], id: \.self) { column in
                            TVStageImage(url: wallURLs[firstIndex + column])
                                .frame(width: tileSide, height: tileSide)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: size.width * 0.04 * plan.tileScale, style: .continuous)
                                )
                                .opacity(row == emphasizedRow ? 0.92 : 0.74)
                        }
                    }
                }
            }
            .offset(x: size.width * 0.04, y: -size.height * 0.06)

            HStack(spacing: 18) {
                ForEach(Array(spotlightURLs.enumerated()), id: \.offset) { index, url in
                    TVStageImage(url: url)
                        .frame(width: size.width * 0.16 * spotlightScale, height: size.height * 0.2 * spotlightScale)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .rotationEffect(.degrees(index == 1 ? 5 : -7))
                        .shadow(color: Color.black.opacity(0.24), radius: 18, x: 0, y: 12)
                }
            }
            .offset(x: size.width * 0.02, y: size.height * 0.24)
        }
    }
}

private struct AlbumStageFallback: View {
    let accent: Color
    let selectedSummary: String

    var body: some View {
        ZStack {
            FilmstripPlaceholderGrid(accent: accent)

            LinearGradient(
                colors: [
                    accent.opacity(0.12),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(selectedSummary)
    }
}

private struct PeopleStageFallback: View {
    let accent: Color
    let selectedSummary: String

    var body: some View {
        ZStack {
            ConstellationPlaceholderField(accent: accent)

            RadialGradient(
                colors: [
                    accent.opacity(0.16),
                    Color.clear
                ],
                center: .center,
                startRadius: 40,
                endRadius: 420
            )
        }
        .accessibilityLabel(selectedSummary)
    }
}

private struct FilmstripPlaceholderGrid: View {
    @Environment(\.colorScheme) private var colorScheme

    let accent: Color

    private func placeholderBaseOpacity(for index: Int) -> Double {
        if colorScheme == .light {
            return 0.04 + Double(index % 3) * 0.015
        }
        return 0.05 + Double(index % 3) * 0.02
    }

    private var placeholderStrokeColor: Color {
        colorScheme == .light ? Color.black.opacity(0.08) : Color.white.opacity(0.08)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(0..<18, id: \.self) { index in
                    let row = index / 6
                    let column = index % 6
                    let cardWidth = geometry.size.width * (row == 1 ? 0.19 : 0.15)
                    let cardHeight = geometry.size.height * (row == 1 ? 0.25 : 0.18)
                    let x = CGFloat(column) * geometry.size.width * 0.17 + geometry.size.width * 0.12
                    let y = CGFloat(row) * geometry.size.height * 0.24 + geometry.size.height * 0.2

                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    (colorScheme == .light ? Color.black : Color.white)
                                        .opacity(placeholderBaseOpacity(for: index)),
                                    accent.opacity(0.08 + Double(index % 2) * 0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: cardWidth, height: cardHeight)
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(placeholderStrokeColor, lineWidth: 1)
                        }
                        .position(x: x, y: y)
                        .rotationEffect(.degrees(row == 1 ? -8 : -4))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ConstellationPlaceholderField: View {
    @Environment(\.colorScheme) private var colorScheme

    let accent: Color

    private var neutralBubbleColor: Color {
        colorScheme == .light ? Color.black.opacity(0.07) : Color.white.opacity(0.08)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(0..<28, id: \.self) { index in
                    Circle()
                        .fill(index.isMultiple(of: 4) ? accent.opacity(0.18) : neutralBubbleColor)
                        .frame(width: CGFloat(40 + (index % 5) * 18), height: CGFloat(40 + (index % 5) * 18))
                        .offset(
                            x: CGFloat((index % 7) - 3) * geometry.size.width * 0.1,
                            y: CGFloat((index / 7) - 2) * geometry.size.height * 0.14
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TVStageImage: View {
    @Environment(\.colorScheme) private var colorScheme

    let url: URL

    private var requestContext: [SDWebImageContextOption: Any] {
        if let modifier = ImmichRequestModifier.create() {
            return [.downloadRequestModifier: modifier]
        }
        return [:]
    }

    var body: some View {
        WebImage(url: url, context: requestContext)
            .onSuccess { image, _, cacheType in
                #if DEBUG
                AssetsDownloadManager.shared.recordPrePlaybackFilterSummaryTransitionWriterForDiagnostics(
                    url: url,
                    context: requestContext,
                    cacheType: cacheType
                )
                #endif
            }
            .resizable()
            .indicator(.activity)
            .aspectRatio(contentMode: .fill)
            .transition(.fade(duration: 0.25))
            .background(
                LinearGradient(
                    colors: [
                        (colorScheme == .light ? Color.black : Color.white).opacity(
                            colorScheme == .light ? 0.04 : 0.08),
                        (colorScheme == .light ? Color.black : Color.white).opacity(colorScheme == .light ? 0.01 : 0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipped()
    }
}
