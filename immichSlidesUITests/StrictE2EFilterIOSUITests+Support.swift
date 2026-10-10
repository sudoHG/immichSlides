import XCTest

#if os(iOS)
extension StrictE2EFilterIOSUITests {
    @MainActor
    func collectVisibleFilterIDs(app: XCUIApplication) -> [String] {
        collectVisibleFilterEvidence(app: app).ids
    }

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
    ) {
        let modeButton = firstBootControl(in: app, identifier: identifier)
        XCTAssertTrue(
            modeButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "Mode page must offer \(identifier).")
        let continueButton = firstBootControl(in: app, identifier: "mode.continue.button")
        // The system Save Password prompt may cover the card late; after handling the named prompt,
        // still prove the target mode is selected.
        _ = waitUntil(timeout: TestWait.seconds(.product(2))) { continueButton.exists && continueButton.isEnabled }
        for _ in 0..<2 {
            if isSystemSavePasswordPromptVisible(app: app) {
                _ = captureNamedPNG(app: app, name: "mode-selection-password-prompt")
                guard dismissSystemSavePasswordPromptIfPresent(app: app, timeout: TestWait.seconds(.infrastructure(4)))
                else {
                    XCTFail("The named Save Password prompt must be gone before choosing a mode")
                    return
                }
            }
            if isOnboardingModeSelected(modeButton) { break }
            if waitUntil(
                timeout: TestWait.seconds(.infrastructure(4)), condition: { modeButton.exists && modeButton.isHittable }
            ) {
                modeButton.tap()
            } else {
                let matches = app.buttons.matching(identifier: identifier)
                let frame = modeButton.frame
                let snapshot: [String: Any] = [
                    "identifier": identifier, "button_count": matches.count,
                    "exists": modeButton.exists, "enabled": modeButton.isEnabled,
                    "hittable": modeButton.isHittable, "frame": String(describing: frame),
                    "app_frame": String(describing: app.frame),
                    "password_prompt_visible": isSystemSavePasswordPromptVisible(app: app)
                ]
                if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) {
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                    attachment.name = "mode-card-hit-diagnostic"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                _ = captureNamedPNG(app: app, name: "mode-card-not-hittable")
                guard matches.count == 1, modeButton.exists, modeButton.isEnabled,
                    !isSystemSavePasswordPromptVisible(app: app),
                    frame.width > 0, frame.height > 0, app.frame.contains(frame)
                else {
                    XCTFail("Target mode card must be unique, enabled, fully visible and unobstructed")
                    return
                }
                // When XCTest's hittable flag is wrong, tap only the center of the single visible button;
                // the selection and page checks below still decide the result.
                modeButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            _ = waitUntil(timeout: TestWait.seconds(.product(4))) {
                self.isSystemSavePasswordPromptVisible(app: app) || self.isOnboardingModeSelected(modeButton)
            }
        }
        if isSystemSavePasswordPromptVisible(app: app) {
            _ = captureNamedPNG(app: app, name: "mode-selection-password-prompt")
            guard dismissSystemSavePasswordPromptIfPresent(app: app, timeout: TestWait.seconds(.infrastructure(4)))
            else {
                XCTFail("The named Save Password prompt must be dismissed before Continue on the mode page")
                return
            }
        }
        XCTAssertTrue(
            isOnboardingModeSelected(modeButton),
            "Target mode card must be selected before Continue; do not rely on Continue with the default random mode"
        )
        continueButton.tap()
        // The password prompt may appear only after tapping Continue; resend the blocked Continue once,
        // and only if the prompt was actually dismissed.
        let departureDeadline = Date().addingTimeInterval(TestWait.seconds(.product(8)))
        var didResumeAfterPrompt = false
        while Date() < departureDeadline {
            if isSystemSavePasswordPromptVisible(app: app) {
                _ = captureNamedPNG(app: app, name: "mode-departure-password-prompt")
                guard !didResumeAfterPrompt,
                    dismissSystemSavePasswordPromptIfPresent(app: app, timeout: TestWait.seconds(.infrastructure(4)))
                else {
                    XCTFail("A Save Password prompt shown while leaving the mode page must be dismissed")
                    return
                }
                didResumeAfterPrompt = true
                if modeButton.exists && continueButton.exists {
                    guard isOnboardingModeSelected(modeButton) else {
                        XCTFail("Target mode must stay selected after the prompt goes away")
                        return
                    }
                    continueButton.tap()
                }
            }
            if !modeButton.exists { return }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.1))))
        }
    }

    @MainActor
    func isOnboardingModeSelected(_ modeButton: XCUIElement) -> Bool {
        modeButton.isSelected || modeButton.images["checkmark.circle.fill"].exists
    }

    @MainActor
    func pausePlaybackIfNeeded(app: XCUIApplication) {
        revealPlaybackControls(app: app)
        let playPause = app.buttons["slideshow.control.playPause.button"]
        guard playPause.waitForExistence(timeout: TestWait.seconds(.infrastructure(4))) else { return }
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
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            return false
        }
    }

    @MainActor
    func waitForPlaybackControls(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            let settings = app.buttons["slideshow.control.settings.button"]
            if settings.exists && settings.isHittable { return true }
            app.tap()
            return false
        }
    }

    @MainActor
    func dismissPlaybackEntryHintIfNeeded(app: XCUIApplication) {
        let banner = app.descendants(matching: .any)["slideshow.entryHint.banner"]
        if banner.waitForExistence(timeout: TestWait.seconds(.product(2))) {
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
            testConnectionButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
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
        field.tap()
        clearTextFieldOrFail(field, app: app, evidenceName: evidenceName)
        field.typeText(value)
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
        // Command-A does not always select the whole URL field, so fall back to end-of-field deletes.
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        if !isTextFieldEmpty(field) {
            field.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: .command)
            let remaining = field.value as? String ?? ""
            if !remaining.isEmpty {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: remaining.count))
            }
        }
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
            done.tap()
            return
        }
        // ui-label-lookup: System keyboard submit keys follow the simulator language.
        for label in ["完成", "Done", "next", "Next"] {
            // ui-label-lookup: System keyboard submit keys follow the simulator language.
            let button = app.keyboards.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
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
                button.tap()
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
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
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
