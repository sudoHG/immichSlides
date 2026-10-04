import XCTest

final class StrictE2ELateImageFocusAuditTests: XCTestCase {
    func testEmptyFocusLinesAreUnidentifiable() {
        XCTAssertNil(StrictE2ELateImageFocusAudit.attachmentBody(fromFocusedLines: []))
        XCTAssertNil(StrictE2ELateImageFocusAudit.attachmentBody(fromFocusedLines: ["", ""]))
    }

    func testFocusedLineIsIdentifiable() {
        let line = "type=9 id=slideshow.control.next.button label=下一张 frame=(0.0, 0.0, 80.0, 80.0)"
        XCTAssertEqual(
            StrictE2ELateImageFocusAudit.attachmentBody(fromFocusedLines: [line]),
            line
        )
    }

    func testKnownIdentifiersCoverLateImageFocusTargets() {
        let identifiers = Set(StrictE2ELateImageFocusAudit.knownIdentifiers)
        for identifier in [
            "slideshow.control.next.button",
            "slideshow.control.playPause.button",
            "slideshow.control.settings.button",
            "firstboot.testConnection.button"
        ] {
            XCTAssertTrue(identifiers.contains(identifier), "Missing focus identifier: \(identifier)")
        }
    }
}
