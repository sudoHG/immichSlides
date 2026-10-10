import UIKit
import XCTest

#if os(iOS)
// The pause contract freezes the photo, not the interface (#218). The control bar and the entry hint may appear,
// fade or change while paused, so their pixels are excluded from the comparison and everything else stays exact.
struct PausedChromeFrame {
    let rect: CGRect
    let isControlBar: Bool
}

struct PausedWindowSample {
    let png: Data
    let windowFrame: CGRect
    let chromeFrames: [PausedChromeFrame]
    // Set when the hierarchy could not be read; "no chrome" is only trusted when the dump was parsed completely.
    let chromeProblem: String?
}

struct PausedPhotoPixelComparison {
    let differingPixelCount: Int
    let comparedPixelCount: Int
    let totalPixelCount: Int
    let differingBounds: CGRect?
    let failureReason: String?
    var chromeFrameCount = 0

    var summary: String {
        failureReason.map { "not comparable: \($0)" }
            ?? "chromeFrames=\(chromeFrameCount) differing=\(differingPixelCount) compared=\(comparedPixelCount) of \(totalPixelCount) bounds=\(differingBounds.map { "\($0)" } ?? "none")"
    }
}

extension PlaybackHistoryIOSUITests {
    // The control bar casts a 50 pt shadow (SlideshowControlBarView), so its pixels reach past its buttons.
    // The entry hint has no shadow and is excluded at its own frame.
    static let pausedControlBarMarginPoints: CGFloat = 80
    // A chrome frame that swallows the screen must not let the comparison pass on almost no pixels.
    static let pausedMinimumComparedFraction = 0.5

