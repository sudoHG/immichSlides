import XCTest

#if os(iOS)
extension StrictE2EFilterIOSUITests {
    // Observations come only from UI identifiers; never splice in albumB from the manifest.
    @MainActor
    func collectVisibleFilterEvidence(app: XCUIApplication) -> (ids: [String], raw: [String]) {
        var ids: [String] = []
        var raw: [String] = []
        openAlbumFilterFromEditor(app: app)
        _ = waitUntil(timeout: TestWait.seconds(.infrastructure(12))) {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "albumFilter.album.")).count > 0
        }
        let albumIDs = identifiers(in: app, prefix: "albumFilter.album.", suffix: ".button")
        let albumRaw = rawIdentifiers(in: app, prefix: "albumFilter.album.")
        ids.append(contentsOf: albumIDs)
        raw.append(contentsOf: albumRaw)
        returnFromAlbumFilter(app: app)
        openPersonFilterFromEditor(app: app)
        _ = waitUntil(timeout: TestWait.seconds(.infrastructure(12))) {
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "personFilter.person.")
            ).count > 0
        }
        let personIDs = identifiers(in: app, prefix: "personFilter.person.", suffix: ".button")
        let personRaw = rawIdentifiers(in: app, prefix: "personFilter.person.")
        ids.append(contentsOf: personIDs)
        raw.append(contentsOf: personRaw)
        returnFromPersonFilter(app: app)
        return (ids, raw)
    }

    @MainActor
    func rawIdentifiers(in app: XCUIApplication, prefix: String) -> [String] {
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        return query.allElementsBoundByIndex.compactMap { element in
            let identifier = element.identifier
            return identifier.hasPrefix(prefix) ? identifier : nil
        }
    }

    @MainActor
    func identifiers(in app: XCUIApplication, prefix: String, suffix: String) -> [String] {
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        return query.allElementsBoundByIndex.compactMap { element in
            let identifier = element.identifier
            guard identifier.hasPrefix(prefix), identifier.hasSuffix(suffix) else { return nil }
            return String(identifier.dropFirst(prefix.count).dropLast(suffix.count))
        }
    }

    @MainActor
    func chooseOnboardingModeAndContinue(
        app: XCUIApplication,
        identifier: String
    ) -> Date? {
        IOSFirstBootNavigation(app: app).selectModeAndContinue(
            identifier,
            destinationIdentifier: identifier == "mode.filtered.button"
                ? "filterSummary.startPlayback.button" : "slideshow.control.settings.button",
            selectionTimeout: TestWait.seconds(.product(8)) + TestWait.seconds(.product(2))
                + TestWait.seconds(.product(4)) + TestWait.seconds(.product(4))
                + TestWait.seconds(.product(4)),
            departureTimeout: TestWait.seconds(.product(28)))
    }

    @MainActor
    func pausePlaybackIfNeeded(app: XCUIApplication) {
        revealPlaybackControls(app: app)
        let playPause = app.buttons["slideshow.control.playPause.button"]
        guard
            playPause.waitForPublicElement("slideshow.control.playPause.button", timeout: TestWait.seconds(.product(4)))
        else { return }
        if playPauseState(playPause) != "play" {
            tapElement(playPause)
        }
        _ = waitUntil(timeout: TestWait.seconds(.product(4))) { self.playPauseState(playPause) == "play" }
    }

    @MainActor
    func revealPlaybackControls(app: XCUIApplication) {
        _ = waitUntil(timeout: TestWait.seconds(.product(4))) {
            let settings = app.buttons["slideshow.control.settings.button"]
            if settings.exists && settings.isHittable { return true }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tapForFailureEvidence()
            return false
        }
    }

    @MainActor
    func waitForPlaybackControls(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            let settings = app.buttons["slideshow.control.settings.button"]
            if settings.exists && settings.isHittable { return true }
            app.tapForFailureEvidence()
            return false
        }
    }

    @MainActor
    func dismissPlaybackEntryHintIfNeeded(app: XCUIApplication) {
        let banner = app.descendants(matching: .any)["slideshow.entryHint.banner"]
        if banner.waitForFailureEvidence(timeout: TestWait.seconds(.product(2))) {
            tapElement(banner)
            _ = waitUntil(timeout: TestWait.seconds(.product(2))) { !banner.exists }
        }
    }

    @MainActor
    func tapTestConnection(app: XCUIApplication) {
        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(
            testConnectionButton.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "Test Connection must be shown")
        tapElement(testConnectionButton)
    }

    func playPauseState(_ button: XCUIElement) -> String {
        ((button.value as? String) ?? "").lowercased()
    }

    func currentDeviceTag() -> String {
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let orientation = XCUIDevice.shared.orientation.isLandscape ? "landscape" : "portrait"
        return "\(idiom)-\(orientation)"
    }

    @MainActor
    func replaceText(
        in field: XCUIElement,
        app: XCUIApplication,
        with value: String,
        evidenceName: String,
        shouldRequireExactValue: Bool
    ) {
        field.tapForFailureEvidence()
        clearTextFieldOrFail(field, app: app, evidenceName: evidenceName)
        field.typeForFailureEvidence(value)
        guard shouldRequireExactValue else { return }
        let actual = field.value as? String ?? ""
        if actual != value {
            _ = captureNamedPNG(app: app, name: "\(evidenceName)-mismatch")
            XCTFail("After typing, the URL must exactly equal the target; actual \(actual)")
        }
    }

    @MainActor
    func clearTextFieldOrFail(_ field: XCUIElement, app: XCUIApplication, evidenceName: String) {
        if isTextFieldEmpty(field) { return }
        // Native editing avoids the iPad keyboard-shortcut animation wait during server switching.
        field.press(forDuration: TestWait.seconds(.product(1)))
        // ui-label-lookup: System text editing supplies the localized Select All action.
        let selectAllLabels = ["Select All", "全选"]
        let menuItem = app.menuItems.matching(NSPredicate(format: "label IN %@", selectAllLabels)).firstMatch
        let button = app.buttons.matching(NSPredicate(format: "label IN %@", selectAllLabels)).firstMatch
        if menuItem.exists {
            menuItem.tapForFailureEvidence()
        } else if button.exists {
            button.tapForFailureEvidence()
        }
        field.typeForFailureEvidence(XCUIKeyboardKey.delete.rawValue)
        if !isTextFieldEmpty(field) {
            _ = captureNamedPNG(app: app, name: "\(evidenceName)-clear-failed")
            XCTFail("Failed to clear the URL field; read back \(field.value as? String ?? "")")
        }
    }

    func isTextFieldEmpty(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return value.isEmpty
            || value.contains("请输入")
            || value.localizedCaseInsensitiveContains("enter")
    }

    func hasSecureFieldEnteredValue(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return !value.isEmpty && !value.contains("请输入") && !value.localizedCaseInsensitiveContains("api key")
    }

    func commitFocusedInputIfNeeded(app: XCUIApplication) {
        let done = app.buttons["server.keyboard.done.button"]
        if done.exists && done.isHittable {
            done.tapForFailureEvidence()
            return
        }
        // ui-label-lookup: System keyboard submit keys follow the simulator language.
        for label in ["完成", "Done", "next", "Next"] {
            // ui-label-lookup: System keyboard submit keys follow the simulator language.
            let button = app.keyboards.buttons[label]
            if button.exists && button.isHittable {
                button.tapForFailureEvidence()
                return
            }
        }
    }

    func waitForSaveEnabled(app: XCUIApplication, saveButton: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            acceptLocalNetworkPermissionIfNeeded()
            if saveButton.exists && saveButton.isEnabled { return true }
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let alert = app.alerts.firstMatch
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            if alert.exists {
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                let details = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
                XCTFail("Connection test showed a failure alert: \(alert.label) | \(details)")
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.2))))
        }
        return saveButton.exists && saveButton.isEnabled
    }

    func acceptLocalNetworkPermissionIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // ui-label-lookup: The local-network permission alert belongs to iOS.
        for label in ["允许", "Allow"] {
            // ui-label-lookup: The permission action belongs to SpringBoard.
            let button = springboard.alerts.buttons[label]
            if button.exists {
                button.tapForFailureEvidence()
                return
            }
        }
    }

    func firstBootControl(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        return app.descendants(matching: .any)[identifier]
    }

    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tapForFailureEvidence()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapForFailureEvidence()
        }
    }

    func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.1))))
        }
        return condition()
    }
}
#endif
