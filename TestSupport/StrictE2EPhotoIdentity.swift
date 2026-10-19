import CoreGraphics
import Foundation
import ImageIO

// On-screen identification of public fixtures: uses only pixels and visible EXIF text, never asset IDs or probes.

enum StrictE2EPhotoIdentity {
    enum Status: String {
        case match = "MATCH"
        case black = "BLACK"
        case blank = "BLANK"
        case unrecognizable = "UNRECOGNIZABLE"
        case transition = "TRANSITION"
    }

    struct Result {
        let status: Status
        let mark: String?
        let scores: [String: Double]
        let meanLuma: Double
        let notes: [String]
    }

    // Calibrate the unchanged Settings glyph before timing starts, then read only captured pixels.
    struct ControlBarReference {
        let normalizedRect: CGRect
        private let centeredPixels: [Double]
        private let magnitude: Double
        private static let edgePixels = 32
        private static let minimumContrast = 8.0  // RMS deviation in 8-bit grey levels over the centered 32x32 sample.
        private static let minimumCorrelation = 0.8

        init?(png: Data, normalizedRect: CGRect) {
            guard let pixels = Self.pixels(png: png, normalizedRect: normalizedRect) else { return nil }
            let centered = Self.center(pixels)
            let magnitude = sqrt(centered.reduce(0) { $0 + $1 * $1 })
            guard magnitude / sqrt(Double(centered.count)) >= Self.minimumContrast else { return nil }
            self.normalizedRect = normalizedRect
            self.centeredPixels = centered
            self.magnitude = magnitude
        }

        func isVisible(png: Data) -> Bool? {
            guard let pixels = Self.pixels(png: png, normalizedRect: normalizedRect) else { return nil }
            let centered = Self.center(pixels)
            let magnitude = sqrt(centered.reduce(0) { $0 + $1 * $1 })
            guard magnitude / sqrt(Double(centered.count)) >= Self.minimumContrast else { return false }
            let dot = zip(centeredPixels, centered).reduce(0) { $0 + $1.0 * $1.1 }
            return dot / (self.magnitude * magnitude) >= Self.minimumCorrelation
        }

        private static func center(_ pixels: [Double]) -> [Double] {
            let mean = pixels.reduce(0, +) / Double(pixels.count)
            return pixels.map { $0 - mean }
        }

