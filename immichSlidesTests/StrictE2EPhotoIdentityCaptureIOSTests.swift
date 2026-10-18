#if os(iOS)
import CoreGraphics
import Foundation
import ImageIO
import Testing

@Suite
struct StrictE2EPhotoIdentityCaptureIOSTests {
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
#endif
