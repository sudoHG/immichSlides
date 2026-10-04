#if os(iOS)
import CoreGraphics
import Foundation
import ImageIO
import Testing

@Suite
struct StrictE2EPhotoIdentityCaptureTests {
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

    @Test
    func `two photos placed side by side keep a composite identity`() throws {
        let png = try renderPNG(width: 480, height: 720) { context in
            fillSyntheticMark("A1", in: CGRect(x: 0, y: 0, width: 240, height: 720), context: context)
            fillSyntheticMark("A3", in: CGRect(x: 240, y: 0, width: 240, height: 720), context: context)
        }

        let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)

        #expect(identity.status == .match)
        #expect(identity.mark == "A1+A3")
    }

    @Test
    func `two photos stacked vertically keep a composite identity`() throws {
        let png = try renderPNG(width: 480, height: 720) { context in
            fillSyntheticMark("A1", in: CGRect(x: 0, y: 0, width: 480, height: 360), context: context)
            fillSyntheticMark("A5", in: CGRect(x: 0, y: 360, width: 480, height: 360), context: context)
        }

        let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)

        #expect(identity.status == .match)
        #expect(identity.mark == "A1+A5")
    }

    private func fillSyntheticMark(_ mark: String, in rect: CGRect, context: CGContext) {
        let colors: (CGColor, CGColor)
        switch mark {
        case "A1":
            colors = (color(0.05, 0.80, 0.15), color(0.78, 0.60, 0.78))
        case "A2":
            colors = (color(0.05, 0.80, 0.15), color(0.65, 0.65, 0.65))
        case "A3":
            colors = (color(0.85, 0.08, 0.85), color(0.45, 0.24, 0.12))
        case "A5":
            colors = (color(0.05, 0.80, 0.15), color(0.05, 0.45, 0.95))
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
            components: [red, green, blue, 1]
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
