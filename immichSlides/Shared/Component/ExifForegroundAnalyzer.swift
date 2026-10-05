//
//  ExifForegroundAnalyzer.swift
//  immichSlides
//
//  Created by Codex on 2026/4/20.
//

import UIKit
import CoreImage
import SDWebImage

enum SinglePhotoBackdropMetrics {
    static let blurRadiusPoints: CGFloat = 50
}

private enum ExifSamplingDimensions {
    static let minimumDisplayDimensionPoints: CGFloat = 1
    static let minimumSourceDimensionPixels: CGFloat = 1
    static let minimumSampleDimensionPixels: CGFloat = 1
}

// Screen geometry used for EXIF sampling; not GeometryProxy, so the analyzer does not depend on view objects.

struct ExifDisplayedBackdropContext: Equatable {
    let surfaceSize: CGSize
    let safeAreaInsets: UIEdgeInsets
    let exifFrameInSurfaceSpace: CGRect

    // While the frame is still .zero there is not enough to sample, so the screen-space algorithm cannot run.

    var isValid: Bool {
        surfaceSize.width > ExifSamplingDimensions.minimumDisplayDimensionPoints
            && surfaceSize.height > ExifSamplingDimensions.minimumDisplayDimensionPoints
            && exifFrameInSurfaceSpace.width > ExifSamplingDimensions.minimumDisplayDimensionPoints
            && exifFrameInSurfaceSpace.height > ExifSamplingDimensions.minimumDisplayDimensionPoints
    }

    // The blurred background layer covers the Safe Area, so the scaledToFill size must include the insets.

    var backdropSize: CGSize {
        CGSize(
            width: surfaceSize.width + safeAreaInsets.left + safeAreaInsets.right,
            height: surfaceSize.height + safeAreaInsets.top + safeAreaInsets.bottom
        )
    }

    // SlideItemView's background reaches up-left into the Safe Area; add left/top back when converting screen frames.

    var exifFrameInBackdropSpace: CGRect {
        exifFrameInSurfaceSpace.offsetBy(
            dx: safeAreaInsets.left,
            dy: safeAreaInsets.top
        )
    }
}

// Only for sampling diagnostics; not used in real playback.

#if DEBUG
struct ExifSamplingDebugSnapshot {
    let reconstructedPanelImage: UIImage
    let panelRectInSurfaceSpace: CGRect
    let panelRectInBackdropSpace: CGRect
    let expandedPanelRectInBackdropSpace: CGRect
}
#endif

// One analyzer shared by iOS/tvOS; platform differences are collected into a profile.

struct ExifForegroundAnalysisProfile {
    // The relative region of the EXIF card that actually holds most of the text.
    let displayedCoreTextRegion: CGRect
    // Used to decide "is this a small badge with little content".
    let compactPanelMaximumSize: CGSize
    // Only used in the benchmark's "previous screen-space average brightness" path.
    let displayedBackdropMaterialLift: CGFloat
    // When normalizing image orientation, keep the renderer format that was more stable on this platform before.
    let normalizedRendererFormat: NormalizedRendererFormat

    enum NormalizedRendererFormat {
        case `default`
        case preferred
    }

    // On phones the core text area is more centered and the small-badge threshold is smaller.

    nonisolated static var iOS: ExifForegroundAnalysisProfile {
        ExifForegroundAnalysisProfile(
            displayedCoreTextRegion: CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.70),
            compactPanelMaximumSize: CGSize(width: 150, height: 56),
            displayedBackdropMaterialLift: 0.05,
            normalizedRendererFormat: .default
        )
    }

    // The TV panel is wider, and core sampling leans left.

    nonisolated static var tvOS: ExifForegroundAnalysisProfile {
        ExifForegroundAnalysisProfile(
            displayedCoreTextRegion: CGRect(x: 0.06, y: 0.08, width: 0.68, height: 0.70),
            compactPanelMaximumSize: CGSize(width: 240, height: 84),
            displayedBackdropMaterialLift: 0,
            normalizedRendererFormat: .preferred
        )
    }
}

// Old and new algorithms share one main sampling flow; only platform differences are parameters.

