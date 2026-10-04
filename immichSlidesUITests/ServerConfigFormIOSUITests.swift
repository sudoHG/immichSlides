// iOS/iPad server form regression tests with the real keyboard.

import XCTest

#if os(iOS)
final class ServerConfigFormIOSUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testIOSSettingsServerURLKeyboardAppearsPromptly() throws {
        let app = try launchConfiguredAppAtModeSelection()
        openServerSettingsFromModeSelection(app: app)

        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 8), "Server settings page should show the URL field")
        tapFieldAndAssertKeyboardAppears(
            serverField,
            app: app,
            timeout: 1.5,
            message: "After tapping the URL field, the keyboard should appear quickly"
        )
    }

    @MainActor
    func testIOSSettingsServerAPIKeyKeyboardAppearsAfterSavedConfig() throws {
        let app = try launchConfiguredAppAtModeSelection()
        openServerSettingsFromModeSelection(app: app)

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 8), "Server settings page should show the API Key field")
        tapFieldAndAssertKeyboardAppears(
            apiKeyField,
            app: app,
            timeout: 2.0,
            message: "With an API Key already saved, tapping the field should open the real keyboard"
        )
    }

    @MainActor
    func testIOSSettingsServerAPIKeyKeyboardAppearsAfterEditingURL() throws {
        let app = try launchConfiguredAppAtModeSelection()
        openServerSettingsFromModeSelection(app: app)

        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 8), "Server settings page should show the URL field")
        tapFieldAndAssertKeyboardAppears(
            serverField,
            app: app,
            timeout: 1.5,
            message: "After tapping the URL field, the keyboard should appear"
        )
        serverField.clearAndType(text: "foo://invalid-host")
        dismissKeyboardIfNeeded(app: app)

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 8), "Server settings page should show the API Key field")
        tapFieldAndAssertKeyboardAppears(
            apiKeyField,
            app: app,
            timeout: 2.0,
            message: "After editing the URL and then tapping API Key, the keyboard should still appear"
        )
    }

    @MainActor
    func testIOSFirstBootServerFieldsKeyboardAppear() throws {
        let app = launchFirstBootApp()

        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 8), "First-launch page should show the URL field")
        tapFieldAndAssertKeyboardAppears(
            serverField,
            app: app,
            timeout: 1.5,
            message: "After tapping the URL field on the first-launch page, the keyboard should appear"
        )
        dismissKeyboardIfNeeded(app: app)

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 8), "First-launch page should show the API Key field")
        tapFieldAndAssertKeyboardAppears(
            apiKeyField,
            app: app,
            timeout: 2.0,
            message: "After tapping the API Key field on the first-launch page, the keyboard should appear"
        )
    }

    private func launchConfiguredAppAtModeSelection() throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        app.launch()

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForExistence(timeout: 12),
            "After injecting the test server config, the app should open the mode selection page"
        )
        return app
    }

    private func launchFirstBootApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        app.launch()
        return app
    }

    private func openServerSettingsFromModeSelection(app: XCUIApplication) {
        startRandomPlaybackFromModeSelection(app: app)
        openSettingsFromSlideshow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.server")
    }

    private func startRandomPlaybackFromModeSelection(app: XCUIApplication) {
        let randomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(randomButton.waitForExistence(timeout: 8), "Mode selection page should show random playback")
        tapElement(randomButton)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 8), "Mode selection page should show Continue")
        XCTAssertTrue(continueButton.isEnabled, "After selecting random playback, Continue should be tappable")
        tapElement(continueButton)

        XCTAssertTrue(
            waitForSlideshowSettingsButton(app: app, timeout: 25),
            "After entering playback, the settings button should be visible"
        )
    }

    private func openSettingsFromSlideshow(app: XCUIApplication) {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(waitForSlideshowSettingsButton(app: app, timeout: 12), "Playback page should show Settings")
        tapElement(settingsButton)
        XCTAssertTrue(waitForAnySettingsRootEntry(app: app, timeout: 8), "Tapping Settings should open settings")
    }

    private func openSettingsSection(app: XCUIApplication, sectionID: String) {
        for attempt in 0..<6 {
            let candidates = [
                app.buttons[sectionID],
                app.staticTexts[sectionID],
                app.otherElements[sectionID]
            ]

            for candidate in candidates where candidate.waitForExistence(timeout: 1) {
                tapElement(candidate)
                return
            }

            let fallback = app.descendants(matching: .any).matching(identifier: sectionID).firstMatch
            if fallback.waitForExistence(timeout: 1) {
                tapElement(fallback)
                return
            }

            // ui-label-lookup: ToggleSidebar is the system-provided sidebar navigation control.
            let toggleSidebarButton = app.buttons["ToggleSidebar"]
            if toggleSidebarButton.exists,
                toggleSidebarButton.isHittable,
                isShowSidebarLabel(toggleSidebarButton.label)
            {
                toggleSidebarButton.tap()
                _ = waitForAnySettingsRootEntry(app: app, timeout: 1.5)
                continue
            }

            if attempt % 2 == 0 {
                app.swipeUp()
            } else {
                app.swipeDown()
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
        let appeared = keyboard.waitForExistence(timeout: timeout)
        if !appeared {
            attachScreenshot(app: app, name: "ios-server-keyboard-missing-\(currentDeviceTag())")
        }
        XCTAssertTrue(appeared, message, file: file, line: line)
        let elapsed = Date().timeIntervalSince(start)
        XCTContext.runActivity(named: "keyboard-appearance-\(String(format: "%.2f", elapsed))s") { _ in }
        if appeared {
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
                keyboardButton.tap()
                if waitUntil(timeout: 1.5, condition: { app.keyboards.count == 0 }) {
                    return
                }
            }

        }

        let appButton = app.buttons["server.keyboard.done.button"]
        if appButton.exists && appButton.isHittable {
            appButton.tap()
            if waitUntil(timeout: 1.5, condition: { app.keyboards.count == 0 }) {
                return
            }
        }

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        _ = waitUntil(timeout: 1.5, condition: { app.keyboards.count == 0 })
    }

    private func waitForSlideshowSettingsButton(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let button = app.buttons["slideshow.control.settings.button"]
        return waitUntil(timeout: timeout) {
            if button.exists && button.isHittable {
                return true
            }
            app.tap()
            return false
        }
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
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
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
        let attachment = XCTAttachment(screenshot: app.screenshot())
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
            self.typeText(text)
            return
        }

        self.tap()
        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)
        self.typeText(deleteString)
        self.typeText(text)
    }
}
#endif