        private static func pixels(png: Data, normalizedRect: CGRect) -> [Double]? {
            guard normalizedRect.width > 0, normalizedRect.height > 0,
                CGRect(x: 0, y: 0, width: 1, height: 1).contains(normalizedRect),
                let source = CGImageSourceCreateWithData(png as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                let crop = image.cropping(
                    to: CGRect(
                        x: normalizedRect.minX * CGFloat(image.width),
                        y: normalizedRect.minY * CGFloat(image.height),
                        width: normalizedRect.width * CGFloat(image.width),
                        height: normalizedRect.height * CGFloat(image.height)
                    ).integral)
            else { return nil }
            var bytes = [UInt8](repeating: 0, count: edgePixels * edgePixels)
            let didDraw = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: edgePixels, height: edgePixels,
                        bitsPerComponent: 8, bytesPerRow: edgePixels,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                    )
                else { return false }
                context.interpolationQuality = .high
                context.draw(crop, in: CGRect(x: 0, y: 0, width: edgePixels, height: edgePixels))
                return true
            }
            return didDraw ? bytes.map(Double.init) : nil
        }
    }

    enum AssertionError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text):
                return text
            }
        }
    }

    private static let marks = ["A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8"]
    private static let expectedExif: [String: String?] = [
        "A1": "Fixture 1",
        "A2": nil,
        "A3": "Fixture 3",
        "A4": nil,
        "A5": "Fixture 5",
        "A6": nil,
        "A7": "Fixture 7",
        "A8": nil
    ]
    private static let keyColors: [String: Set<String>] = [
        "A1": ["green", "purple"],
        "A2": ["green", "gray"],
        "A3": ["magenta", "brown"],
        "A4": ["blue", "brown"],
        "A5": ["green", "blue"],
        "A6": ["purple"],
        "A7": ["purple"],
        "A8": ["purple"]
    ]
    // RGB pairs keep old-photo hue mixtures from being read as new B photos.
    private static let extendedPalettes: [String: [[Int]]] = [
        "A6": [[180, 120, 250], [215, 120, 250]],
        "A7": [[235, 100, 210], [235, 100, 175]],
        "A8": [[255, 75, 255], [255, 75, 220]]
    ]
    private static let extendedPaletteChannelTolerance = 12
    // Kept in sync with Python DISPLAY_REGION_BOXES. top/upper cover the case where motion cropping of the upper half
    // makes top_half scan as TRANSITION.
    static let displayRegionBoxes: [(name: String, box: (CGFloat, CGFloat, CGFloat, CGFloat))] = [
        ("center", (0.28, 0.18, 0.72, 0.82)),
        ("left", (0.0, 0.12, 0.18, 0.82)),
        ("right", (0.82, 0.12, 1.0, 0.82)),
        ("top", (0.20, 0.02, 0.80, 0.16)),
        ("upper", (0.0, 0.0, 1.0, 0.40)),
        ("mid_left", (0.18, 0.20, 0.42, 0.80)),
        ("mid_right", (0.58, 0.20, 0.82, 0.80)),
        ("top_half", (0.0, 0.0, 1.0, 0.50)),
        ("bottom_half", (0.0, 0.50, 1.0, 1.0))
    ]
    // Mirror Python's public palette rectangles; SmartFill slots need not divide the canvas equally.
    private static let captureSampleWidthPixels = 480
    private static let captureEdgeBandRawPixels = 8
    private static let textureMaximumCellDriftPixels = 2
    private static let captureInnerBox: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.28, 0.18, 0.72, 0.82)
    private static let capturePalettes: [String: [[Int]]] = [
        "A1": [[37, 109, 19], [91, 61, 91]],
        "A2": [[74, 170, 38], [128, 122, 110]],
        "A3": [[111, 51, 57], [165, 3, 129]],
        "A4": [[22, 64, 148], [148, 112, 76]],
        "A5": [[5, 173, 95], [59, 125, 167]]
    ].merging(extendedPalettes) { first, _ in first }
    private static let minDisplayCropEdgePixels = 8
    private static let sampleWidthPixels: Int = 96
    private static let minimumSampleHeightPixels: Int = 8
    private static let pixelChannelCount: Int = 4
    private static let observedRowFraction: Double = 0.86
    private static let observedColumnFraction: Double = 0.85
    private static let overlayLeftFraction: Double = 0.72
    private static let overlayBottomFraction: Double = 0.22
    private static let redLuminanceWeight: Double = 0.299
    private static let greenLuminanceWeight: Double = 0.587
    private static let blueLuminanceWeight: Double = 0.114
    private static let maximumChannelValue: Double = 255.0
    private static let minimumColorLuminance: Double = 0.035
    private static let maximumColorLuminance: Double = 0.94
    private static let minimumColorSaturation: Double = 0.16
    private static let greenHueRange: ClosedRange<Double> = 70...170
    private static let blueHueRange: ClosedRange<Double> = 185...255
    private static let purpleHueRange: ClosedRange<Double> = 265...345
    private static let brownHueRange: ClosedRange<Double> = 8...50
    private static let minimumMagentaSaturation: Double = 0.35
    private static let maximumMagentaLuminance: Double = 0.55
    private static let minimumChromaticPixelCount: Int = 18
    private static let maximumBlackLuminance: Double = 0.10
    private static let minimumBlankLuminance: Double = 0.86
    private static let fixtureA1BalanceBonus: Double = 0.15
    private static let fixtureA2GreenBonus: Double = 0.12
    private static let fixtureA2MagentaPenalty: Double = 0.55
    private static let fixtureA2BluePenalty: Double = 0.40
    private static let fixtureA2BrownPenalty: Double = 0.20
    private static let fixtureA3MagentaBonus: Double = 0.20
    private static let fixtureA4BlueBonus: Double = 0.15
    private static let fixtureA5BlueBonus: Double = 0.12
    private static let fixtureA5BrownPenalty: Double = 0.45
    private static let fixtureA5MagentaPenalty: Double = 0.25
    private static let maximumDarkWashLuminance: Double = 0.30
    private static let minimumDarkWashGrayFraction: Double = 0.60
    private static let minimumMatchScore: Double = 0.045
    private static let minimumMixedSecondScore: Double = 0.05
    private static let closeScoreRatio: Double = 1.18
    private static let maximumCloseScoreDifference: Double = 0.035

    static func overlayModel(from overlayText: String) -> String? {
        for model in ["Fixture 1", "Fixture 3", "Fixture 5", "Fixture 7"] where overlayText.contains(model) {
            return model
        }
        return nil
    }

    static func classify(png: Data) -> Result {
        classify(png: png, shouldQualifySinglePhoto: true)
    }

    static func classifyRejectionEvidence(png: Data) -> Result {
        classify(png: png, shouldQualifySinglePhoto: false)
    }

    private static func classify(png: Data, shouldQualifySinglePhoto: Bool) -> Result {
        guard !png.isEmpty,
            let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return Result(status: .unrecognizable, mark: nil, scores: [:], meanLuma: 0, notes: ["unreadable"])
        }
        let sampleHeightPixels = max(
            minimumSampleHeightPixels,
            Int((Double(sampleWidthPixels) * Double(image.height) / Double(max(1, image.width))).rounded(.down)))
        var pixels = [UInt8](repeating: 0, count: sampleWidthPixels * sampleHeightPixels * pixelChannelCount)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                let context = CGContext(
                    data: base,
                    width: sampleWidthPixels,
                    height: sampleHeightPixels,
                    bitsPerComponent: 8,
                    bytesPerRow: sampleWidthPixels * pixelChannelCount,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                return false
            }
            context.interpolationQuality = .low
            context.translateBy(x: 0, y: CGFloat(sampleHeightPixels))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidthPixels, height: sampleHeightPixels))
            return true
        }
        guard didDraw else {
            return Result(status: .unrecognizable, mark: nil, scores: [:], meanLuma: 0, notes: ["undrawn"])
        }

        var counts: [String: Int] = [
            "green": 0, "gray": 0, "magenta": 0, "blue": 0, "brown": 0, "purple": 0
        ]
        var extendedCounts = extendedPalettes.mapValues { _ in [0, 0] }
        var lumaSum = 0.0
        var chromatic = 0
        let observed = max(
            1, Int(Double(sampleWidthPixels * sampleHeightPixels) * observedRowFraction * observedColumnFraction))
        for row in 0..<sampleHeightPixels {
            if row > Int(Double(sampleHeightPixels) * observedRowFraction) { continue }
            for col in 0..<sampleWidthPixels {
                if col > Int(Double(sampleWidthPixels) * overlayLeftFraction)
                    && row < Int(Double(sampleHeightPixels) * overlayBottomFraction)
                {
                    continue
                }
                let offset = (row * sampleWidthPixels + col) * pixelChannelCount
                let red = Double(pixels[offset])
                let green = Double(pixels[offset + 1])
                let blue = Double(pixels[offset + 2])
                let luma =
                    (redLuminanceWeight * red + greenLuminanceWeight * green + blueLuminanceWeight * blue)
                    / maximumChannelValue
                lumaSum += luma
                if luma < minimumColorLuminance || luma > maximumColorLuminance { continue }
                let channels = [Int(red), Int(green), Int(blue)]
                for (mark, palette) in extendedPalettes {
                    for (index, reference) in palette.enumerated()
                    where zip(channels, reference).allSatisfy({ pair in
                        abs(pair.0 - pair.1) <= extendedPaletteChannelTolerance
                    }) {
                        extendedCounts[mark, default: [0, 0]][index] += 1
                    }
                }
                let (hue, saturation) = hueSaturation(red: red, green: green, blue: blue)
                if saturation < minimumColorSaturation || hue == nil {
                    counts["gray", default: 0] += 1
                    chromatic += 1
                    continue
                }
                guard let hue else { continue }
                if greenHueRange.contains(hue) {
                    counts["green", default: 0] += 1
                } else if blueHueRange.contains(hue) {
                    counts["blue", default: 0] += 1
                } else if purpleHueRange.contains(hue) {
                    if saturation > minimumMagentaSaturation && luma < maximumMagentaLuminance {
                        counts["magenta", default: 0] += 1
                    } else {
                        counts["purple", default: 0] += 1
                    }
                } else if brownHueRange.contains(hue) {
                    counts["brown", default: 0] += 1
                } else {
                    continue
                }
                chromatic += 1
            }
        }
        let meanLuma = lumaSum / Double(observed)
        if chromatic < minimumChromaticPixelCount {
            if meanLuma < maximumBlackLuminance {
                return Result(status: .black, mark: nil, scores: [:], meanLuma: meanLuma, notes: ["low-chroma-dark"])
            }
            if meanLuma > minimumBlankLuminance {
                return Result(status: .blank, mark: nil, scores: [:], meanLuma: meanLuma, notes: ["low-chroma-bright"])
            }
            return Result(status: .unrecognizable, mark: nil, scores: [:], meanLuma: meanLuma, notes: ["low-chroma"])
        }
        let total = Double(chromatic)
        let fraction = counts.mapValues { Double($0) / total }
        let green = fraction["green"] ?? 0
        let gray = fraction["gray"] ?? 0
        let magenta = fraction["magenta"] ?? 0
        let blue = fraction["blue"] ?? 0
        let brown = fraction["brown"] ?? 0
        let purple = fraction["purple"] ?? 0
        let scores: [String: Double] = [
            "A1": min(green, purple) + fixtureA1BalanceBonus * min(green, purple),
            "A2": max(
                0,
                min(green, gray) + fixtureA2GreenBonus * green - fixtureA2MagentaPenalty * magenta
                    - fixtureA2BluePenalty * blue - fixtureA2BrownPenalty * brown),
            "A3": min(magenta, brown) + fixtureA3MagentaBonus * magenta,
            "A4": min(blue, brown) + fixtureA4BlueBonus * blue,
            "A5": max(
                0,
                min(green, blue) + fixtureA5BlueBonus * blue - fixtureA5BrownPenalty * brown
                    - fixtureA5MagentaPenalty * magenta),
            "A6": Double(extendedCounts["A6"]!.min()!) / total,
            "A7": Double(extendedCounts["A7"]!.min()!) / total,
            "A8": Double(extendedCounts["A8"]!.min()!) / total
        ]
        let ranked = scores.sorted { $0.value > $1.value }
        let best = ranked[0]
        let second = ranked[1]
        let notes = [
            String(format: "luma=%.3f", meanLuma),
            String(format: "best=%@:%0.3f", best.key, best.value),
            String(format: "second=%@:%0.3f", second.key, second.value)
        ]
        // The dark blurred background of an empty result has some blue/brown noise; a gray wash must not read as A4.
        if meanLuma <= maximumDarkWashLuminance && gray >= minimumDarkWashGrayFraction {
            return Result(
                status: .unrecognizable,
                mark: nil,
                scores: scores,
                meanLuma: meanLuma,
                notes: notes + ["dark-gray-wash"]
            )
        }
        if best.value < minimumMatchScore {
            return Result(status: .unrecognizable, mark: nil, scores: scores, meanLuma: meanLuma, notes: notes)
        }
        let isMixed =
            second.value >= minimumMixedSecondScore
            && Set(keyColors[best.key] ?? []).isDisjoint(with: keyColors[second.key] ?? [])
        let isClose =
            second.value > 0 && best.value < second.value * closeScoreRatio
            && (best.value - second.value) < maximumCloseScoreDifference
        if isMixed || isClose {
            return Result(status: .transition, mark: nil, scores: scores, meanLuma: meanLuma, notes: notes)
        }
        if shouldQualifySinglePhoto && ["A1", "A2"].contains(best.key) {
            let candidates = singlePhotoCandidates(image: image)
            if candidates.count > 1 {
                return Result(
                    status: .transition, mark: nil, scores: scores, meanLuma: meanLuma,
                    notes: notes + ["multiple-public-candidates"])
            }
            guard let candidate = candidates.first, (scores[candidate] ?? 0) >= minimumMatchScore else {
                return Result(
                    status: .unrecognizable, mark: nil, scores: scores, meanLuma: meanLuma,
                    notes: notes + ["unsupported-public-candidate"])
            }
            return Result(status: .match, mark: candidate, scores: scores, meanLuma: meanLuma, notes: notes)
        }
        return Result(status: .match, mark: best.key, scores: scores, meanLuma: meanLuma, notes: notes)
    }

    private static func singlePhotoCandidates(image: CGImage) -> [String] {
        // Palette proof uses encoded RGB, matching Python; display color conversion changes tagged video channels.
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        guard let frame = capturePixels(image: image, colorSpace: colorSpace) else { return [] }
        let colors = paletteColors(frame: frame)
        // Mirror PUBLIC_SCENE_GEOMETRIES' shared color/glyph box, never a glyph-only
        // phone box or an inferred landscape geometry. Cropped inputs grant no mask.
        let exclusion: CGRect? =
            image.width == 3840 && image.height == 2160
            ? CGRect(
                x: floor(1256 * Double(frame.width) / 3840), y: floor(1436 * Double(frame.height) / 2160),
                width: ceil(2580 * Double(frame.width) / 3840) - floor(1256 * Double(frame.width) / 3840),
                height: ceil(1925 * Double(frame.height) / 2160) - floor(1436 * Double(frame.height) / 2160)) : nil
        return ["A1", "A2"].filter { mark in
            guard let foreground = sharpPublicForeground(frame: frame, colors: colors, mark: mark, exclusion: exclusion)
            else { return false }
            var counts = [0, 0]
            for (index, color) in foreground.colors.enumerated() {
                if foreground.exclusion?.contains(
                    CGPoint(x: index % foreground.frame.width, y: index / foreground.frame.width)) == true
                {
                    continue
                }
                if let (observed, index) = color, observed == mark { counts[index] += 1 }
            }
            return counts.min()! >= minimumChromaticPixelCount
                && hasPublicTexture(
                    frame: foreground.frame, colors: foreground.colors, mark: mark, exclusion: foreground.exclusion)
        }
    }

    private static func paletteColors(frame: (width: Int, height: Int, pixels: [UInt8])) -> [(String, Int)?] {
        var assignments = [Int: (String, Int)]()
        var colors = [(String, Int)?]()
        for offset in stride(from: 0, to: frame.pixels.count, by: pixelChannelCount) {
            let channels = (0..<3).map { Int(frame.pixels[offset + $0]) }
            let key = channels[0] << 16 | channels[1] << 8 | channels[2]
            let assignment: (String, Int)?
            if let cached = assignments[key] {
                assignment = cached.0.isEmpty ? nil : cached
            } else {
                let matches = capturePalettes.flatMap { mark, palette in
                    palette.enumerated().compactMap { index, reference -> (String, Int)? in
                        zip(channels, reference).allSatisfy { abs($0 - $1) <= extendedPaletteChannelTolerance }
                            ? (mark, index) : nil
                    }
                }
                assignment = matches.count == 1 ? matches[0] : nil
                assignments[key] = assignment ?? ("", 0)
            }
            colors.append(assignment)
        }
        return colors
    }

    private static func sharpPublicForeground(
        frame: (width: Int, height: Int, pixels: [UInt8]), colors: [(String, Int)?], mark: String, exclusion: CGRect?
    ) -> (frame: (width: Int, height: Int, pixels: [UInt8]), colors: [(String, Int)?], exclusion: CGRect?)? {
        // Half-resolution capture separates a bilinear footprint from blur. The 96-pixel proof remains below.
        let width = min(frame.width, max(minimumSampleHeightPixels, frame.width / 2))
        let height = max(
            minimumSampleHeightPixels,
            Int((Double(frame.height) * Double(width) / Double(frame.width)).rounded(.toNearestOrEven)))
        let probeExclusion = exclusion.map {
            CGRect(
                x: floor($0.minX * Double(width) / Double(frame.width)),
                y: floor($0.minY * Double(height) / Double(frame.height)),
                width: ceil($0.maxX * Double(width) / Double(frame.width))
                    - floor($0.minX * Double(width) / Double(frame.width)),
                height: ceil($0.maxY * Double(height) / Double(frame.height))
                    - floor($0.minY * Double(height) / Double(frame.height)))
        }
        var probe = [Int?]()
        for row in 0..<height {
            let sourceRow = min(frame.height - 1, Int((Double(row) + 0.5) * Double(frame.height) / Double(height)))
            for column in 0..<width {
                let sourceColumn = min(
                    frame.width - 1, Int((Double(column) + 0.5) * Double(frame.width) / Double(width)))
                let color = colors[sourceRow * frame.width + sourceColumn]
                probe.append(color?.0 == mark ? color?.1 : nil)
            }
        }
        var seeds = [[(Int, Int)]](repeating: [], count: 2)
        var runs = [[(Int, Int, Int)]](repeating: [], count: 2)
        for vertical in [false, true] {
            let axis = vertical ? 1 : 0
            let extent = vertical ? width : height
            let length = vertical ? height : width
            for line in 0..<extent {
                var start: Int?
                var previous: Int?
                var previousPosition: Int?
                var isSharp = false
                var unknownRun = 0
                for position in 0...length {
                    let point = CGPoint(x: vertical ? line : position, y: vertical ? position : line)
                    if probeExclusion?.contains(point) == true {
                        // Neither the overlay nor its opposite edge may provide a sharp seed.
                        if isSharp, let start, let previousPosition {
                            runs[axis].append((line, start, previousPosition + 1))
                        }
                        start = nil
                        previous = nil
                        previousPosition = nil
                        isSharp = false
                        unknownRun = 0
                        continue
                    }
                    let value =
                        position < length ? probe[vertical ? position * width + line : line * width + position] : nil
                    guard let value else {
                        unknownRun += 1
                        if unknownRun > textureMaximumCellDriftPixels || position == length {
                            if isSharp, let start, let previousPosition {
                                runs[axis].append((line, start, previousPosition + 1))
                            }
                            start = nil
                            previous = nil
                            previousPosition = nil
                            isSharp = false
                        }
                        continue
                    }
                    if start == nil { start = position }
                    if let previous, let previousPosition, previous != value {
                        seeds[axis].append(vertical ? (line, previousPosition) : (previousPosition, line))
                        seeds[axis].append(vertical ? (line, position) : (position, line))
                        isSharp = true
                    }
                    previous = value
                    previousPosition = position
                    unknownRun = 0
                }
            }
        }
        guard !seeds[0].isEmpty || !seeds[1].isEmpty else { return nil }
        let vertical = seeds[1]
        let left: Int
        let right: Int
        let top: Int
        let bottom: Int
        if let first = vertical.map(\.0).min(), let last = vertical.map(\.0).max(),
            last - first + 1 >= minimumSampleHeightPixels
        {
            (left, right) = (first, last + 1)
        } else if let first = runs[0].map(\.1).min(), let last = runs[0].map(\.2).max() {
            (left, right) = (first, last)
        } else {
            return nil
        }
        // A stripe touching the blurred side margin is a boundary, not a checker cell.
        let horizontal = seeds[0].filter {
            $0.0 >= left + textureMaximumCellDriftPixels && $0.0 < right - textureMaximumCellDriftPixels
        }
        if let first = horizontal.map(\.1).min(), let last = horizontal.map(\.1).max(),
            last - first + 1 >= minimumSampleHeightPixels
        {
            (top, bottom) = (first, last + 1)
        } else if let first = runs[1].map(\.1).min(), let last = runs[1].map(\.2).max() {
            (top, bottom) = (first, last)
        } else {
            return nil
        }
        guard min(right - left, bottom - top) >= minimumSampleHeightPixels else { return nil }
        let fullSupport = colors.indices.allSatisfy { index in
            colors[index]?.0 == mark || (0..<3).allSatisfy { frame.pixels[index * pixelChannelCount + $0] >= 240 }
        }
        let cropLeft = fullSupport ? 0 : Int((Double(left) + 0.5) * Double(frame.width) / Double(width))
        let cropTop = fullSupport ? 0 : Int((Double(top) + 0.5) * Double(frame.height) / Double(height))
        let cropRight = fullSupport ? frame.width : Int((Double(right) - 0.5) * Double(frame.width) / Double(width)) + 1
        let cropBottom =
            fullSupport ? frame.height : Int((Double(bottom) - 0.5) * Double(frame.height) / Double(height)) + 1
        var pixels = [UInt8]()
        var croppedColors = [(String, Int)?]()
        for row in cropTop..<cropBottom {
            for column in cropLeft..<cropRight {
                let index = row * frame.width + column
                pixels.append(contentsOf: frame.pixels[(index * pixelChannelCount)..<((index + 1) * pixelChannelCount)])
                croppedColors.append(colors[index])
            }
        }
        var croppedWidth = cropRight - cropLeft
        var croppedHeight = cropBottom - cropTop
        var foregroundExclusion = exclusion?.offsetBy(dx: -CGFloat(cropLeft), dy: -CGFloat(cropTop))
        var supported = croppedColors.indices.map { index in
            foregroundExclusion?.contains(CGPoint(x: index % croppedWidth, y: index / croppedWidth)) != true
                && (croppedColors[index]?.0 == mark
                    || (0..<3).allSatisfy { pixels[index * pixelChannelCount + $0] >= 240 })
        }
        let rows = (0..<croppedHeight).filter { row in
            supported[(row * croppedWidth)..<((row + 1) * croppedWidth)].filter { $0 }.count
                >= minimumChromaticPixelCount
        }
        let columns = (0..<croppedWidth).filter { column in
            (0..<croppedHeight).filter { supported[$0 * croppedWidth + column] }.count >= minimumChromaticPixelCount
        }
        guard let firstRow = rows.first, let lastRow = rows.last,
            let firstColumn = columns.first, let lastColumn = columns.last
        else { return nil }
        // A run may touch sparse background pixels; only supported boundary lines belong to its rectangle.
        var trimmedPixels = [UInt8]()
        var trimmedColors = [(String, Int)?]()
        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn {
                let index = row * croppedWidth + column
                trimmedPixels.append(
                    contentsOf: pixels[(index * pixelChannelCount)..<((index + 1) * pixelChannelCount)])
                trimmedColors.append(croppedColors[index])
            }
        }
        foregroundExclusion = foregroundExclusion?.offsetBy(dx: -CGFloat(firstColumn), dy: -CGFloat(firstRow))
        croppedWidth = lastColumn - firstColumn + 1
        croppedHeight = lastRow - firstRow + 1
        guard
            Double(min(croppedWidth, croppedHeight) * width) / Double(frame.width) >= Double(minimumSampleHeightPixels)
        else { return nil }
        pixels = trimmedPixels
        croppedColors = trimmedColors
        supported = croppedColors.indices.map { index in
            foregroundExclusion?.contains(CGPoint(x: index % croppedWidth, y: index / croppedWidth)) != true
                && (croppedColors[index]?.0 == mark
                    || (0..<3).allSatisfy { pixels[index * pixelChannelCount + $0] >= 240 })
        }
        // Complete-slot line support excludes detached patches and thin edges; public white ink is an occlusion.
        for vertical in [false, true] {
            var matches = [Bool]()
            for line in 0..<(vertical ? croppedWidth : croppedHeight) {
                let isOccluded = (0..<(vertical ? croppedHeight : croppedWidth)).allSatisfy { position in
                    foregroundExclusion?.contains(CGPoint(x: vertical ? line : position, y: vertical ? position : line))
                        == true
                }
                // A wholly occluded line is neither evidence nor a missing-photo gap.
                if isOccluded { continue }
                let count = (0..<(vertical ? croppedHeight : croppedWidth)).reduce(0) { count, position in
                    count
                        + (supported[vertical ? position * croppedWidth + line : line * croppedWidth + position]
                            ? 1 : 0)
                }
                matches.append(count >= minimumChromaticPixelCount)
            }
            guard matches.first == true, matches.last == true else { return nil }
            var missing = 0
            for present in matches {
                missing = present ? 0 : missing + 1
                if Double(missing * width) / Double(frame.width) > Double(textureMaximumCellDriftPixels) { return nil }
            }
        }
        // A matching y range alone cannot exempt texture wholly beside the overlay.
        let textureExclusion = foregroundExclusion?.intersection(
            CGRect(x: 0, y: 0, width: croppedWidth, height: croppedHeight))
        return ((croppedWidth, croppedHeight, pixels), croppedColors, textureExclusion)
    }

    private static func hasPublicTexture(
        frame: (width: Int, height: Int, pixels: [UInt8]), colors: [(String, Int)?], mark: String, exclusion: CGRect?
    ) -> Bool {
        // Mirror Python's existing row texture gates inside the independently detected foreground.
        var pattern: String?
        for row in 0..<frame.height {
            var count = [0, 0]
            var hasWhite = false
            var transitions = [Double]()
            var previous: Int?
            var previousX = 0
            var unknownRun = 0
            var maximumUnknownRun = 0
            for column in 0..<frame.width {
                if exclusion?.contains(CGPoint(x: column, y: row)) == true { continue }
                let index = row * frame.width + column
                hasWhite = hasWhite || (0..<3).allSatisfy { frame.pixels[index * pixelChannelCount + $0] >= 240 }
                if let (observedMark, color) = colors[index], observedMark == mark {
                    count[color] += 1
                    if let previous, previous != color { transitions.append(Double(previousX + column) / 2) }
                    previous = color
                    previousX = column
                    unknownRun = 0
                } else {
                    unknownRun += 1
                    maximumUnknownRun = max(maximumUnknownRun, unknownRun)
                }
            }
            guard !hasWhite, Double(count.reduce(0, +)) >= Double(frame.width) * observedColumnFraction else {
                continue
            }
            let observed = count.min()! >= minimumChromaticPixelCount ? "A" : "B"
            if observed == "A", transitions.count >= 2, maximumUnknownRun <= textureMaximumCellDriftPixels,
                !(exclusion.map { $0.minY <= CGFloat(row) && CGFloat(row) < $0.maxY } ?? false)
            {
                let widths = zip(transitions, transitions.dropFirst()).map { $1 - $0 }
                let period = widths.min()!
                if widths.max()! - period > Double(textureMaximumCellDriftPixels)
                    || max(transitions.first!, Double(frame.width - 1) - transitions.last!)
                        > period + Double(textureMaximumCellDriftPixels)
                {
                    return false
                }
            }
            if let pattern, pattern != observed { return false }
            pattern = observed
        }
        guard let pattern else { return false }
        return pattern != "B" || hasSharpPublicStripe(frame: frame, colors: colors, mark: mark, exclusion: exclusion)
    }

    private static func hasSharpPublicStripe(
        frame: (width: Int, height: Int, pixels: [UInt8]), colors: [(String, Int)?], mark: String, exclusion: CGRect?
    ) -> Bool {
        // Use the existing identity scale: display upscaling spreads a sharp source edge over capture pixels.
        let width = min(frame.width, sampleWidthPixels)
        let height = max(
            minimumSampleHeightPixels,
            Int((Double(frame.height) * Double(width) / Double(frame.width)).rounded(.toNearestOrEven)))
        for column in 0..<width {
            let sourceColumn = min(frame.width - 1, Int((Double(column) + 0.5) * Double(frame.width) / Double(width)))
            var previous: Int?
            var unknownRun = 0
            for row in 0..<height {
                let sourceRow = min(frame.height - 1, Int((Double(row) + 0.5) * Double(frame.height) / Double(height)))
                if exclusion?.contains(CGPoint(x: sourceColumn, y: sourceRow)) == true {
                    previous = nil
                    unknownRun = 0
                    continue
                }
                if let (observedMark, color) = colors[sourceRow * frame.width + sourceColumn], observedMark == mark {
                    if let previous, previous != color, unknownRun <= textureMaximumCellDriftPixels {
                        return true
                    }
                    previous = color
                    unknownRun = 0
                } else {
                    unknownRun += 1
                }
            }
        }
        return false
    }

    static func classifyRegions(png: Data, hasReferenceMatchedForeground: Bool = false) -> [String: Result] {
        let full = classify(png: png)
        var regions = ["full": full]
        var completeCandidates: [String]?
        for item in displayRegionBoxes {
            if let cropped = cropPNG(png, box: item.box) {
                // The caller derives this flag only from displayCandidatePNG returning a real reference crop.
                let region = classify(png: cropped, shouldQualifySinglePhoto: false)
                if hasReferenceMatchedForeground, ["A1", "A2"].contains(full.mark ?? ""),
                    region.status == .match, region.mark == full.mark
                {
                    regions[item.name] = region
                } else {
                    let qualified = classify(png: cropped)
                    regions[item.name] = qualified
                    if qualified.status == .unrecognizable, region.status == .match,
                        ["A1", "A2"].contains(region.mark ?? "")
                    {
                        if completeCandidates == nil { completeCandidates = completeSceneCandidates(png: png) }
                        if let inherited = regionFromCompleteScene(
                            png: cropped, region: region, candidates: completeCandidates ?? [])
                        {
                            regions[item.name] = inherited
                        }
                    }
                }
            } else {
                regions[item.name] = Result(
                    status: .unrecognizable,
                    mark: nil,
                    scores: [:],
                    meanLuma: 0,
                    notes: ["crop-failed"]
                )
            }
        }
        return regions
    }

    private static func completeSceneCandidates(png: Data) -> [String] {
        let capture = captureIdentity(png: png)
        let completeMarks = (capture.mark ?? "").split(separator: "+").map(String.init)
        guard capture.status == .match, (2...3).contains(completeMarks.count),
            let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return [] }
        return singlePhotoCandidates(image: image).filter { completeMarks.contains($0) }
    }

    private static func regionFromCompleteScene(png: Data, region: Result, candidates: [String]) -> Result? {
        guard !candidates.isEmpty, let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let frame = capturePixels(
                image: image, colorSpace: image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil })
        else { return nil }
        var counts = Dictionary(uniqueKeysWithValues: marks.map { ($0, [0, 0]) })
        for color in paletteColors(frame: frame) {
            if let (mark, index) = color { counts[mark]![index] += 1 }
        }
        let supported = candidates.filter { mark in
            counts[mark]!.min()! >= minimumChromaticPixelCount
                && !counts.contains { other, count in other != mark && count.reduce(0, +) >= minimumChromaticPixelCount
                }
        }
        guard supported.count == 1, let mark = supported.first, (region.scores[mark] ?? 0) >= minimumMatchScore else {
            return nil
        }
        return Result(
            status: .match, mark: mark, scores: region.scores, meanLuma: region.meanLuma,
            notes: region.notes + ["complete-public-scene-region"])
    }

    static func rejectionRegions(png: Data) -> [String: Result] {
        var regions = ["full": classifyRejectionEvidence(png: png)]
        for item in displayRegionBoxes {
            if let cropped = cropPNG(png, box: item.box) {
                regions[item.name] = classifyRejectionEvidence(png: cropped)
            }
        }
        return regions
    }

    static func captureIdentity(png: Data) -> Result {
        let full = classify(png: png)
        let slotMarks = captureSlotMarks(png: png)
        if slotMarks.count >= 2 {
            return Result(
                status: .match,
                mark: slotMarks.joined(separator: "+"),
                scores: full.scores,
                meanLuma: full.meanLuma,
                notes: ["photo-slot-axis-match"] + full.notes
            )
        }
        return full
    }

    static func assertExifCorrespondence(_ identity: Result, overlayText: String) throws {
        guard identity.status == .match, let mark = identity.mark, expectedExif.keys.contains(mark) else {
            throw AssertionError.message(
                "Can't check EXIF: photo status \(identity.status.rawValue) mark=\(identity.mark ?? "nil")")
        }
        let expected = expectedExif[mark] ?? nil
        let actual = overlayModel(from: overlayText)
        if expected != actual {
            throw AssertionError.message(
                "EXIF does not match the photo: mark=\(mark) expected=\(expected ?? "nil") actual=\(actual ?? "nil")"
            )
        }
    }

    static func assertPauseHold(_ immediate: Result, _ after: Result) throws {
        let marks = try requireMarks([immediate, after], context: "Pause hold")
        if marks[0] != marks[1] {
            throw AssertionError.message("Photo changed after pausing over 10 seconds: \(marks[0]) → \(marks[1])")
        }
    }

    static func assertRequiredFrames(_ present: [String: Bool], required: [String]) throws {
        let missing = required.filter { present[$0] != true }
        if !missing.isEmpty {
            throw AssertionError.message("Window missed or required frames missing: " + missing.joined(separator: ", "))
        }
    }

    static func payload(_ identity: Result) -> [String: Any] {
        [
            "status": identity.status.rawValue,
            "mark": identity.mark ?? NSNull(),
            "mean_luma": identity.meanLuma,
            "notes": identity.notes,
            "scores": identity.scores
        ]
    }

    private static func requireMarks(_ identities: [Result], context: String) throws -> [String] {
        try identities.enumerated().map { index, identity in
            guard identity.status == .match, let mark = identity.mark, marks.contains(mark) else {
                throw AssertionError.message(
                    "\(context) step \(index + 1) cannot be identified: status=\(identity.status.rawValue) mark=\(identity.mark ?? "nil")"
                )
            }
            return mark
        }
    }

    private static func capturePixels(image: CGImage, colorSpace: CGColorSpace? = nil) -> (
        width: Int, height: Int, pixels: [UInt8]
    )? {
        let width = min(captureSampleWidthPixels, image.width)
        let height = max(
            minDisplayCropEdgePixels,
            Int((Double(width) * Double(image.height) / Double(image.width)).rounded(.toNearestOrEven)))
        var pixels = [UInt8](repeating: 0, count: width * height * pixelChannelCount)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * pixelChannelCount, space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return didDraw ? (width, height, pixels) : nil
    }

    private static func captureSlotMarks(png: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            image.width >= minDisplayCropEdgePixels, image.height >= minDisplayCropEdgePixels,
            let frame = capturePixels(image: image)
        else { return [] }
        let (width, height, pixels) = frame
        var paletteCache: [Int: String] = [:]
        var edgeCache: [Int: String] = [:]
        let edgeWidth = captureEdgeBandRawPixels * width / image.width
        let edgeHeight = captureEdgeBandRawPixels * height / image.height
        let assignments: [String] = stride(from: 0, to: pixels.count, by: pixelChannelCount).map { offset in
            let key = Int(pixels[offset]) << 16 | Int(pixels[offset + 1]) << 8 | Int(pixels[offset + 2])
            var mark = paletteCache[key]
            if mark == nil {
                let matches = capturePalettes.compactMap { mark, palette in
                    palette.contains { reference in
                        (0..<3).allSatisfy {
                            abs(Int(pixels[offset + $0]) - reference[$0]) <= extendedPaletteChannelTolerance
                        }
                    } ? mark : nil
                }
                mark = matches.count == 1 ? matches[0] : ""
                paletteCache[key] = mark
            }
            let column = offset / pixelChannelCount % width
            let row = offset / pixelChannelCount / width
            if mark == "",
                column < edgeWidth || column >= width - edgeWidth || row < edgeHeight || row >= height - edgeHeight
            {
                if let cached = edgeCache[key] { return cached }
                let edgeMark = captureEdgeMark((0..<3).map { Double(pixels[offset + $0]) })
                edgeCache[key] = edgeMark
                return edgeMark
            }
            return mark ?? ""
        }
        let markIndices = Dictionary(uniqueKeysWithValues: marks.enumerated().map { ($1, $0) })
        var rowCounts = marks.map { _ in [Int](repeating: 0, count: height) }
        var columnCounts = marks.map { _ in [Int](repeating: 0, count: width) }
        for (index, mark) in assignments.enumerated() {
            if let markIndex = markIndices[mark] {
                rowCounts[markIndex][index / width] += 1
                columnCounts[markIndex][index % width] += 1
            }
        }
        var slots: [(mark: String, rect: CGRect)] = []
        for (markIndex, mark) in marks.enumerated() {
            let rows = (0..<height).filter { rowCounts[markIndex][$0] >= minimumChromaticPixelCount }
            let columns = (0..<width).filter { columnCounts[markIndex][$0] >= minimumChromaticPixelCount }
            if let top = rows.first, let bottom = rows.last, let left = columns.first, let right = columns.last {
                slots.append((mark, CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)))
            }
        }
        guard (2...3).contains(slots.count) else { return [] }
        let canvas = slots.reduce(CGRect.null) { $0.union($1.rect) }
        guard (canvas.width == CGFloat(width) || canvas.height == CGFloat(height)),
            canvas.contains(CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2))
        else { return [] }
        guard isCaptureCanvasTiled(slots.map(\.rect), canvas: canvas, pixels: pixels, width: width),
            !slots.indices.contains(where: { index in
                slots.dropFirst(index + 1).contains { slots[index].rect.intersects($0.rect) }
            }),
            (0..<(width * height)).allSatisfy({ index in
                canvas.contains(CGPoint(x: index % width, y: index / width))
                    || (pixels[index * pixelChannelCount] == 0 && pixels[index * pixelChannelCount + 1] == 0
                        && pixels[index * pixelChannelCount + 2] == 0)
            })
        else { return [] }
        for slot in slots {
            guard isCaptureSlotReadable(assignments, width: width, rect: slot.rect, mark: slot.mark) else { return [] }
            let box = (
                (slot.rect.minX + captureInnerBox.0 * slot.rect.width) / CGFloat(width),
                (slot.rect.minY + captureInnerBox.1 * slot.rect.height) / CGFloat(height),
                (slot.rect.minX + captureInnerBox.2 * slot.rect.width) / CGFloat(width),
                (slot.rect.minY + captureInnerBox.3 * slot.rect.height) / CGFloat(height)
            )
            guard capturePhotoMark(png: png, box: box) == slot.mark else { return [] }
        }
        return slots.sorted {
            $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY
        }.map(\.mark)
    }

    private static func isCaptureCanvasTiled(_ rects: [CGRect], canvas: CGRect, pixels: [UInt8], width: Int) -> Bool {
        if rects.reduce(CGFloat(0), { $0 + $1.width * $1.height }) == canvas.width * canvas.height { return true }
        for y in Int(canvas.minY)..<Int(canvas.maxY) {
            for x in Int(canvas.minX)..<Int(canvas.maxX) {
                let point = CGPoint(x: x, y: y)
                if rects.contains(where: { $0.contains(point) }) { continue }
                // A fractional edge may leave one sampled line, backed by distinct slots immediately on both sides.
                let isBlendedBoundary = [CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)].contains { step in
                    let before = CGPoint(x: point.x - step.x, y: point.y - step.y)
                    let after = CGPoint(x: point.x + step.x, y: point.y + step.y)
                    guard let first = rects.firstIndex(where: { $0.contains(before) }),
                        let second = rects.firstIndex(where: { $0.contains(after) }), first != second
                    else { return false }
                    let index = (y * width + x) * pixelChannelCount
                    let offset = (Int(step.y) * width + Int(step.x)) * pixelChannelCount
                    let a = (0..<3).map { Double(pixels[index - offset + $0]) }
                    let delta = (0..<3).map { Double(pixels[index + offset + $0]) - a[$0] }
                    let color = (0..<3).map { Double(pixels[index + $0]) }
                    let squaredLength = delta.reduce(0.0) { $0 + $1 * $1 }
                    let fraction =
                        squaredLength == 0
                        ? 0.5 : (0..<3).reduce(0.0) { $0 + (color[$1] - a[$1]) * delta[$1] } / squaredLength
                    return fraction > 0 && fraction < 1
                        && (0..<3).allSatisfy {
                            abs(color[$0] - (a[$0] + fraction * delta[$0])) <= Double(extendedPaletteChannelTolerance)
                        }
                }
                if !isBlendedBoundary { return false }
            }
        }
        return true
    }

    private static func captureEdgeMark(_ channels: [Double]) -> String {
        let matches = capturePalettes.compactMap { mark, palette -> String? in
            let first = palette[0].map(Double.init)
            let delta = zip(palette[1], palette[0]).map { Double($0.0 - $0.1) }
            let fraction =
                zip(zip(channels, first), delta).reduce(0.0) { $0 + ($1.0.0 - $1.0.1) * $1.1 }
                / delta.reduce(0.0) { $0 + $1 * $1 }
            guard fraction > 0, fraction < 1,
                (0..<3).allSatisfy({
                    abs(channels[$0] - (first[$0] + fraction * delta[$0])) <= Double(extendedPaletteChannelTolerance)
                })
            else { return nil }
            return mark
        }
        return matches.count == 1 ? matches[0] : ""
    }

    private static func isCaptureSlotReadable(_ assignments: [String], width: Int, rect: CGRect, mark: String) -> Bool {
        for horizontal in [false, true] {
            let lines = horizontal ? Int(rect.minX)..<Int(rect.maxX) : Int(rect.minY)..<Int(rect.maxY)
            let offsets = horizontal ? Int(rect.minY)..<Int(rect.maxY) : Int(rect.minX)..<Int(rect.maxX)
            var matches: [Bool] = []
            for line in lines {
                var counts: [String: Int] = [:]
                for offset in offsets {
                    let observed = assignments[horizontal ? offset * width + line : line * width + offset]
                    if !observed.isEmpty { counts[observed, default: 0] += 1 }
                }
                if counts.contains(where: { $0.key != mark && $0.value >= minimumChromaticPixelCount }) { return false }
                matches.append((counts[mark] ?? 0) >= minimumChromaticPixelCount)
            }
            // Missing interior lines can borrow only from the same independently identified photo on both sides.
            guard matches.first == true, matches.last == true else { return false }
        }
        return true
    }

    private static func capturePhotoMark(
        png: Data,
        box: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> String? {
        guard let cropped = cropPNG(png, box: box) else { return nil }
        // The complete slot already passed the existing RGB/coverage gates.
        let identity = classify(png: cropped, shouldQualifySinglePhoto: false)
        guard identity.status == .match,
            let mark = identity.mark,
            marks.contains(mark)
        else {
            return nil
        }
        return mark
    }

    private static func cropPNG(_ png: Data, box: (CGFloat, CGFloat, CGFloat, CGFloat)) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let left = min(max(box.0, 0), 1) * width
        let top = min(max(box.1, 0), 1) * height
        let right = min(max(box.2, 0), 1) * width
        let bottom = min(max(box.3, 0), 1) * height
        let cropWidth = max(CGFloat(minDisplayCropEdgePixels), right - left)
        let cropHeight = max(CGFloat(minDisplayCropEdgePixels), bottom - top)
        let rect = CGRect(x: left, y: top, width: cropWidth, height: cropHeight)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else {
            return nil
        }
        let encoded = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                encoded,
                "public.png" as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, cropped, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return encoded as Data
    }

    private static func hueSaturation(red: Double, green: Double, blue: Double) -> (Double?, Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        if maximum == 0 { return (nil, 0) }
        let saturation = (maximum - minimum) / maximum
        let rf = red / 255, gf = green / 255, bf = blue / 255
        let mx = max(rf, gf, bf)
        let mn = min(rf, gf, bf)
        let delta = mx - mn
        if delta == 0 { return (nil, saturation) }
        let hue: Double
        if mx == rf {
            hue = ((gf - bf) / delta).truncatingRemainder(dividingBy: 6)
        } else if mx == gf {
            hue = (bf - rf) / delta + 2
        } else {
            hue = (rf - gf) / delta + 4
        }
        let wrapped = hue < 0 ? hue + 6 : hue
        return (wrapped * 60, saturation)
    }
}