enum ExifForegroundAnalyzer {
    private struct BrightnessStats {
        let average: CGFloat
        let median: CGFloat
        let lowerQuartile: CGFloat
        let upperQuartile: CGFloat

        var spread: CGFloat {
            upperQuartile - lowerQuartile
        }
    }

    // Mainly use the core text area; the whole card only lightly corrects it, so one small patch cannot cause jitter.

    private struct ToneDecisionMetrics {
        let panel: BrightnessStats
        let coreText: BrightnessStats
        let isCompactPanel: Bool
    }

    // Sample the whole card once, then slice sub-regions on the CPU, to avoid repeated Core Image renders.

    private struct SampledLuminanceGrid {
        let samples: [CGFloat]
        let width: Int
        let height: Int

        func samples(in normalizedRegion: CGRect) -> [CGFloat] {
            guard width > 0, height > 0, !samples.isEmpty else {
                return []
            }

            let minColumn = max(0, min(width - 1, Int(floor(CGFloat(width) * normalizedRegion.minX))))
            let maxColumn = max(
                minColumn + 1,
                min(width, Int(ceil(CGFloat(width) * normalizedRegion.maxX)))
            )
            let minRow = max(0, min(height - 1, Int(floor(CGFloat(height) * normalizedRegion.minY))))
            let maxRow = max(
                minRow + 1,
                min(height, Int(ceil(CGFloat(height) * normalizedRegion.maxY)))
            )

            var regionSamples: [CGFloat] = []
            regionSamples.reserveCapacity((maxColumn - minColumn) * (maxRow - minRow))

            for row in minRow..<maxRow {
                for column in minColumn..<maxColumn {
                    regionSamples.append(samples[(row * width) + column])
                }
            }

            return regionSamples
        }
    }

    // The old region algorithm is kept for the frame-not-ready fallback and the benchmark.

    private static let legacyPanelRegion = CGRect(x: 0.60, y: 0.03, width: 0.34, height: 0.16)
    private static let legacyCoreTextRegion = CGRect(x: 0.64, y: 0.04, width: 0.26, height: 0.10)

    // Coordinates are relative to the EXIF card itself, so they follow the panel when its on-device position changes.

    private static let displayedPanelRegion = CGRect(x: 0, y: 0, width: 1, height: 1)

    private static let coreTextBlendWeight: CGFloat = 0.78
    private static let panelBlendWeight: CGFloat = 0.22
    private static let compactBadgeMedianThreshold: CGFloat = 0.56
    private static let compactBadgeCoreUpperQuartileThreshold: CGFloat = 0.70
    private static let compactBadgePanelUpperQuartileThreshold: CGFloat = 0.68
    private static let redLuminanceCoefficient: CGFloat = 0.2126
    private static let greenLuminanceCoefficient: CGFloat = 0.7152
    private static let blueLuminanceCoefficient: CGFloat = 0.0722
    private static let darkTextThreshold: CGFloat = 0.53
    private static let backgroundBlurRadius: CGFloat = SinglePhotoBackdropMetrics.blurRadiusPoints
    private static let blurSamplingPadding: CGFloat = 80
    // The real text color does not assume the material layer brightens things noticeably.

    private static let readabilityMaterialLift: CGFloat = 0
    private static let displayedReadabilitySampleGrid = CGSize(width: 24, height: 12)
    private static let darkTextMeanThreshold: CGFloat = 0.68
    private static let darkTextMedianThreshold: CGFloat = 0.66
    private static let darkTextFloorThreshold: CGFloat = 0.61
    private static let darkTextSpreadThreshold: CGFloat = 0.18
    private static let darkTextExtremeMeanThreshold: CGFloat = 0.76
    private static let darkTextExtremeFloorThreshold: CGFloat = 0.68
    private static let ciContext = CIContext(options: nil)

