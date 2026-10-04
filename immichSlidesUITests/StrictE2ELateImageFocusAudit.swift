import XCTest

enum StrictE2ELateImageFocusAudit {
    static let knownIdentifiers = [
        "slideshow.control.next.button",
        "slideshow.control.playPause.button",
        "slideshow.control.settings.button",
        "firstboot.testConnection.button",
        "firstboot.saveConfig.button",
        "firstboot.serverURL.field",
        "firstboot.apiKey.field",
        "mode.random.button",
        "mode.continue.button"
    ]

    // Record only resolved focus descriptions; an empty list means focus is unidentifiable and the caller must fail.
    static func attachmentBody(fromFocusedLines lines: [String]) -> String? {
        let resolvedLines = lines.filter { !$0.isEmpty }
        return resolvedLines.isEmpty ? nil : resolvedLines.joined(separator: "\n")
    }

    static func auditLine(for element: XCUIElement) -> String {
        "type=\(element.elementType.rawValue) id=\(element.identifier) label=\(element.label) frame=\(element.frame)"
    }
}
