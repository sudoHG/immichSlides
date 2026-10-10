import UIKit
import XCTest

#if os(iOS)
// The pause contract freezes the photo, not the interface (#218). The control bar and the entry hint may appear,
// fade or change while paused, so their pixels are excluded from the comparison and everything else stays exact.
struct PausedWindowSample {
    let png: Data
    let windowFrame: CGRect
    let chromeFrames: [CGRect]
}

struct PausedPhotoPixelComparison {
    let differingPixelCount: Int
    let comparedPixelCount: Int
    let totalPixelCount: Int
    let differingBounds: CGRect?
    let isComparable: Bool
    var chromeFrameCount = 0

    var summary: String {
        isComparable
            ? "chromeFrames=\(chromeFrameCount) differing=\(differingPixelCount) compared=\(comparedPixelCount) of \(totalPixelCount) bounds=\(differingBounds.map { "\($0)" } ?? "none")"
            : "screenshots are not comparable (decode failure or different size)"
    }
}

extension PlaybackHistoryIOSUITests {
    // The control bar casts a 50 pt shadow (SlideshowControlBarView), so its pixels reach past its buttons.
    static let pausedChromeMarginPoints: CGFloat = 80

    // Read from one hierarchy dump: querying elements one by one records a test failure when the bar fades out
    // between the query and the frame read, and a hidden bar is normal here.
    func pausedChromeFrames(app: XCUIApplication) -> [CGRect] {
        let pattern =
            #"\{\{(-?[0-9.]+), (-?[0-9.]+)\}, \{(-?[0-9.]+), (-?[0-9.]+)\}\}, identifier: '(slideshow\.(?:control|entryHint)\.[^']*)'"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let dump = app.debugDescription as NSString
        return expression.matches(in: dump as String, range: NSRange(location: 0, length: dump.length)).compactMap {
            match in
            let numbers = (1...4).compactMap { Double(dump.substring(with: match.range(at: $0))) }
            guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
            return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        }
    }

    // The chrome is read before and after the screenshot, so a bar that fades in or out during it is still covered.
    func capturePausedWindowSample(app: XCUIApplication) -> PausedWindowSample {
        let window = app.windows.firstMatch
        let before = pausedChromeFrames(app: app)
        let png = window.screenshot().pngRepresentation
        let after = pausedChromeFrames(app: app)
        return PausedWindowSample(png: png, windowFrame: window.frame, chromeFrames: before + after)
    }

    func comparePausedPhotoPixels(
        _ sample: PausedWindowSample,
        against baseline: PausedWindowSample
    ) -> PausedPhotoPixelComparison {
        let unusable = PausedPhotoPixelComparison(
            differingPixelCount: 0, comparedPixelCount: 0, totalPixelCount: 0, differingBounds: nil,
            isComparable: false)
        guard let current = Self.rgbaPixels(of: sample.png), let initial = Self.rgbaPixels(of: baseline.png),
            current.width == initial.width, current.height == initial.height, sample.windowFrame.width > 0
        else { return unusable }
        let width = current.width
        let height = current.height
        let scale = CGFloat(width) / sample.windowFrame.width
        let origin = sample.windowFrame.origin
        let excluded = (sample.chromeFrames + baseline.chromeFrames).map { frame -> CGRect in
            frame.offsetBy(dx: -origin.x, dy: -origin.y)
                .insetBy(dx: -Self.pausedChromeMarginPoints, dy: -Self.pausedChromeMarginPoints)
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
        return PausedPhotoPixelComparison(
            differingPixelCount: differing, comparedPixelCount: compared, totalPixelCount: width * height,
            differingBounds: bounds, isComparable: true, chromeFrameCount: excluded.count)
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