    static func resolveTone(
        assetId: String,
        downloadManager: AssetsDownloadManager,
        backdropContext: ExifDisplayedBackdropContext?,
        profile: ExifForegroundAnalysisProfile = .iOS
    ) async -> ExifForegroundTone {
        // Snapshot the URLs on the main actor first; the background only reads this immutable array.

        let candidateURLs = cachedImageCandidateURLs(
            assetId: assetId,
            downloadManager: downloadManager
        )

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let tone = resolveToneSynchronously(
                    candidateURLs: candidateURLs,
                    backdropContext: backdropContext,
                    profile: profile
                )
                continuation.resume(returning: tone)
            }
        }
    }

    private static func resolveToneSynchronously(
        candidateURLs: [URL],
        backdropContext: ExifDisplayedBackdropContext?,
        profile: ExifForegroundAnalysisProfile
    ) -> ExifForegroundTone {
        guard let image = loadCachedImage(from: candidateURLs) else {
            return .lightText
        }

        return resolveTone(
            from: image,
            backdropContext: backdropContext,
            profile: profile
        )
    }

    static func resolveTone(
        from image: UIImage,
        backdropContext: ExifDisplayedBackdropContext?,
        profile: ExifForegroundAnalysisProfile = .iOS
    ) -> ExifForegroundTone {
        guard let cgImage = normalizedCGImage(from: image, profile: profile) else {
            return .lightText
        }

        if let backdropContext,
            backdropContext.isValid,
            let displayedMetrics = displayedBackdropToneMetrics(
                of: cgImage,
                backdropContext: backdropContext,
                profile: profile
            )
        {
            return resolveTone(from: displayedMetrics)
        }

        guard let legacyLuminance = legacyEffectiveLuminance(of: cgImage) else {
            return .lightText
        }
        return legacyLuminance >= darkTextThreshold ? .darkText : .lightText
    }

    #if DEBUG
    // Only lets the benchmark measure the old and new algorithms separately; production does not call it directly.

    static func legacyToneForBenchmark(from cgImage: CGImage) -> ExifForegroundTone? {
        guard let luminance = legacyEffectiveLuminance(of: cgImage) else {
            return nil
        }
        return luminance >= darkTextThreshold ? .darkText : .lightText
    }

    static func displayedBackdropToneForBenchmark(
        from cgImage: CGImage,
        backdropContext: ExifDisplayedBackdropContext,
        profile: ExifForegroundAnalysisProfile = .iOS
    ) -> ExifForegroundTone? {
        guard
            let metrics = displayedBackdropToneMetrics(
                of: cgImage,
                backdropContext: backdropContext,
                profile: profile
            )
        else {
            return nil
        }
        return resolveTone(from: metrics)
    }

    // Keeps the previous screen-space average brightness, only for benchmark comparison.

    static func displayedBackdropAverageToneForBenchmark(
        from cgImage: CGImage,
        backdropContext: ExifDisplayedBackdropContext,
        profile: ExifForegroundAnalysisProfile = .iOS
    ) -> ExifForegroundTone? {
        guard
            let luminance = displayedBackdropEffectiveLuminance(
                of: cgImage,
                backdropContext: backdropContext,
                profile: profile
            )
        else {
            return nil
        }
        return luminance >= darkTextThreshold ? .darkText : .lightText
    }

    static func debugSnapshot(
        assetId: String,
        downloadManager: AssetsDownloadManager,
        backdropContext: ExifDisplayedBackdropContext
    ) async -> ExifSamplingDebugSnapshot? {
        // The diagnostic snapshot also captures URLs on the main actor first, then goes to the background.

        let candidateURLs = cachedImageCandidateURLs(
            assetId: assetId,
            downloadManager: downloadManager
        )

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let snapshot = debugSnapshotSynchronously(
                    candidateURLs: candidateURLs,
                    backdropContext: backdropContext
                )
                continuation.resume(returning: snapshot)
            }
        }
    }

    // The diagnostic image reuses renderedDisplayedBackdropPanel, so it shares the real text color's background.

    private static func debugSnapshotSynchronously(
        candidateURLs: [URL],
        backdropContext: ExifDisplayedBackdropContext
    ) -> ExifSamplingDebugSnapshot? {
        guard backdropContext.isValid,
            let image = loadCachedImage(from: candidateURLs),
            let cgImage = normalizedCGImage(from: image, profile: .iOS)
        else {
            return nil
        }

        let backdropBounds = CGRect(origin: .zero, size: backdropContext.backdropSize)
        let panelRect = backdropContext.exifFrameInBackdropSpace.intersection(backdropBounds)

        guard !panelRect.isNull, panelRect.width > ExifSamplingDimensions.minimumDisplayDimensionPoints,
            panelRect.height > ExifSamplingDimensions.minimumDisplayDimensionPoints
        else {
            return nil
        }

        let expandedPanelRect =
            panelRect
            .insetBy(dx: -blurSamplingPadding, dy: -blurSamplingPadding)
            .intersection(backdropBounds)

        guard
            let renderedPanelImage = renderedDisplayedBackdropPanel(
                of: cgImage,
                backdropSize: backdropContext.backdropSize,
                expandedPanelRect: expandedPanelRect,
                panelRect: panelRect
            )
        else {
            return nil
        }

        guard
            let renderedCGImage = ciContext.createCGImage(
                renderedPanelImage,
                from: renderedPanelImage.extent
            )
        else {
            return nil
        }

        return ExifSamplingDebugSnapshot(
            reconstructedPanelImage: UIImage(cgImage: renderedCGImage),
            panelRectInSurfaceSpace: backdropContext.exifFrameInSurfaceSpace,
            panelRectInBackdropSpace: panelRect,
            expandedPanelRectInBackdropSpace: expandedPanelRect
        )
    }
    #endif

    private static func legacyEffectiveLuminance(of cgImage: CGImage) -> CGFloat? {
        guard
            let panelLuminance = averageLuminance(
                of: cgImage,
                normalizedRegion: legacyPanelRegion
            )
        else {
            return nil
        }

        let coreTextLuminance =
            averageLuminance(
                of: cgImage,
                normalizedRegion: legacyCoreTextRegion
            ) ?? panelLuminance

        return max(panelLuminance, coreTextLuminance)
    }

    // White text by default; switch to black only when the whole background is clearly bright and uniform enough.

    private static func displayedBackdropToneMetrics(
        of cgImage: CGImage,
        backdropContext: ExifDisplayedBackdropContext,
        profile: ExifForegroundAnalysisProfile
    ) -> ToneDecisionMetrics? {
        let backdropBounds = CGRect(origin: .zero, size: backdropContext.backdropSize)
        let panelRect = backdropContext.exifFrameInBackdropSpace.intersection(backdropBounds)

        guard !panelRect.isNull, panelRect.width > ExifSamplingDimensions.minimumDisplayDimensionPoints,
            panelRect.height > ExifSamplingDimensions.minimumDisplayDimensionPoints
        else {
            return nil
        }

        let expandedPanelRect =
            panelRect
            .insetBy(dx: -blurSamplingPadding, dy: -blurSamplingPadding)
            .intersection(backdropBounds)

        guard
            let renderedPanelImage = renderedDisplayedBackdropPanel(
                of: cgImage,
                backdropSize: backdropContext.backdropSize,
                expandedPanelRect: expandedPanelRect,
                panelRect: panelRect
            )
        else {
            return nil
        }

        guard
            let luminanceGrid = sampledLuminanceGrid(
                of: renderedPanelImage,
                sampleGrid: displayedReadabilitySampleGrid,
                materialLift: readabilityMaterialLift
            )
        else {
            return nil
        }

        guard
            let panelStats = brightnessStats(
                fromLuminanceSamples: luminanceGrid.samples
            )
        else {
            return nil
        }

        let coreTextStats =
            brightnessStats(
                fromLuminanceSamples: luminanceGrid.samples(in: profile.displayedCoreTextRegion)
            ) ?? panelStats

        return ToneDecisionMetrics(
            panel: panelStats,
            coreText: coreTextStats,
            isCompactPanel: isCompactExifPanel(
                backdropContext.exifFrameInSurfaceSpace,
                profile: profile
            )
        )
    }

    private static func isCompactExifPanel(
        _ frame: CGRect,
        profile: ExifForegroundAnalysisProfile
    ) -> Bool {
        // A small date badge leans to black text as long as the area behind the text is bright enough; the large-panel
        // uniformity rule does not apply.

        frame.width <= profile.compactPanelMaximumSize.width && frame.height <= profile.compactPanelMaximumSize.height
    }

    #if DEBUG
    // Keeps the full previous screen-space average brightness for the benchmark only; not used in production choices.

    private static func displayedBackdropEffectiveLuminance(
        of cgImage: CGImage,
        backdropContext: ExifDisplayedBackdropContext,
        profile: ExifForegroundAnalysisProfile
    ) -> CGFloat? {
        let backdropBounds = CGRect(origin: .zero, size: backdropContext.backdropSize)
        let panelRect = backdropContext.exifFrameInBackdropSpace.intersection(backdropBounds)

        guard !panelRect.isNull, panelRect.width > ExifSamplingDimensions.minimumDisplayDimensionPoints,
            panelRect.height > ExifSamplingDimensions.minimumDisplayDimensionPoints
        else {
            return nil
        }

        let expandedPanelRect =
            panelRect
            .insetBy(dx: -blurSamplingPadding, dy: -blurSamplingPadding)
            .intersection(backdropBounds)

        guard
            let renderedPanelImage = renderedDisplayedBackdropPanel(
                of: cgImage,
                backdropSize: backdropContext.backdropSize,
                expandedPanelRect: expandedPanelRect,
                panelRect: panelRect
            )
        else {
            return nil
        }

        guard
            let panelLuminance = averageLuminance(
                of: renderedPanelImage,
                normalizedRegion: displayedPanelRegion,
                materialLift: profile.displayedBackdropMaterialLift
            )
        else {
            return nil
        }

        let coreTextLuminance =
            averageLuminance(
                of: renderedPanelImage,
                normalizedRegion: profile.displayedCoreTextRegion,
                materialLift: profile.displayedBackdropMaterialLift
            ) ?? panelLuminance

        return max(panelLuminance, coreTextLuminance)
    }
    #endif

    // Rebuild the EXIF area offline from SlideItemView's fill+blur instead of capturing the whole screen, so the panel
    // and control bar are not sampled.

    private static func renderedDisplayedBackdropPanel(
        of cgImage: CGImage,
        backdropSize: CGSize,
        expandedPanelRect: CGRect,
        panelRect: CGRect
    ) -> CIImage? {
        guard
            let aspectFillMapping = AspectFillMapping(
                sourceSize: CGSize(width: cgImage.width, height: cgImage.height),
                backdropSize: backdropSize
            )
        else {
            return nil
        }

        // CIImage.cropped uses a bottom-left origin; without flipping the y axis, the top EXIF would be sampled from
        // the bottom of the image.

        let sourceCropRectInTopLeftSpace =
            aspectFillMapping
            .sourceRect(forBackdropRect: expandedPanelRect)
            .intersection(
                CGRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(cgImage.width),
                    height: CGFloat(cgImage.height)
                ))

        guard !sourceCropRectInTopLeftSpace.isNull,
            sourceCropRectInTopLeftSpace.width > ExifSamplingDimensions.minimumSourceDimensionPixels,
            sourceCropRectInTopLeftSpace.height > ExifSamplingDimensions.minimumSourceDimensionPixels
        else {
            return nil
        }

        let sourceCropRect = CGRect(
            x: sourceCropRectInTopLeftSpace.minX,
            y: CGFloat(cgImage.height) - sourceCropRectInTopLeftSpace.maxY,
            width: sourceCropRectInTopLeftSpace.width,
            height: sourceCropRectInTopLeftSpace.height
        )

        let translatedCrop = CIImage(cgImage: cgImage)
            .cropped(to: sourceCropRect)
            .transformed(
                by: CGAffineTransform(
                    translationX: -sourceCropRect.minX,
                    y: -sourceCropRect.minY
                ))

        let scaledCrop = translatedCrop.transformed(
            by: CGAffineTransform(
                scaleX: aspectFillMapping.scale,
                y: aspectFillMapping.scale
            ))

        let blurredCrop =
            scaledCrop
            .clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [
                    kCIInputRadiusKey: backgroundBlurRadius
                ]
            )
            .cropped(to: scaledCrop.extent)

        // panelRect is still in top-left coordinates while blurredCrop is in CI bottom-left coordinates, so the top
        // offset must become a distance from the bottom.

        let panelOffsetX = panelRect.minX - expandedPanelRect.minX
        let panelOffsetYInTopLeftSpace = panelRect.minY - expandedPanelRect.minY
        let panelInExpandedSpace = CGRect(
            x: panelOffsetX,
            y: expandedPanelRect.height - panelOffsetYInTopLeftSpace - panelRect.height,
            width: panelRect.width,
            height: panelRect.height
        )

        let renderedPanel =
            blurredCrop
            .cropped(to: panelInExpandedSpace)
            .transformed(
                by: CGAffineTransform(
                    translationX: -panelInExpandedSpace.minX,
                    y: -panelInExpandedSpace.minY
                ))

        return renderedPanel
    }

    // Prefer preview, because the SlideItemView blurred background also uses preview first.

    @MainActor
    static func hasCachedImage(
        assetId: String,
        downloadManager: AssetsDownloadManager
    ) -> Bool {
        let candidateURLs = cachedImageCandidateURLs(
            assetId: assetId,
            downloadManager: downloadManager
        )
        return loadCachedImage(from: candidateURLs) != nil
    }

    // The download manager's URL dictionary must be read on the main actor; return a plain array to the background.

    @MainActor
    private static func cachedImageCandidateURLs(
        assetId: String,
        downloadManager: AssetsDownloadManager
    ) -> [URL] {
        [
            downloadManager.findURL(assetId: assetId, size: .preview),
            downloadManager.findURL(assetId: assetId, size: .fullsize)
        ].compactMap { $0 }
    }

    private static func loadCachedImage(from candidateURLs: [URL]) -> UIImage? {
        for candidateURL in candidateURLs {
            if let image = SDImageCache.shared.imageFromCache(forKey: candidateURL.absoluteString) {
                return image
            }
        }
        return nil
    }

    private static func normalizedCGImage(
        from image: UIImage,
        profile: ExifForegroundAnalysisProfile
    ) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage {
            return cgImage
        }

        let format: UIGraphicsImageRendererFormat
        switch profile.normalizedRendererFormat {
        case .default:
            format = UIGraphicsImageRendererFormat()
        case .preferred:
            format = UIGraphicsImageRendererFormat.preferred()
        }
        format.scale = 1

        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let normalizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return normalizedImage.cgImage
    }

    // Look at the median and a darker percentile as well as the average, so a few highlights do not push the card to
    // black text.

    private static func brightnessStats(
        fromLuminanceSamples luminanceSamples: [CGFloat]
    ) -> BrightnessStats? {
        guard !luminanceSamples.isEmpty else {
            return nil
        }

        let average = luminanceSamples.reduce(0, +) / CGFloat(luminanceSamples.count)
        let sortedSamples = luminanceSamples.sorted()
        let median = percentile(
            inSortedSamples: sortedSamples,
            percentile: 0.50
        )
        let lowerQuartile = percentile(
            inSortedSamples: sortedSamples,
            percentile: 0.25
        )
        let upperQuartile = percentile(
            inSortedSamples: sortedSamples,
            percentile: 0.75
        )

        return BrightnessStats(
            average: average,
            median: median,
            lowerQuartile: lowerQuartile,
            upperQuartile: upperQuartile
        )
    }

    // Downsample into a small grid to see the local distribution and avoid a full-size scan.

    private static func sampledLuminanceGrid(
        of ciImage: CIImage,
        sampleGrid: CGSize,
        materialLift: CGFloat
    ) -> SampledLuminanceGrid? {
        let sampleRect = ciImage.extent

        guard sampleRect.width > ExifSamplingDimensions.minimumSampleDimensionPixels,
            sampleRect.height > ExifSamplingDimensions.minimumSampleDimensionPixels
        else {
            return nil
        }

        let targetWidth = max(1, Int(sampleGrid.width.rounded()))
        let targetHeight = max(1, Int(sampleGrid.height.rounded()))
        let renderBounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)

        let scaledImage =
            ciImage
            .transformed(
                by: CGAffineTransform(
                    translationX: -sampleRect.minX,
                    y: -sampleRect.minY
                )
            )
            .transformed(
                by: CGAffineTransform(
                    scaleX: CGFloat(targetWidth) / sampleRect.width,
                    y: CGFloat(targetHeight) / sampleRect.height
                )
            )
            .cropped(to: renderBounds)

        var pixels = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        ciContext.render(
            scaledImage,
            toBitmap: &pixels,
            rowBytes: targetWidth * 4,
            bounds: renderBounds,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        var luminanceSamples: [CGFloat] = []
        luminanceSamples.reserveCapacity(targetWidth * targetHeight)

        for pixelStart in stride(from: 0, to: pixels.count, by: 4) {
            let red = CGFloat(pixels[pixelStart]) / 255.0
            let green = CGFloat(pixels[pixelStart + 1]) / 255.0
            let blue = CGFloat(pixels[pixelStart + 2]) / 255.0
            let rawLuminance = relativeLuminance(red: red, green: green, blue: blue)
            luminanceSamples.append(
                adjustedLuminance(rawLuminance, materialLift: materialLift)
            )
        }

        return SampledLuminanceGrid(
            samples: luminanceSamples,
            width: targetWidth,
            height: targetHeight
        )
    }

    private static func resolveTone(from metrics: ToneDecisionMetrics) -> ExifForegroundTone {
        // White text by default; switch to black only when it is bright overall and uniform enough, so a midtone
        // background is not switched early by a local bright patch.

        let blendedAverage =
            (metrics.coreText.average * coreTextBlendWeight) + (metrics.panel.average * panelBlendWeight)
        let blendedMedian = (metrics.coreText.median * coreTextBlendWeight) + (metrics.panel.median * panelBlendWeight)
        let brightnessFloor = min(metrics.coreText.lowerQuartile, metrics.panel.lowerQuartile)
        let brightnessSpread = max(metrics.coreText.spread, metrics.panel.spread)

        let isClearlyBright =
            blendedAverage >= darkTextMeanThreshold && blendedMedian >= darkTextMedianThreshold
            && brightnessFloor >= darkTextFloorThreshold

        let isUniformEnough = brightnessSpread <= darkTextSpreadThreshold

        let isExtremelyBright =
            blendedAverage >= darkTextExtremeMeanThreshold && brightnessFloor >= darkTextExtremeFloorThreshold

        let isBrightCompactBadge =
            metrics.isCompactPanel && metrics.coreText.median >= compactBadgeMedianThreshold
            && metrics.coreText.upperQuartile >= compactBadgeCoreUpperQuartileThreshold
            && metrics.panel.upperQuartile >= compactBadgePanelUpperQuartileThreshold

        return (isBrightCompactBadge || isExtremelyBright || (isClearlyBright && isUniformEnough))
            ? .darkText
            : .lightText
    }

    private static func percentile(
        inSortedSamples sortedSamples: [CGFloat],
        percentile: CGFloat
    ) -> CGFloat {
        guard !sortedSamples.isEmpty else {
            return 0
        }

        let clampedPercentile = min(max(percentile, 0), 1)
        let rawIndex = (CGFloat(sortedSamples.count - 1) * clampedPercentile).rounded(.down)
        let index = max(0, min(Int(rawIndex), sortedSamples.count - 1))
        return sortedSamples[index]
    }

    private static func averageLuminance(
        of cgImage: CGImage,
        normalizedRegion: CGRect
    ) -> CGFloat? {
        let imageRect = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(cgImage.width),
            height: CGFloat(cgImage.height)
        )

        let sampleRect = CGRect(
            x: imageRect.width * normalizedRegion.minX,
            y: imageRect.height * normalizedRegion.minY,
            width: imageRect.width * normalizedRegion.width,
            height: imageRect.height * normalizedRegion.height
        ).intersection(imageRect)

        guard !sampleRect.isNull, sampleRect.width > ExifSamplingDimensions.minimumSampleDimensionPixels,
            sampleRect.height > ExifSamplingDimensions.minimumSampleDimensionPixels
        else {
            return nil
        }

        return averageLuminance(
            of: CIImage(cgImage: cgImage),
            absoluteRegion: sampleRect,
            materialLift: 0
        )
    }

    private static func averageLuminance(
        of ciImage: CIImage,
        normalizedRegion: CGRect,
        materialLift: CGFloat
    ) -> CGFloat? {
        let extent = ciImage.extent
        let sampleRect = CGRect(
            x: extent.width * normalizedRegion.minX,
            y: extent.height * normalizedRegion.minY,
            width: extent.width * normalizedRegion.width,
            height: extent.height * normalizedRegion.height
        ).intersection(extent)

        guard !sampleRect.isNull, sampleRect.width > ExifSamplingDimensions.minimumSampleDimensionPixels,
            sampleRect.height > ExifSamplingDimensions.minimumSampleDimensionPixels
        else {
            return nil
        }

        return averageLuminance(
            of: ciImage,
            absoluteRegion: sampleRect,
            materialLift: materialLift
        )
    }

    private static func averageLuminance(
        of ciImage: CIImage,
        absoluteRegion: CGRect,
        materialLift: CGFloat
    ) -> CGFloat? {
        guard let averageFilter = CIFilter(name: "CIAreaAverage") else {
            return nil
        }

        averageFilter.setValue(
            ciImage.cropped(to: absoluteRegion),
            forKey: kCIInputImageKey
        )
        averageFilter.setValue(
            CIVector(cgRect: absoluteRegion),
            forKey: kCIInputExtentKey
        )

        guard let outputImage = averageFilter.outputImage else {
            return nil
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            outputImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let red = CGFloat(pixel[0]) / 255.0
        let green = CGFloat(pixel[1]) / 255.0
        let blue = CGFloat(pixel[2]) / 255.0

        let rawLuminance = relativeLuminance(red: red, green: green, blue: blue)

        return adjustedLuminance(rawLuminance, materialLift: materialLift)
    }

    private static func relativeLuminance(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> CGFloat {
        (redLuminanceCoefficient * red) + (greenLuminanceCoefficient * green) + (blueLuminanceCoefficient * blue)
    }

    private static func adjustedLuminance(
        _ rawLuminance: CGFloat,
        materialLift: CGFloat
    ) -> CGFloat {
        // Approximate the slight brightening of the material layer with a linear blend.

        min(1, (rawLuminance * (1 - materialLift)) + materialLift)
    }
}

// Describes scaledToFill: scale is the zoom factor, visibleSourceRect is the part of the original image actually shown.

private struct AspectFillMapping {
    let scale: CGFloat
    let visibleSourceRect: CGRect

    init?(sourceSize: CGSize, backdropSize: CGSize) {
        guard sourceSize.width > ExifSamplingDimensions.minimumSourceDimensionPixels,
            sourceSize.height > ExifSamplingDimensions.minimumSourceDimensionPixels,
            backdropSize.width > ExifSamplingDimensions.minimumDisplayDimensionPoints,
            backdropSize.height > ExifSamplingDimensions.minimumDisplayDimensionPoints
        else {
            return nil
        }

        scale = max(
            backdropSize.width / sourceSize.width,
            backdropSize.height / sourceSize.height
        )

        let visibleWidth = backdropSize.width / scale
        let visibleHeight = backdropSize.height / scale

        visibleSourceRect = CGRect(
            x: (sourceSize.width - visibleWidth) / 2,
            y: (sourceSize.height - visibleHeight) / 2,
            width: visibleWidth,
            height: visibleHeight
        )
    }

    func sourceRect(forBackdropRect backdropRect: CGRect) -> CGRect {
        CGRect(
            x: visibleSourceRect.minX + (backdropRect.minX / scale),
            y: visibleSourceRect.minY + (backdropRect.minY / scale),
            width: backdropRect.width / scale,
            height: backdropRect.height / scale
        )
    }
}