enum StrictE2EVisualEvidence {
    enum WriteError: LocalizedError {
        case missingDirectory
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingDirectory:
                return "STRICT_E2E_EVIDENCE_DIR is missing; cannot write photo identity evidence"
            case .writeFailed(let name):
                return "Cannot write evidence \(name)"
            }
        }
    }

    static func directory() -> URL? {
        let path = ProcessInfo.processInfo.environment["STRICT_E2E_EVIDENCE_DIR"] ?? ""
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func writePNG(_ data: Data, name: String) {
        guard let directory = directory() else { return }
        try? data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    static func writeJSON(_ payload: [String: Any], name: String) {
        guard let directory = directory(),
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    // Filter identity evidence must be written to disk; a missing directory must not be skipped silently and
    // mislead Python.
    static func writeRequiredPNG(_ data: Data, name: String) throws {
        guard let directory = directory() else { throw WriteError.missingDirectory }
        do {
            try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        } catch {
            throw WriteError.writeFailed("\(name).png")
        }
    }

    static func writeRequiredJSON(_ payload: [String: Any], name: String) throws {
        guard let directory = directory() else { throw WriteError.missingDirectory }
        guard JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else {
            throw WriteError.writeFailed(name)
        }
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            throw WriteError.writeFailed(name)
        }
    }
}
