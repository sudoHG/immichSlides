//
//  FilterSummaryViewIOS+Media.swift
//  immichSlides
//
//  Created by Codex during platform separation.
//

import SwiftUI
import SDWebImageSwiftUI
import SDWebImage

struct SelectionStageMosaicViewIOS: View {
    enum Style {
        case album
        case people
    }

    let urls: [URL]
    let style: Style

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 0, style: .continuous)
                    .fill(Color.black.opacity(style == .people ? 0.12 : 0.08))

                if style == .album {
                    albumLayout(size: geometry.size, urls: urls)
                } else {
                    peopleLayout(size: geometry.size, urls: urls)
                }
            }
            .clipped()
        }
    }

    private func albumLayout(size: CGSize, urls: [URL]) -> some View {
        arrangedTiles(photos: CoverMosaicLayout.distinct(urls), size: size) { url, width, height, role in
            albumTile(url: url, width: width, height: height, prominence: role.albumProminence)
                .clipShape(RoundedRectangle(cornerRadius: role.cornerRadius, style: .continuous))
        }
        .padding(Self.inset)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func albumTile(url: URL, width: CGFloat, height: CGFloat, prominence: AlbumTileProminence) -> some View {
        GridStageImageViewIOS(url: url, prominence: prominence)
            .frame(width: width, height: height)
    }

    private func peopleLayout(size: CGSize, urls: [URL]) -> some View {
        ZStack {
            arrangedTiles(photos: CoverMosaicLayout.distinct(urls), size: size) { url, width, height, role in
                peoplePortrait(url: url, width: width, height: height, emphasis: role.portraitEmphasis)
                    .clipShape(RoundedRectangle(cornerRadius: role.cornerRadius, style: .continuous))
            }
            .padding(Self.inset)
        }
    }

    private func peoplePortrait(url: URL, width: CGFloat, height: CGFloat, emphasis: PortraitBandEmphasis) -> some View
    {
        PortraitStageImageViewIOS(url: url, emphasis: emphasis)
            .frame(width: width, height: height)
    }

    // Four or more photos keep the original large-plus-three arrangement; fewer photos get fewer, larger tiles.
    @ViewBuilder
    private func arrangedTiles<Tile: View>(
        photos: [URL],
        size: CGSize,
        tile: @escaping (URL, CGFloat, CGFloat, TileRole) -> Tile
    ) -> some View {
        let gap = Self.gap
        let availableWidth = size.width - Self.inset * 2
        let availableHeight = size.height - Self.inset * 2
        let largeWidth = availableWidth * 0.60
        let trailingWidth = availableWidth - largeWidth - gap
        let topHeight = availableHeight * 0.63
        let bottomHeight = availableHeight - topHeight - gap

        switch CoverMosaicLayout.tabletArrangement(photoCount: photos.count) {
        case .empty:
            EmptyView()
        case .single:
            tile(photos[0], availableWidth, availableHeight, .primary)
        case .pair:
            HStack(spacing: gap) {
                tile(photos[0], (availableWidth - gap) / 2, availableHeight, .primary)
                tile(photos[1], (availableWidth - gap) / 2, availableHeight, .secondary)
            }
        case .trio:
            HStack(alignment: .top, spacing: gap) {
                tile(photos[0], largeWidth, availableHeight, .primary)

                VStack(spacing: gap) {
                    tile(photos[1], trailingWidth, topHeight, .secondary)
                    tile(photos[2], trailingWidth, bottomHeight, .tertiary)
                }
                .frame(width: trailingWidth, height: availableHeight, alignment: .topLeading)
            }
        case .quad:
            HStack(alignment: .top, spacing: gap) {
                tile(photos[0], largeWidth, availableHeight, .primary)

                VStack(spacing: gap) {
                    tile(photos[1], trailingWidth, topHeight, .secondary)

                    HStack(spacing: gap) {
                        tile(photos[2], (trailingWidth - gap) / 2, bottomHeight, .tertiary)
                        tile(photos[3], (trailingWidth - gap) / 2, bottomHeight, .tertiary)
                    }
                }
                .frame(width: trailingWidth, height: availableHeight, alignment: .topLeading)
            }
        }
    }

    private static let gap: CGFloat = 6
    private static let inset: CGFloat = 8

    enum TileRole {
        case primary
        case secondary
        case tertiary

        var cornerRadius: CGFloat { self == .primary ? 18 : 16 }

        var albumProminence: AlbumTileProminence {
            switch self {
            case .primary: return .primary
            case .secondary: return .secondary
            case .tertiary: return .tertiary
            }
        }

        var portraitEmphasis: PortraitBandEmphasis {
            switch self {
            case .primary: return .primary
            case .secondary: return .secondary
            case .tertiary: return .tertiary
            }
        }
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

struct GridStageImageViewIOS: View {
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

struct PortraitStageImageViewIOS: View {
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
