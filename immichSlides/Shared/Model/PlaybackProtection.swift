//
//  PlaybackProtection.swift
//  immichSlides
//

import Foundation

struct PlaybackProtectionRect: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    nonisolated static func normalized(
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> PlaybackProtectionRect? {
        guard x.isFinite,
            y.isFinite,
            width.isFinite,
            height.isFinite,
            width >= 0,
            height >= 0
        else {
            return nil
        }

        if x >= 0,
            y >= 0,
            x + width <= 1,
            y + height <= 1,
            width > 0,
            height > 0
        {
            return PlaybackProtectionRect(x: x, y: y, width: width, height: height)
        }

        let minX = clamp(x)
        let minY = clamp(y)
        let maxX = clamp(x + width)
        let maxY = clamp(y + height)
        guard maxX > minX, maxY > minY else { return nil }

        return PlaybackProtectionRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    nonisolated static func fromPixelRect(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        surfaceWidth: Double,
        surfaceHeight: Double
    ) -> PlaybackProtectionRect? {
        fromSurfaceRect(
            x: x,
            y: y,
            width: width,
            height: height,
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight
        )
    }

    nonisolated static func fromPointRect(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        surfaceWidth: Double,
        surfaceHeight: Double
    ) -> PlaybackProtectionRect? {
        fromSurfaceRect(
            x: x,
            y: y,
            width: width,
            height: height,
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight
        )
    }

    private nonisolated static func fromSurfaceRect(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        surfaceWidth: Double,
        surfaceHeight: Double
    ) -> PlaybackProtectionRect? {
        guard surfaceWidth.isFinite,
            surfaceHeight.isFinite,
            surfaceWidth > 0,
            surfaceHeight > 0
        else {
            return nil
        }

        return normalized(
            x: x / surfaceWidth,
            y: y / surfaceHeight,
            width: width / surfaceWidth,
            height: height / surfaceHeight
        )
    }

    private nonisolated static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

struct PlaybackProtectionInsets: Equatable, Sendable {
    let top: Double
    let leading: Double
    let bottom: Double
    let trailing: Double
}

enum PlaybackProtectionPriority: String, Equatable, Sendable {
    case hard
    case standard
    case soft
}

enum PlaybackProtectionSource: String, Equatable, Sendable {
    case systemSafeArea
    case systemTopObstruction
    case exifPanel
    case futureOverlay
    case controlBar

    nonisolated var summaryLabel: String {
        switch self {
        case .systemSafeArea:
            "system-safe-area"
        case .systemTopObstruction:
            "system-top-obstruction"
        case .exifPanel:
            "exif-panel"
        case .futureOverlay:
            "future-overlay"
        case .controlBar:
            "control-bar"
        }
    }
}

struct PlaybackProtectionRegion: Equatable, Sendable {
    private nonisolated static let maximumActiveConditionSummaryCharacters: Int = 80
    let source: PlaybackProtectionSource
    let priority: PlaybackProtectionPriority
    let rect: PlaybackProtectionRect
    let activeConditionSummary: String

    nonisolated static func systemSafeArea(
        rect: PlaybackProtectionRect,
        activeConditionSummary: String
    ) -> PlaybackProtectionRegion? {
        make(
            source: .systemSafeArea,
            priority: .hard,
            rect: rect,
            activeConditionSummary: activeConditionSummary
        )
    }

    nonisolated static func systemTopObstruction(
        rect: PlaybackProtectionRect,
        activeConditionSummary: String
    ) -> PlaybackProtectionRegion? {
        make(
            source: .systemTopObstruction,
            priority: .hard,
            rect: rect,
            activeConditionSummary: activeConditionSummary
        )
    }

    nonisolated static func exifPanel(
        isShowingExif: Bool,
        hasExifContent: Bool,
        frame: PlaybackProtectionRect?
    ) -> PlaybackProtectionRegion? {
        guard isShowingExif, hasExifContent, let frame else { return nil }
        return make(
            source: .exifPanel,
            priority: .soft,
            rect: frame,
            activeConditionSummary: "showExif=true;hasExif=true;frame=valid"
        )
    }

    nonisolated static func futureOverlay(
        rect: PlaybackProtectionRect,
        activeConditionSummary: String
    ) -> PlaybackProtectionRegion? {
        make(
            source: .futureOverlay,
            priority: .soft,
            rect: rect,
            activeConditionSummary: activeConditionSummary
        )
    }

    nonisolated static func controlBar(
        rect: PlaybackProtectionRect,
        activeConditionSummary: String
    ) -> PlaybackProtectionRegion? {
        make(
            source: .controlBar,
            priority: .soft,
            rect: rect,
            activeConditionSummary: activeConditionSummary
        )
    }

    private nonisolated static func make(
        source: PlaybackProtectionSource,
        priority: PlaybackProtectionPriority,
        rect: PlaybackProtectionRect,
        activeConditionSummary: String
    ) -> PlaybackProtectionRegion? {
        guard
            let normalizedRect = PlaybackProtectionRect.normalized(
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height
            )
        else {
            return nil
        }

        return PlaybackProtectionRegion(
            source: source,
            priority: priority,
            rect: normalizedRect,
            activeConditionSummary: safeActiveConditionSummary(activeConditionSummary)
        )
    }

    private nonisolated static func safeActiveConditionSummary(_ summary: String) -> String {
        let allowed = summary.filter { character in
            character.isLetter
                || character.isNumber
                || character == "="
                || character == ";"
                || character == "-"
                || character == "_"
        }
        return allowed.isEmpty ? "active" : String(allowed.prefix(maximumActiveConditionSummaryCharacters))
    }
}

struct PlaybackProtectionSnapshot: Equatable, Sendable {
    let version: String
    let regions: [PlaybackProtectionRegion]
    #if DEBUG
    let qaDebugSummary: String
    #endif

    nonisolated static let empty = PlaybackProtectionSnapshot(regions: [])

    nonisolated init(regions: [PlaybackProtectionRegion]) {
        self.version = "screen-protection-v1"
        self.regions = regions
        #if DEBUG
        self.qaDebugSummary = Self.makeQADebugSummary(regions: regions)
        #endif
    }

    nonisolated var smartFillReplanFingerprint: String {
        let regionKeys = regions.map { region in
            [
                region.source.rawValue,
                region.priority.rawValue,
                region.activeConditionSummary
            ].joined(separator: ":")
        }.sorted()
        return ([version] + regionKeys).joined(separator: "|")
    }

    nonisolated init(
        safeAreaInsets: PlaybackProtectionInsets,
        systemTopObstructionHeight: Double,
        surfaceWidth: Double,
        surfaceHeight: Double
    ) {
        var regions: [PlaybackProtectionRegion] = []

        if let top = Self.regionFromSurfaceRect(
            source: .systemSafeArea,
            rect: (x: 0, y: 0, width: surfaceWidth, height: safeAreaInsets.top),
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight,
            activeConditionSummary: "edge=top"
        ) {
            regions.append(top)
        }
        if let leading = Self.regionFromSurfaceRect(
            source: .systemSafeArea,
            rect: (x: 0, y: 0, width: safeAreaInsets.leading, height: surfaceHeight),
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight,
            activeConditionSummary: "edge=leading"
        ) {
            regions.append(leading)
        }
        if let bottom = Self.regionFromSurfaceRect(
            source: .systemSafeArea,
            rect: (x: 0, y: surfaceHeight - safeAreaInsets.bottom, width: surfaceWidth, height: safeAreaInsets.bottom),
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight,
            activeConditionSummary: "edge=bottom"
        ) {
            regions.append(bottom)
        }
        if let trailing = Self.regionFromSurfaceRect(
            source: .systemSafeArea,
            rect: (
                x: surfaceWidth - safeAreaInsets.trailing, y: 0, width: safeAreaInsets.trailing, height: surfaceHeight
            ),
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight,
            activeConditionSummary: "edge=trailing"
        ) {
            regions.append(trailing)
        }
        if let topObstruction = Self.regionFromSurfaceRect(
            source: .systemTopObstruction,
            rect: (x: 0, y: 0, width: surfaceWidth, height: systemTopObstructionHeight),
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight,
            activeConditionSummary: "topObstruction=true"
        ) {
            regions.append(topObstruction)
        }

        self.init(regions: regions)
    }

    private nonisolated static func regionFromSurfaceRect(
        source: PlaybackProtectionSource,
        rect: (x: Double, y: Double, width: Double, height: Double),
        surfaceWidth: Double,
        surfaceHeight: Double,
        activeConditionSummary: String
    ) -> PlaybackProtectionRegion? {
        guard
            let normalizedRect = PlaybackProtectionRect.fromPointRect(
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height,
                surfaceWidth: surfaceWidth,
                surfaceHeight: surfaceHeight
            )
        else {
            return nil
        }

        switch source {
        case .systemSafeArea:
            return .systemSafeArea(
                rect: normalizedRect,
                activeConditionSummary: activeConditionSummary
            )
        case .systemTopObstruction:
            return .systemTopObstruction(
                rect: normalizedRect,
                activeConditionSummary: activeConditionSummary
            )
        case .exifPanel, .futureOverlay, .controlBar:
            return nil
        }
    }

    #if DEBUG
    private nonisolated static func makeQADebugSummary(regions: [PlaybackProtectionRegion]) -> String {
        let hardCount = regions.filter { $0.priority == .hard }.count
        let standardCount = regions.filter { $0.priority == .standard }.count
        let softCount = regions.filter { $0.priority == .soft }.count
        let sources = uniqueSources(in: regions)
            .map(\.summaryLabel)
            .joined(separator: ",")
        return [
            "version=screen-protection-v1",
            "regions=\(regions.count)",
            "hard=\(hardCount)",
            "standard=\(standardCount)",
            "soft=\(softCount)",
            "sources=\(sources.isEmpty ? "none" : sources)"
        ].joined(separator: ";")
    }
    private nonisolated static func uniqueSources(in regions: [PlaybackProtectionRegion]) -> [PlaybackProtectionSource]
    {
        var seen: [PlaybackProtectionSource] = []
        for source in regions.map(\.source) where !seen.contains(source) {
            seen.append(source)
        }
        return seen
    }
    #endif
}
