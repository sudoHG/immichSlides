// iOS/iPad server form regression tests with the real keyboard.

import XCTest

private enum KeyboardGeometry {
    static let dismissalHorizontalFraction: CGFloat = 0.5
    static let dismissalTopFraction: CGFloat = 0.06
}

private enum WaitTiming {
    static let briefElementTimeoutSeconds: TimeInterval = TestWait.seconds(.product(1))
    static let controlAppearanceTimeoutSeconds: TimeInterval = TestWait.seconds(.product(8))
    static let keyboardTransitionTimeoutSeconds: TimeInterval = TestWait.seconds(.product(1.5))
    static let readbackTimeoutSeconds: TimeInterval = TestWait.seconds(.product(2))
    static let screenTransitionTimeoutSeconds: TimeInterval = TestWait.seconds(.product(12))
    static let shortFocusSettleSeconds: TimeInterval = TestWait.seconds(.product(0.15))
}

#if os(iOS)
final class ServerConfigFormIOSUITests: XCTestCase {
    override func invokeTest() {
        FirstFailureContext.reset()
        super.invokeTest()
    }

    override func record(_ issue: XCTIssue) {
        FirstFailureEvidence.record(self, issue: issue)
        super.record(issue)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        FirstFailureOrientation.set(.portrait)
    }