    // Read from one hierarchy dump: querying elements one by one records a test failure when the bar fades out
    // between the query and the frame read, and a hidden bar is normal here.
    func pausedChromeFrames(app: XCUIApplication) -> (frames: [PausedChromeFrame], problem: String?) {
        let framePattern =
            #"\{\{(-?[0-9.]+), (-?[0-9.]+)\}, \{(-?[0-9.]+), (-?[0-9.]+)\}\}, identifier: '(slideshow\.(?:control|entryHint)\.[^']*)'"#
        let anyChromePattern = #"identifier: 'slideshow\.(?:control|entryHint)\."#
        guard let frameExpression = try? NSRegularExpression(pattern: framePattern),
            let anyChromeExpression = try? NSRegularExpression(pattern: anyChromePattern)
        else { return ([], "chrome patterns do not compile") }
        let dump = app.debugDescription as NSString
        let fullRange = NSRange(location: 0, length: dump.length)
        guard dump.length > 0, dump.contains("identifier:") else {
            return ([], "the hierarchy dump is empty or has no identifiers")
        }
        let matches = frameExpression.matches(in: dump as String, range: fullRange)
        let mentionedCount = anyChromeExpression.numberOfMatches(in: dump as String, range: fullRange)
        guard matches.count == mentionedCount else {
            return ([], "\(mentionedCount) chrome elements in the dump but \(matches.count) frames could be read")
        }
        var frames: [PausedChromeFrame] = []
        for match in matches {
            let numbers = (1...4).compactMap { Double(dump.substring(with: match.range(at: $0))) }
            let identifier = dump.substring(with: match.range(at: 5))
            guard numbers.count == 4, numbers.allSatisfy({ $0.isFinite }), numbers[2] >= 0, numbers[3] >= 0 else {
                return ([], "unreadable frame for \(identifier)")
            }
            guard numbers[2] > 0, numbers[3] > 0 else { continue }
            frames.append(
                PausedChromeFrame(
                    rect: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]),
                    isControlBar: identifier.hasPrefix("slideshow.control.")))
        }
        return (frames, nil)
    }

    // The chrome is read before and after the screenshot, so a bar that fades in or out during it is still covered.
    func capturePausedWindowSample(app: XCUIApplication) -> PausedWindowSample {
        let window = app.windows.firstMatch
        let before = pausedChromeFrames(app: app)
        let png = window.screenshot().pngRepresentation
        let after = pausedChromeFrames(app: app)
        return PausedWindowSample(
            png: png, windowFrame: window.frame, chromeFrames: before.frames + after.frames,
            chromeProblem: before.problem ?? after.problem)
    }

    func comparePausedPhotoPixels(
        _ sample: PausedWindowSample,
        against baseline: PausedWindowSample
    ) -> PausedPhotoPixelComparison {
        func unusable(_ reason: String) -> PausedPhotoPixelComparison {
            PausedPhotoPixelComparison(
                differingPixelCount: 0, comparedPixelCount: 0, totalPixelCount: 0, differingBounds: nil,
                failureReason: reason)
        }
        if let problem = sample.chromeProblem ?? baseline.chromeProblem {
            return unusable("could not read the interface frames: \(problem)")
        }
        guard sample.windowFrame == baseline.windowFrame, sample.windowFrame.width > 0, sample.windowFrame.height > 0
        else {
            return unusable("window frame changed from \(baseline.windowFrame) to \(sample.windowFrame)")
        }
        guard let current = Self.rgbaPixels(of: sample.png), let initial = Self.rgbaPixels(of: baseline.png) else {
            return unusable("a screenshot did not decode")
        }
        guard current.width == initial.width, current.height == initial.height else {
            return unusable("screenshot sizes differ")
        }
        let width = current.width
        let height = current.height
        let scale = CGFloat(width) / sample.windowFrame.width
        guard abs(CGFloat(height) / sample.windowFrame.height - scale) < 0.01 else {
            return unusable("screenshot pixels do not match the window frame at one scale")
        }
        let origin = sample.windowFrame.origin
        let excluded = (sample.chromeFrames + baseline.chromeFrames).map { frame -> CGRect in
            let margin = frame.isControlBar ? Self.pausedControlBarMarginPoints : 0
            return frame.rect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -margin, dy: -margin)
        }
        var differing = 0
        var compared = 0
        var bounds: CGRect?
        for row in 0..<height {
            let yPoint = (CGFloat(row) + 0.5) / scale
            let spans = excluded.filter { $0.minY <= yPoint && yPoint <= $0.maxY }
                .map { rect in
                    max(0, Int((rect.minX * scale).rounded(.down)))..<min(width, Int((rect.maxX * scale).rounded(.up)))
                }
                .filter { !$0.isEmpty }
                .sorted { $0.lowerBound < $1.lowerBound }
            // Compare whole segments between excluded spans first; only a differing segment is scanned per pixel.
            var segmentStart = 0
            for stop in spans.map({ ($0.lowerBound, $0.upperBound) }) + [(width, width)] {
                let segment = segmentStart..<max(segmentStart, stop.0)
                compared += segment.count
                let byteRange = (row * width + segment.lowerBound) * 4..<(row * width + segment.upperBound) * 4
                if current.bytes[byteRange] != initial.bytes[byteRange] {
                    for column in segment {
                        let offset = (row * width + column) * 4
                        guard current.bytes[offset..<offset + 4] != initial.bytes[offset..<offset + 4] else { continue }
                        differing += 1
                        let pixel = CGRect(x: CGFloat(column) / scale, y: CGFloat(row) / scale, width: 1, height: 1)
                        bounds = bounds.map { $0.union(pixel) } ?? pixel
                    }
                }
                segmentStart = max(segmentStart, stop.1)
            }
        }
        let total = width * height
        let tooLittle = Double(compared) < Double(total) * Self.pausedMinimumComparedFraction
        return PausedPhotoPixelComparison(
            differingPixelCount: differing, comparedPixelCount: compared, totalPixelCount: total,
            differingBounds: bounds,
            failureReason: tooLittle
                ? "only \(compared) of \(total) pixels were compared; the excluded interface area is too large" : nil,
            chromeFrameCount: excluded.count)
    }

    private static func rgbaPixels(of png: Data) -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let image = UIImage(data: png)?.cgImage else { return nil }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let isDrawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return isDrawn ? (width, height, bytes) : nil
    }
}
#endif
