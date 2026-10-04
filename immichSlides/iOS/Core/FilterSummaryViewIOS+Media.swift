//
//  FilterSummaryViewIOS+Media.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI
import SDWebImageSwiftUI
import SDWebImage

struct IOSSelectionStageMosaic: View {
    enum Style {
        case album
        case people
    }

    let urls: [URL]
    let style: Style
    let colorScheme: ColorScheme

    var body: some View {
        GeometryReader { geometry in
            let displayURLs = repeated(urls: urls, minimumCount: 7)

            ZStack {
                RoundedRectangle(cornerRadius: 0, style: .continuous)
                    .fill(Color.black.opacity(style == .people ? 0.12 : 0.08))

                if style == .album {
                    albumLayout(size: geometry.size, urls: displayURLs)
                } else {
                    peopleLayout(size: geometry.size, urls: displayURLs)
                }
            }
            .clipped()
        }
    }

    private func albumLayout(size: CGSize, urls: [URL]) -> some View {
        let displayURLs = repeated(urls: urls, minimumCount: 4)
        let gap: CGFloat = 6
        let inset: CGFloat = 8
        let availableWidth = size.width - inset * 2
        let availableHeight = size.height - inset * 2
        let largeWidth = availableWidth * 0.60
        let trailingWidth = availableWidth - largeWidth - gap
        let topHeight = availableHeight * 0.63
        let bottomHeight = availableHeight - topHeight - gap

        return HStack(alignment: .top, spacing: gap) {
            albumTile(url: displayURLs[0], width: largeWidth, height: availableHeight, prominence: .primary)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(spacing: gap) {
                albumTile(url: displayURLs[1], width: trailingWidth, height: topHeight, prominence: .secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack(spacing: gap) {
                    albumTile(
                        url: displayURLs[2], width: (trailingWidth - gap) / 2, height: bottomHeight,
                        prominence: .tertiary
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    albumTile(
                        url: displayURLs[3], width: (trailingWidth - gap) / 2, height: bottomHeight,
                        prominence: .tertiary
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .frame(width: trailingWidth, height: availableHeight, alignment: .topLeading)
        }
        .padding(inset)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func albumTile(url: URL, width: CGFloat, height: CGFloat, prominence: AlbumTileProminence) -> some View {
        IOSGridStageImage(url: url, prominence: prominence)
            .frame(width: width, height: height)
    }

    private func peopleLayout(size: CGSize, urls: [URL]) -> some View {
        let displayURLs = repeated(urls: urls, minimumCount: 4)
        let gap: CGFloat = 6
        let inset: CGFloat = 8
        let availableWidth = size.width - inset * 2
        let availableHeight = size.height - inset * 2
        let primaryWidth = availableWidth * 0.60
        let trailingWidth = availableWidth - primaryWidth - gap
        let topHeight = availableHeight * 0.63
        let bottomHeight = availableHeight - topHeight - gap

        return ZStack {
            HStack(alignment: .top, spacing: gap) {
                peoplePortrait(
                    url: displayURLs[0],
                    width: primaryWidth,
                    height: availableHeight,
                    emphasis: .primary
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(spacing: gap) {
                    peoplePortrait(
                        url: displayURLs[1],
                        width: trailingWidth,
                        height: topHeight,
                        emphasis: .secondary
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    HStack(spacing: gap) {
                        peoplePortrait(
                            url: displayURLs[2],
                            width: (trailingWidth - gap) / 2,
                            height: bottomHeight,
                            emphasis: .tertiary
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        peoplePortrait(
                            url: displayURLs[3],
                            width: (trailingWidth - gap) / 2,
                            height: bottomHeight,
                            emphasis: .tertiary
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .frame(width: trailingWidth, height: availableHeight, alignment: .topLeading)
            }
            .padding(inset)
        }
    }

    private func peoplePortrait(url: URL, width: CGFloat, height: CGFloat, emphasis: PortraitBandEmphasis) -> some View
    {
        IOSPortraitStageImage(url: url, emphasis: emphasis)
            .frame(width: width, height: height)
    }
}

enum AlbumTileProminence {
    case primary
    case secondary
    case tertiary
}

enum PortraitBandEmphasis {
    case primary
    case secondary
    case tertiary
}

struct IOSGridStageImage: View {
    let url: URL
    let prominence: AlbumTileProminence

    private var requestContext: [SDWebImageContextOption: Any] {
        if let modifier = ImmichRequestModifier.create() {
            return [.downloadRequestModifier: modifier]
        }
        return [:]
    }

    var body: some View {
        WebImage(url: url, context: requestContext)
            .resizable()
            .indicator(.activity)
            .aspectRatio(contentMode: .fill)
            .transition(.fade(duration: 0.25))
            .background(Color.white.opacity(0.04))
            .overlay {
                RoundedRectangle(cornerRadius: 0, style: .continuous)
                    .fill(tileVeil)
            }
            .clipped()
    }

    private var tileVeil: some ShapeStyle {
        switch prominence {
        case .primary:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(0.10)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        case .secondary:
            return AnyShapeStyle(Color.black.opacity(0.12))
        case .tertiary:
            return AnyShapeStyle(Color.black.opacity(0.18))
        }
    }
}

struct IOSPortraitStageImage: View {
    let url: URL
    let emphasis: PortraitBandEmphasis

    private var requestContext: [SDWebImageContextOption: Any] {
        if let modifier = ImmichRequestModifier.create() {
            return [.downloadRequestModifier: modifier]
        }
        return [:]
    }

    var body: some View {
        WebImage(url: url, context: requestContext)
            .resizable()
            .indicator(.activity)
            .aspectRatio(contentMode: .fill)
            .transition(.fade(duration: 0.25))
            .overlay {
                Rectangle()
                    .fill(veil)
            }
            .overlay(alignment: .topLeading) {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.18),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColor, lineWidth: borderWidth)
            }
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: 10)
            .clipped()
    }

    private var cornerRadius: CGFloat {
        switch emphasis {
        case .primary:
            return 24
        case .secondary:
            return 22
        case .tertiary:
            return 20
        }
    }

    private var borderColor: Color {
        switch emphasis {
        case .primary:
            return Color.white.opacity(0.18)
        case .secondary:
            return Color.white.opacity(0.12)
        case .tertiary:
            return Color.white.opacity(0.08)
        }
    }

    private var borderWidth: CGFloat {
        switch emphasis {
        case .primary:
            return 1.4
        case .secondary:
            return 1.2
        case .tertiary:
            return 1.0
        }
    }

    private var veil: some ShapeStyle {
        switch emphasis {
        case .primary:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.04),
                        Color.black.opacity(0.16)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        case .secondary:
            return AnyShapeStyle(Color.black.opacity(0.20))
        case .tertiary:
            return AnyShapeStyle(Color.black.opacity(0.28))
        }
    }

    private var shadowColor: Color {
        switch emphasis {
        case .primary:
            return Color.black.opacity(0.26)
        case .secondary:
            return Color.black.opacity(0.18)
        case .tertiary:
            return Color.black.opacity(0.12)
        }
    }

    private var shadowRadius: CGFloat {
        switch emphasis {
        case .primary:
            return 18
        case .secondary:
            return 14
        case .tertiary:
            return 10
        }
    }
}

private func repeated(urls: [URL], minimumCount: Int) -> [URL] {
    guard urls.isEmpty == false else { return [] }
    var expanded = urls
    while expanded.count < minimumCount {
        expanded.append(contentsOf: urls)
    }
    return Array(expanded.prefix(max(minimumCount, urls.count)))
}
