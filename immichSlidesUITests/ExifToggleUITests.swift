import CoreGraphics
import ImageIO
import XCTest

// E2E-P2-01: EXIF must follow the current photo's metadata (full vs empty) and remain available on a SmartFill
// multi-photo frame.
final class ExifToggleUITests: XCTestCase {
    // Public fixture convention: odd photos carry full EXIF (camera model Fixture N), even photos have empty metadata.
    private static let fullMetadataMarks: Set<String> = ["A1", "A3", "A5"]
    private static let emptyMetadataMarks: Set<String> = ["A2", "A4"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    #if os(iOS)
    @MainActor
    func testExifToggleOwnershipIOS() throws {
        XCUIDevice.shared.orientation = .portrait
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        try runExifFlow(IOSDriver(app: app), input: input)
    }
    #endif

    #if os(tvOS)
    @MainActor
    func testExifToggleOwnershipTVOS() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The tvOS EXIF test must run on a tvOS Simulator.")
            return
        }
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        try runExifFlow(TVDriver(app: app), input: input)
    }
    #endif

    // Toggle EXIF on the same photo so the overlay change cannot be explained by advancing.
    @MainActor
    private func runExifFlow(_ driver: some PlaybackDriver, input: StrictE2EInput) throws {
        let evidence = Evidence()
        driver.launchToPlayback(input: input)
        driver.applyPlaybackSettings([.interval30Seconds, .displayMode(singlePhoto: true), .showExif(true)])
        driver.pause()

        let fullMark = try driver.advance(toAnyOf: Self.fullMetadataMarks)
        try captureExifState("exif-full-on", mark: fullMark, isExifEnabled: true, driver: driver, evidence: evidence)
        let evidenceDirectory = try XCTUnwrap(StrictE2EVisualEvidence.directory())
        let enabledPNG = try Data(contentsOf: evidenceDirectory.appendingPathComponent("exif-full-on.png"))

        driver.applyPlaybackSettings([.showExif(false)])
        XCTAssertTrue(
            Wait.until(timeout: Timing.exifSettleTimeout) {
                ExifOverlayImage.isHidden(comparedWith: enabledPNG, in: driver.app.screenshot().pngRepresentation)
            },
            "After turning EXIF off, the info card in the upper-right area of the public photo must disappear from the screen."
        )
        try captureExifState("exif-off", mark: fullMark, isExifEnabled: false, driver: driver, evidence: evidence)
        let disabledPNG = try Data(contentsOf: evidenceDirectory.appendingPathComponent("exif-off.png"))
        XCTAssertTrue(
            ExifOverlayImage.isHidden(comparedWith: enabledPNG, in: disabledPNG),
            "The required PNG with EXIF off still shows the info card."
        )

        driver.applyPlaybackSettings([.showExif(true)])
        try captureExifState("exif-reenabled", mark: fullMark, isExifEnabled: true, driver: driver, evidence: evidence)

        let emptyMark = try driver.advance(toAnyOf: Self.emptyMetadataMarks)
        try captureExifState("exif-empty", mark: emptyMark, isExifEnabled: true, driver: driver, evidence: evidence)

        driver.applyPlaybackSettings([.displayMode(singlePhoto: false)])
        try driver.advanceToMultiPhotoScene()
        try evidence.capture("exif-smartfill-multi", from: driver.app) { _ in driver.isShowingMultiPhotoScene() }
        // AX on a multi-photo scene may still hold the previous photo's EXIF text; whether the info card is shown is
        // reviewed by a human from this step's PNG.
    }

    // When enabled, wait for the EXIF text; when disabled, only check the screen of the same public photo, so stale AX
    // text cannot cause a false report.
    @MainActor
    private func captureExifState(
        _ name: String,
        mark: String,
        isExifEnabled: Bool,
        driver: some PlaybackDriver,
        evidence: Evidence
    ) throws {
        let expectedModel = isExifEnabled && Self.fullMetadataMarks.contains(mark) ? "Fixture \(mark.dropFirst())" : nil
        if isExifEnabled {
            _ = Wait.until(timeout: Timing.exifSettleTimeout) {
                StrictE2EPhotoIdentity.overlayModel(from: driver.visibleOverlayText()) == expectedModel
            }
        }
        let identity = try evidence.capture(name, from: driver.app) { $0.status == .match && $0.mark == mark }
        if isExifEnabled {
            try StrictE2EPhotoIdentity.assertExifCorrespondence(identity, overlayText: driver.visibleOverlayText())
        }
    }
}

// Public fixtures have no white text in the upper-right area; compare against the same paused frame so invisible stale
// AX text cannot cause a false report.
private enum ExifOverlayImage {
    static func isHidden(comparedWith enabledPNG: Data, in disabledPNG: Data) -> Bool {
        guard let enabled = brightPixelCount(enabledPNG),
            let disabled = brightPixelCount(disabledPNG),
            enabled > 100
        else { return false }
        return disabled * 4 < enabled
    }

    private static func brightPixelCount(_ png: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let region = CGRect(
            x: CGFloat(image.width) * 0.28,
            y: CGFloat(image.height) * 0.015,
            width: CGFloat(image.width) * 0.72,
            height: CGFloat(image.height) * 0.195
        ).integral
        guard let crop = image.cropping(to: region) else { return nil }
        let bytesPerRow = crop.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * crop.height)
        return pixels.withUnsafeMutableBytes { buffer -> Int? in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: crop.width,
                    height: crop.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return nil }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 4).reduce(0) { count, index in
                count + (bytes[index] > 210 && bytes[index + 1] > 210 && bytes[index + 2] > 210 ? 1 : 0)
            }
        }
    }
}