    @MainActor
    func testIOSSettingsServerURLKeyboardAppearsPromptly() throws {
        let app = try launchConfiguredAppAtModeSelection(
            extraLaunchEnvironment: SlideshowControlBarNavigationTestConfiguration.extendedAutoHideLaunchEnvironment)
        openServerSettingsFromModeSelection(app: app)

        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForPublicElement(
                "firstboot.serverURL.field", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Server settings page should show the URL field")
        tapFieldAndAssertKeyboardAppears(
            serverField,
            app: app,
            timeout: WaitTiming.keyboardTransitionTimeoutSeconds,
            message: "After tapping the URL field, the keyboard should appear quickly"
        )
    }

    @MainActor
    func testIOSSettingsServerAPIKeyKeyboardAppearsAfterSavedConfig() throws {
        let app = try launchConfiguredAppAtModeSelection(
            extraLaunchEnvironment: SlideshowControlBarNavigationTestConfiguration.extendedAutoHideLaunchEnvironment)
        openServerSettingsFromModeSelection(app: app)

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForPublicElement(
                "firstboot.apiKey.field", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Server settings page should show the API Key field")
        tapFieldAndAssertKeyboardAppears(
            apiKeyField,
            app: app,
            timeout: WaitTiming.readbackTimeoutSeconds,
            message: "With an API Key already saved, tapping the field should open the real keyboard"
        )
    }

    @MainActor
    func testIOSSettingsServerAPIKeyKeyboardAppearsAfterEditingURL() throws {
        let app = try launchConfiguredAppAtModeSelection(
            extraLaunchEnvironment: SlideshowControlBarNavigationTestConfiguration.extendedAutoHideLaunchEnvironment)
        openServerSettingsFromModeSelection(app: app)

        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForPublicElement(
                "firstboot.serverURL.field", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Server settings page should show the URL field")
        tapFieldAndAssertKeyboardAppears(
            serverField,
            app: app,
            timeout: WaitTiming.keyboardTransitionTimeoutSeconds,
            message: "After tapping the URL field, the keyboard should appear"
        )
        serverField.clearAndType(text: "foo://invalid-host")
        dismissKeyboardIfNeeded(app: app)

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForPublicElement(
                "firstboot.apiKey.field", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Server settings page should show the API Key field")
        tapFieldAndAssertKeyboardAppears(
            apiKeyField,
            app: app,
            timeout: WaitTiming.readbackTimeoutSeconds,
            message: "After editing the URL and then tapping API Key, the keyboard should still appear"
        )
    }

    @MainActor
    func testIOSFirstBootServerFieldsKeyboardAppear() throws {
        let app = launchFirstBootApp()

        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForPublicElement(
                "firstboot.serverURL.field", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "First-launch page should show the URL field")
        tapFieldAndAssertKeyboardAppears(
            serverField,
            app: app,
            timeout: WaitTiming.keyboardTransitionTimeoutSeconds,
            message: "After tapping the URL field on the first-launch page, the keyboard should appear"
        )
        dismissKeyboardIfNeeded(app: app)

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForPublicElement(
                "firstboot.apiKey.field", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "First-launch page should show the API Key field")
        tapFieldAndAssertKeyboardAppears(
            apiKeyField,
            app: app,
            timeout: WaitTiming.readbackTimeoutSeconds,
            message: "After tapping the API Key field on the first-launch page, the keyboard should appear"
        )
    }

    private func launchConfiguredAppAtModeSelection(extraLaunchEnvironment: [String: String] = [:]) throws
        -> XCUIApplication
    {
        let config = try requireTestServerConfig()
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        app.launchEnvironment.merge(extraLaunchEnvironment) { _, new in new }
        app.launchForFailureEvidence()

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForPublicElement(
                "mode.continue.button", timeout: WaitTiming.screenTransitionTimeoutSeconds),
            "After injecting the test server config, the app should open the mode selection page"
        )
        return app
    }

    private func launchFirstBootApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        app.launchForFailureEvidence()
        return app
    }

    private func openServerSettingsFromModeSelection(app: XCUIApplication) {
        startRandomPlaybackFromModeSelection(app: app)
        openSettingsFromSlideshow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.server")
    }

    private func startRandomPlaybackFromModeSelection(app: XCUIApplication) {
        let randomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(
            randomButton.waitForPublicElement(
                "mode.random.button", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Mode selection page should show random playback")
        tapElement(randomButton)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForPublicElement(
                "mode.continue.button", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Mode selection page should show Continue")
        XCTAssertTrue(continueButton.isEnabled, "After selecting random playback, Continue should be tappable")
        tapElement(continueButton)

        XCTAssertTrue(
            waitForSlideshowSettingsButton(app: app, timeout: TestWait.seconds(.product(25))) != nil,
            "After entering playback, the settings button should be visible"
        )
    }

    private func openSettingsFromSlideshow(app: XCUIApplication) {
        let observation = waitForSlideshowSettingsButton(app: app, timeout: WaitTiming.screenTransitionTimeoutSeconds)
        XCTAssertTrue(
            observation != nil,
            "Playback page should show Settings")
        if let observation, let button = observation.button {
            // Reuse the satisfying snapshot instead of resolving an auto-hiding button again.
            observation.windowElement.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(
                    dx: button.frame.midX - observation.windowFrame.minX,
                    dy: button.frame.midY - observation.windowFrame.minY)
            ).tapForFailureEvidence()
        }
        XCTAssertTrue(
            waitForAnySettingsRootEntry(app: app, timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Tapping Settings should open settings")
    }

    private func openSettingsSection(app: XCUIApplication, sectionID: String) {
        for attempt in 0..<6 {
            let candidates = [
                app.buttons[sectionID],
                app.staticTexts[sectionID],
                app.otherElements[sectionID]
            ]

            for candidate in candidates
            where candidate.waitForFailureEvidence(timeout: WaitTiming.briefElementTimeoutSeconds) {
                tapElement(candidate)
                return
            }

            let fallback = app.descendants(matching: .any).matching(identifier: sectionID).firstMatch
            if fallback.waitForFailureEvidence(timeout: WaitTiming.briefElementTimeoutSeconds) {
                tapElement(fallback)
                return
            }

            // ui-label-lookup: ToggleSidebar is the system-provided sidebar navigation control.
            let toggleSidebarButton = app.buttons["ToggleSidebar"]
            if toggleSidebarButton.exists,
                toggleSidebarButton.isHittable,
                isShowSidebarLabel(toggleSidebarButton.label)
            {
                toggleSidebarButton.tapForFailureEvidence()
                _ = waitForAnySettingsRootEntry(app: app, timeout: WaitTiming.keyboardTransitionTimeoutSeconds)
                continue
            }

            if attempt % 2 == 0 {
                app.swipeUpForFailureEvidence()
            } else {
                app.swipeDownForFailureEvidence()
            }
        }

        XCTFail("Could not open settings section: \(sectionID)")
    }

    private func tapFieldAndAssertKeyboardAppears(
        _ field: XCUIElement,
        app: XCUIApplication,
        timeout: TimeInterval,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let start = Date()
        tapElement(field)
        let keyboard = app.keyboards.firstMatch
        let didAppear = keyboard.waitForFailureEvidence(timeout: timeout)
        if !didAppear {
            attachScreenshot(app: app, name: "ios-server-keyboard-missing-\(currentDeviceTag())")
        }
        XCTAssertTrue(didAppear, message, file: file, line: line)
        let elapsed = Date().timeIntervalSince(start)
        XCTContext.runActivity(named: "keyboard-appearance-\(String(format: "%.2f", elapsed))s") { _ in }
        if didAppear {
            attachScreenshot(app: app, name: "Desktop-keyboard-visible-\(currentDeviceTag())")
        }
    }

    private func dismissKeyboardIfNeeded(app: XCUIApplication) {
        guard app.keyboards.count > 0 else { return }

        // ui-label-lookup: These labels address system keyboard action keys.
        let labels = ["完成", "Done", "Return", "Next", "Go", "Search"]
        for label in labels {
            // ui-label-lookup: Keyboard action keys are system-provided controls.
            let keyboardButton = app.keyboards.buttons[label]
            if keyboardButton.exists && keyboardButton.isHittable {
                keyboardButton.tapForFailureEvidence()
                if waitUntil(
                    timeout: WaitTiming.keyboardTransitionTimeoutSeconds, condition: { app.keyboards.count == 0 })
                {
                    return
                }
            }

        }

        let appButton = app.buttons["server.keyboard.done.button"]
        if appButton.exists && appButton.isHittable {
            appButton.tapForFailureEvidence()
            if waitUntil(timeout: WaitTiming.keyboardTransitionTimeoutSeconds, condition: { app.keyboards.count == 0 })
            {
                return
            }
        }

        app.coordinate(
            withNormalizedOffset: CGVector(
                dx: KeyboardGeometry.dismissalHorizontalFraction, dy: KeyboardGeometry.dismissalTopFraction)
        ).tapForFailureEvidence()
        _ = waitUntil(timeout: WaitTiming.keyboardTransitionTimeoutSeconds, condition: { app.keyboards.count == 0 })
    }

    private func waitForSlideshowSettingsButton(app: XCUIApplication, timeout: TimeInterval)
        -> SlideshowControlBarButtonObservation?
    {
        let identifier = "slideshow.control.settings.button"
        var timing = SlideshowControlBarTiming()
        var didReveal = false
        let deadline = Date().addingTimeInterval(timeout)
        defer { print("Server form Settings readiness: \(timing.diagnostic)") }
        while Date() < deadline {
            let observation = timing.observe(app: app, identifier: identifier)
            guard Date() < deadline else { break }
            if let observation, observation.hasPlaybackMarker, !observation.hasSettingsNavigationEvidence {
                if observation.isReady, observation.windowElement.buttons[identifier].isHittable {
                    return observation
                }
                if !didReveal, Date() < deadline {
                    didReveal = true
                    timing.reveal(app: app)
                }
            }
            guard Date() < deadline else { break }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(WaitTiming.shortFocusSettleSeconds)))
        }
        return nil
    }

    private func waitForAnySettingsRootEntry(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            app.buttons["settings.item.playback"].exists || app.otherElements["settings.item.playback"].exists
                || app.staticTexts["settings.item.playback"].exists || app.buttons["settings.item.server"].exists
                || app.otherElements["settings.item.server"].exists || app.staticTexts["settings.item.server"].exists
                || app.buttons["settings.item.cache"].exists || app.otherElements["settings.item.cache"].exists
                || app.staticTexts["settings.item.cache"].exists
                || app.staticTexts["settings.playback.title"].exists
                || app.staticTexts["settings.accessProtection.title"].exists
                || app.staticTexts["settings.server.title"].exists
                || app.staticTexts["settings.cache.title"].exists
                || app.staticTexts["settings.about.title"].exists
        }
    }

    private func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tapForFailureEvidence()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapForFailureEvidence()
        }
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.shortFocusSettleSeconds))
        }
        return condition()
    }

    private func isShowSidebarLabel(_ label: String) -> Bool {
        // ui-label-lookup: These labels are localized system sidebar control text.
        [
            "Show Sidebar",
            "显示边栏",
            "顯示側邊欄",
            "サイドバーを表示",
            "Mostrar barra lateral"
        ].contains(label)
    }

    private func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshotForFailureEvidence())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func currentDeviceTag() -> String {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return "ipad"
        case .phone:
            return "iphone"
        default:
            return "ios"
        }
    }
}

private extension XCUIElement {
    func clearAndType(text: String) {
        guard let existing = self.value as? String else {
            self.typeForFailureEvidence(text)
            return
        }

        self.tapForFailureEvidence()
        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)
        self.typeForFailureEvidence(deleteString)
        self.typeForFailureEvidence(text)
    }
}
#endif
