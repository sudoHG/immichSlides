import CoreGraphics
import Foundation
import ImageIO
import Testing
import UIKit

// These reader tests run on both iOS and tvOS; keep the existing suite identity for CI routing.
@Suite
struct StrictE2EPhotoIdentityCaptureIOSTests {
    enum ControlBarCaptureCase: CaseIterable, Sendable {
        case lightVisible, darkVisible, lightHidden, darkHidden, blackHidden, flatCalibration
    }

    @Test(arguments: ControlBarCaptureCase.allCases)
    func `control bar capture rejects hidden and flat pixels`(captureCase: ControlBarCaptureCase) throws {
        let isDark = captureCase == .darkVisible || captureCase == .darkHidden
        let isVisible = captureCase == .lightVisible || captureCase == .darkVisible
        let gear = try #require(UIImage(systemName: "gearshape.fill"))
        let button = CGRect(x: 35, y: 610, width: 60, height: 60)
        let normalized = CGRect(
            x: button.minX / 480, y: button.minY / 720, width: button.width / 480, height: button.height / 720)
        func frame(mark: String, hasControl: Bool) throws -> Data {
            try renderPNG(width: 480, height: 720) { context in
                fillSyntheticMark(mark, in: CGRect(x: 0, y: 0, width: 480, height: 720), context: context)
                if hasControl {
                    context.setFillColor(isDark ? UIColor.black.cgColor : UIColor.white.cgColor)
                    context.fill(button)
                    UIGraphicsPushContext(context)
                    gear
                        .withTintColor(isDark ? .white : .black, renderingMode: .alwaysOriginal)
                        .draw(in: button.insetBy(dx: 12, dy: 12))
                    UIGraphicsPopContext()
                }
            }
        }
        let black = try renderPNG(width: 480, height: 720) { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 720))
        }
        let calibrationPNG = try (captureCase == .flatCalibration ? black : frame(mark: "A1", hasControl: true))
        let reference = StrictE2EPhotoIdentity.ControlBarReference(
            png: calibrationPNG, normalizedRect: normalized
        )
        if captureCase == .flatCalibration {
            #expect(reference == nil)
            return
        }
        let calibrated = try #require(reference)
        let observed = try (captureCase == .blackHidden ? black : frame(mark: "A3", hasControl: isVisible))

        #expect(calibrated.isVisible(png: observed) == isVisible)
    }

    @Test
    func `a differently colored top overlay on a single photo does not count as a second photo`() throws {
        let png = try renderPNG(width: 480, height: 720) { context in
            fillSyntheticMark("A5", in: CGRect(x: 0, y: 0, width: 480, height: 720), context: context)
            fillSyntheticMark("A2", in: CGRect(x: 96, y: 14, width: 288, height: 100), context: context)
        }

        let regions = StrictE2EPhotoIdentity.classifyRegions(png: png)
        let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)

        #expect(regions["full"]?.mark == "A5")
        #expect(regions["top"]?.mark == "A2")
        #expect(identity.status == .match)
        #expect(identity.mark == "A5")
    }

    @Test(arguments: ["A1", "A2", "p3-A2"])
    func `portrait single photo needs its public colors and sharp texture`(mark: String) throws {
        let photoMark = mark.hasPrefix("p3-") ? String(mark.dropFirst(3)) : mark
        var png = try renderPNG(width: 480, height: 1040) { context in
            context.setFillColor(color(180, 180, 180))
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 1040))
            context.setFillColor(color(55, 135, 38))
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 1040))
            fillSyntheticMark(photoMark, in: CGRect(x: 0, y: 385, width: 480, height: 270), context: context)
        }
        if mark.hasPrefix("p3-") {
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
            let tagged = try #require(image.copy(colorSpace: space))
            let output = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, tagged, nil)
            try #require(CGImageDestinationFinalize(destination))
            png = output as Data
        }
        for identity in [StrictE2EPhotoIdentity.classify(png: png), StrictE2EPhotoIdentity.captureIdentity(png: png)] {
            #expect(identity.status == .match)
            #expect(identity.mark == photoMark)
        }
    }

    @Test(arguments: [0.4, 0.5, 0.6])
    func `two photos placed side by side keep a composite identity`(share: Double) throws {
        let boundary = 480 * share
        let png = try renderPNG(width: 480, height: 720) { context in
            fillSyntheticMark("A1", in: CGRect(x: 0, y: 0, width: boundary, height: 720), context: context)
            fillSyntheticMark("A3", in: CGRect(x: boundary, y: 0, width: 480 - boundary, height: 720), context: context)
        }

        let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)

        #expect(identity.status == .match)
        #expect(identity.mark == "A1+A3")
    }

    @Test(arguments: [0.4, 0.5, 0.6])
    func `two photos stacked vertically keep a composite identity`(share: Double) throws {
        let boundary = 720 * share
        let png = try renderPNG(width: 480, height: 720) { context in
            fillSyntheticMark("A1", in: CGRect(x: 0, y: 0, width: 480, height: boundary), context: context)
            fillSyntheticMark("A5", in: CGRect(x: 0, y: boundary, width: 480, height: 720 - boundary), context: context)
        }

        let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)

        #expect(identity.status == .match)
        #expect(identity.mark == "A1+A5")
    }

    @Test
    func `shared public frames have the same Swift and Python verdicts`() throws {
        let url = try #require(
            Bundle(for: FixtureBundle.self).url(
                forResource: "public-photo-identity-cases", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode([ParityCase].self, from: Data(contentsOf: url))
        for item in cases {
            let png = try renderPNG(width: item.size[0], height: item.size[1]) { context in
                for slot in item.slots {
                    fillPublicFixture(
                        slot[0], in: CGRect(x: slot[1], y: slot[2], width: slot[3], height: slot[4]),
                        context: context, label: slot[2] > 0 ? item.bottomLabel : nil,
                        glyphOffsetY: item.glyphOffsetY ?? 0)
                }
                for band in item.bands {
                    context.setFillColor(color(CGFloat(band[4]), CGFloat(band[5]), CGFloat(band[6])))
                    context.fill(CGRect(x: band[0], y: band[1], width: band[2], height: band[3]))
                }
            }
            let marks = StrictE2EPhotoIdentity.strictCaptureSlotMarks(png: png)
            #expect(marks == item.marks, "\(item.name)")
            let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
            #expect(identity.status.rawValue == item.capture.status, "\(item.name)")
            #expect(identity.mark == item.capture.mark, "\(item.name)")
            if let notes = item.capture.notes {
                #expect(identity.notes == notes, "\(item.name)")
            }
            let outOfOrder = StrictE2EPhotoIdentity.captureIdentityForOutOfOrderValidator(png: png)
            let expectedOutOfOrder = item.swiftLegacy ?? item.capture
            #expect(outOfOrder.status.rawValue == expectedOutOfOrder.status, "\(item.name)")
            #expect(outOfOrder.mark == expectedOutOfOrder.mark, "\(item.name)")
            if let candidates = item.completeSceneCandidates {
                #expect(StrictE2EPhotoIdentity.completeSceneCandidates(png: png) == candidates, "\(item.name)")
            }
        }
    }

    private final class FixtureBundle {}
    private struct ParityCase: Decodable {
        let name: String
        let size: [Int]
        let slots: [[Int]]
        let bands: [[Int]]
        let marks: [String]
        let glyphOffsetY: Int?
        let bottomLabel: String?
        let capture: CaptureExpectation
        let swiftLegacy: CaptureExpectation?
        let completeSceneCandidates: [String]?
    }

    private struct CaptureExpectation: Decodable {
        let status: String
        let mark: String?
        let notes: [String]?
    }

    @Test(arguments: [1170, 1640])
    func `native public portrait pairs identify every slot`(width: Int) throws {
        let height = width == 1170 ? 2532 : 2360
        for pair in [[3, 2], [2, 1]] {
            let png = try renderPNG(width: width, height: height) { context in
                fillPublicFixture(pair[0], in: CGRect(x: 0, y: 0, width: width, height: height / 2), context: context)
                fillPublicFixture(
                    pair[1], in: CGRect(x: 0, y: height / 2, width: width, height: height - height / 2),
                    context: context)
            }
            let marks = StrictE2EPhotoIdentity.strictCaptureSlotMarks(png: png)
            #expect(marks == pair.map { "A\($0)" })
        }
    }

    @Test(arguments: [false, true])
    func `tagged mosaics preserve encoded proof and non transition legacy verdicts`(isCalibrated: Bool) throws {
        let png = try renderPNG(width: isCalibrated ? 960 : 480, height: 720) { context in
            fillPublicFixture(
                3, in: CGRect(x: 0, y: 0, width: isCalibrated ? 192 : 480, height: isCalibrated ? 720 : 360),
                context: context)
            fillPublicFixture(
                2,
                in: CGRect(
                    x: isCalibrated ? 192 : 0, y: isCalibrated ? 0 : 360,
                    width: isCalibrated ? 768 : 480, height: isCalibrated ? 720 : 360), context: context)
        }
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Encoded RGB stays public; calibrated gamma makes the legacy hue reader see converted colors.
        let space = try #require(
            isCalibrated
                ? CGColorSpace(
                    calibratedRGBWhitePoint: [0.95047, 1, 1.08883], blackPoint: nil, gamma: [5, 1, 5],
                    matrix: [
                        0.4124564, 0.2126729, 0.0193339, 0.3575761, 0.7151522, 0.1191920, 0.1804375, 0.0721750,
                        0.9503041
                    ])
                : CGColorSpace(name: CGColorSpace.displayP3))
        let tagged = try #require(image.copy(colorSpace: space))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, tagged, nil)
        try #require(CGImageDestinationFinalize(destination))
        let marks = StrictE2EPhotoIdentity.strictCaptureSlotMarks(png: output as Data)
        #expect(marks == ["A3", "A2"])
        let identity = StrictE2EPhotoIdentity.captureIdentity(png: output as Data)
        #expect(identity.status == (isCalibrated ? .unrecognizable : .match))
        #expect(identity.mark == (isCalibrated ? nil : "A3+A2"))
    }

    @Test(arguments: [1.15, 1.2, 1.25])
    func `bilinearly enlarged moving fixtures retain their composite identity`(zoom: Double) throws {
        let sources = try [(1, 320, 180), (5, 240, 360)].map { number, width, height in
            let png = try renderPNG(width: width, height: height) { context in
                fillPublicFixture(number, in: CGRect(x: 0, y: 0, width: width, height: height), context: context)
            }
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let enlarged = try sources.enumerated().map { index, image in
            try bilinearFill(image, width: 1170, height: index == 0 ? 1822 : 710, zoom: zoom)
        }
        let png = try renderPNG(width: 1170, height: 2532) { context in
            for (index, image) in enlarged.enumerated() {
                let slot = CGRect(x: 0, y: index == 0 ? 0 : 1822, width: image.width, height: image.height)
                context.saveGState()
                context.interpolationQuality = .none
                context.translateBy(x: 0, y: slot.minY + slot.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: slot)
                context.restoreGState()
            }
        }
        let marks = StrictE2EPhotoIdentity.strictCaptureSlotMarks(png: png)
        #expect(marks == ["A1", "A5"])
    }

    // Explicit bilinear reconstruction avoids CoreGraphics choosing a different upscaling filter on each OS.
    private func bilinearFill(_ image: CGImage, width: Int, height: Int, zoom: Double) throws -> CGImage {
        let source = try #require(image.dataProvider?.data) as Data
        try #require(image.bitsPerPixel == 32)
        let scale = max(Double(width) / Double(image.width), Double(height) / Double(image.height)) * zoom
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let sy = (Double(y) + 0.5 - Double(height) / 2) / scale + Double(image.height) / 2 - 0.5
            let top = max(0, min(image.height - 1, Int(floor(sy))))
            let bottom = min(image.height - 1, top + 1)
            let dy = sy - floor(sy)
            for x in 0..<width {
                let sx = (Double(x) + 0.5 - Double(width) / 2) / scale + Double(image.width) / 2 - 0.5
                let left = max(0, min(image.width - 1, Int(floor(sx))))
                let right = min(image.width - 1, left + 1)
                let dx = sx - floor(sx)
                for channel in 0..<3 {
                    func value(_ column: Int, _ row: Int) -> Double {
                        Double(source[row * image.bytesPerRow + column * 4 + channel])
                    }
                    let upper = value(left, top) * (1 - dx) + value(right, top) * dx
                    let lower = value(left, bottom) * (1 - dx) + value(right, bottom) * dx
                    pixels[(y * width + x) * 4 + channel] = UInt8(
                        (upper * (1 - dy) + lower * dy).rounded(.toNearestOrEven))
                }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test(arguments: [
        "sharp", "sharpB", "third-palette", "missing-glyph", "wrong-digit", "foreign-pattern", "mixed-letter",
        "crossfade"
    ])
    func `public slot evidence rejects mixed or unreadable photos`(defect: String) throws {
        let png = try renderPNG(width: 480, height: 720) { context in
            fillPublicFixture(
                3, in: CGRect(x: 0, y: 0, width: 480, height: 360), context: context,
                label: defect == "sharpB" ? "B3" : "A3", isStriped: defect == "sharpB")
            let isSecondStriped = ["sharpB", "mixed-letter"].contains(defect)
            fillPublicFixture(
                2, in: CGRect(x: 0, y: 360, width: 480, height: 360), context: context,
                label: isSecondStriped ? "B2" : "A2", isStriped: isSecondStriped)
            if defect == "third-palette" {
                context.setFillColor(color(37, 109, 19))
                context.fill(CGRect(x: 0, y: 20, width: 480, height: 8))
            }
            if defect == "missing-glyph" || defect == "wrong-digit" {
                fillPublicFixture(
                    2, in: CGRect(x: 0, y: 360, width: 480, height: 360), context: context,
                    label: defect == "missing-glyph" ? "" : "A1")
            }
            if defect == "foreign-pattern" {
                fillPublicFixture(
                    2, in: CGRect(x: 0, y: 360, width: 480, height: 360), context: context, isStriped: true)
            }
            if defect == "crossfade" {
                context.setAlpha(0.5)
                fillPublicFixture(1, in: CGRect(x: 0, y: 0, width: 480, height: 720), context: context)
            }
        }
        let marks = StrictE2EPhotoIdentity.strictCaptureSlotMarks(png: png)
        if ["sharp", "sharpB"].contains(defect) {
            #expect(marks == ["A3", "A2"])
        } else {
            #expect(marks.isEmpty)
        }
    }

    @Test(arguments: ["sharp", "unknown-band", "boundary", "mixed-boundary", "wide-boundary"])
    func `three photo layouts retain each independently verified slot`(defect: String) throws {
        for orientation in 0..<4 {
            let horizontal = orientation >= 2
            let isReversed = orientation.isMultiple(of: 2) == false
            let isOriginalBandCase = defect == "unknown-band"
            let canvasScale: CGFloat = isOriginalBandCase ? 1.5 : 1
            let png = try renderPNG(width: isOriginalBandCase ? 720 : 480, height: isOriginalBandCase ? 480 : 320) {
                context in
                let gap = defect == "wide-boundary" ? 2 : defect.contains("boundary") ? 1 : 0
                let first = CGRect(
                    x: horizontal && isReversed ? 192 + gap : 0,
                    y: !horizontal && isReversed ? 128 + gap : 0,
                    width: horizontal ? 288 - (isReversed ? gap : 0) : 480,
                    height: horizontal ? 320 : 192 - (isReversed ? gap : 0))
                let second = CGRect(
                    x: horizontal ? (isReversed ? 0 : 288 + gap) : 0,
                    y: horizontal || isReversed ? 0 : 192 + gap,
                    width: horizontal ? 192 - (isReversed ? 0 : gap) : 240,
                    height: horizontal ? 160 : 128 - (isReversed ? 0 : gap))
                let third = CGRect(
                    x: horizontal ? second.minX : 240, y: horizontal ? 160 : second.minY,
                    width: second.width, height: second.height)
                let transform = CGAffineTransform(scaleX: canvasScale, y: canvasScale)
                for (number, rect) in zip([3, 2, 1], [first, second, third]) {
                    fillPublicFixture(number, in: rect.applying(transform), context: context)
                }
                if isOriginalBandCase {
                    let corruptedSlot = second.applying(transform)
                    context.setFillColor(color(0, 255, 255))
                    context.fill(
                        CGRect(
                            x: corruptedSlot.minX + 10, y: corruptedSlot.minY, width: 8, height: corruptedSlot.height))
                }
                if gap > 0 {
                    let boundary = horizontal ? (isReversed ? 192 : 288) : (isReversed ? 128 : 192)
                    context.setFillColor(color(138, 27, 93))
                    context.fill(
                        CGRect(
                            x: horizontal ? boundary : 0, y: horizontal ? 0 : boundary,
                            width: horizontal ? gap : 480, height: horizontal ? 320 : gap))
                    if defect == "mixed-boundary" {
                        // Corrupt only one shared span; the other span must not hide it in the cache.
                        context.setFillColor(color(101, 146, 74))
                        context.fill(
                            CGRect(
                                x: horizontal ? boundary : 360, y: horizontal ? 240 : boundary,
                                width: horizontal ? gap : 120, height: horizontal ? 80 : gap))
                    }
                }
            }
            let marks = StrictE2EPhotoIdentity.strictCaptureSlotMarks(png: png)
            if !["sharp", "boundary"].contains(defect) {
                #expect(marks.isEmpty)
            } else {
                let expected = isReversed ? (horizontal ? "A2+A3+A1" : "A2+A1+A3") : "A3+A2+A1"
                #expect(marks.joined(separator: "+") == expected)
            }
        }
    }

    @Test
    func `next compares every slot without counting rearrangement as a photo change`() throws {
        func frame(_ marks: [Int]) throws -> StrictE2EPhotoIdentity.Result {
            let png = try renderPNG(width: 480, height: 720) { context in
                for (index, mark) in marks.enumerated() {
                    fillPublicFixture(
                        mark, in: CGRect(x: 0, y: index * 720 / marks.count, width: 480, height: 720 / marks.count),
                        context: context)
                }
            }
            return StrictE2EPhotoIdentity.captureIdentity(png: png)
        }
        let before = try #require(frame([3, 2]).navigationMark)
        #expect(try frame([2, 3]).navigationMark == before)
        #expect(try frame([3, 1]).navigationMark != before)
        #expect(try frame([3]).navigationMark == "A3")
        #expect(try frame([2]).navigationMark == "A2")
    }

    // Same public generator as strict_e2e_server._png: 48-pixel cells and centered bitmap ink.
    private func fillPublicFixture(
        _ number: Int, in rect: CGRect, context: CGContext, label: String? = nil, isStriped: Bool = false,
        glyphOffsetY: Int = 0
    ) {
        let glyphs = [
            "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
            "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
            "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
            "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
            "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
            "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
            "5": ["11111", "10000", "10000", "11110", "00001", "00001", "11110"]
        ]
        context.saveGState()
        context.clip(to: rect)
        for y in stride(from: 0, to: Int(rect.height), by: 48) {
            for x in stride(from: 0, to: Int(rect.width), by: 48) {
                let block = (isStriped ? y / 48 : x / 48 + y / 48) % 2
                context.setFillColor(
                    color(
                        CGFloat((number * 37 + block * 54) % 180),
                        CGFloat((number * 61 + (1 - block) * 48) % 180),
                        CGFloat((number * 19 + block * 72) % 180)))
                context.fill(CGRect(x: rect.minX + CGFloat(x), y: rect.minY + CGFloat(y), width: 48, height: 48))
            }
        }
        let scale = max(8, min(Int(rect.width) / 18, Int(rect.height) / 10))
        let origin = CGPoint(
            x: rect.minX + CGFloat((Int(rect.width) - 11 * scale) / 2),
            y: rect.minY + CGFloat((Int(rect.height) - 7 * scale) / 2 + glyphOffsetY))
        context.setFillColor(color(255, 255, 255))
        for (index, key) in (label ?? "A\(number)").map(String.init).enumerated() {
            for (row, text) in glyphs[key]!.enumerated() {
                for (column, bit) in text.enumerated() where bit == "1" {
                    let x = origin.x + CGFloat((index * 6 + column) * scale)
                    let y = origin.y + CGFloat(row * scale)
                    context.fill(CGRect(x: x, y: y, width: CGFloat(scale), height: CGFloat(scale)))
                }
            }
        }
        context.restoreGState()
    }

    private func fillSyntheticMark(_ mark: String, in rect: CGRect, context: CGContext) {
        let colors: (CGColor, CGColor)
        switch mark {
        case "A1":
            colors = (color(37, 109, 19), color(91, 61, 91))
        case "A2":
            colors = (color(74, 170, 38), color(128, 122, 110))
        case "A3":
            colors = (color(111, 51, 57), color(165, 3, 129))
        case "A5":
            colors = (color(5, 173, 95), color(59, 125, 167))
        default:
            preconditionFailure("Unknown synthetic mark: \(mark)")
        }
        context.saveGState()
        context.clip(to: rect)
        let columns = 10
        let rows = 10
        let cellWidth = rect.width / CGFloat(columns)
        let cellHeight = rect.height / CGFloat(rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let color = (row + column).isMultiple(of: 2) ? colors.0 : colors.1
                context.setFillColor(color)
                context.fill(
                    CGRect(
                        x: rect.minX + CGFloat(column) * cellWidth,
                        y: rect.minY + CGFloat(row) * cellHeight,
                        width: cellWidth,
                        height: cellHeight
                    )
                )
            }
        }
        context.restoreGState()
    }

    private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
        CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [red / 255, green / 255, blue / 255, 1]
        )!
    }

    private func renderPNG(width: Int, height: Int, draw: (CGContext) -> Void) throws -> Data {
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw FixtureError.contextUnavailable
        }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        guard let image = context.makeImage() else {
            throw FixtureError.contextUnavailable
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw FixtureError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.encodingFailed
        }
        return output as Data
    }

    private enum FixtureError: Error {
        case contextUnavailable
        case encodingFailed
    }
}
