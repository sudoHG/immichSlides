// UI regression tests for the tvOS first-launch configuration page.

import XCTest

private enum CapsuleGeometry {
    static let maximumLeadingPositionPoints: CGFloat = 170
    static let maximumTopPositionPoints: CGFloat = 90
}

private enum WaitTiming {
    static let briefElementTimeoutSeconds: TimeInterval = TestWait.seconds(.product(1))
    static let controlAppearanceTimeoutSeconds: TimeInterval = TestWait.seconds(.infrastructure(8))
    static let elementAppearanceTimeoutSeconds: TimeInterval = TestWait.seconds(.product(5))
    static let shortInteractionTimeoutSeconds: TimeInterval = TestWait.seconds(.product(3))
}

#if os(tvOS)
final class ServerConfigFormTVOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try requireTVOSDestination()
    }

    @MainActor
    func testTVOSFirstBootCoreElementsAndDisabledSave() throws {
        let app = launchApp(shouldResetState: true)
        assertFirstBootCoreElements(app: app)

        let saveButton = firstBootSaveButton(in: app)
        XCTAssertTrue(
            saveButton.waitForExistence(
                timeout: TestWait.seconds(.infrastructure(WaitTiming.elementAppearanceTimeoutSeconds))))
        XCTAssertFalse(saveButton.isEnabled, "Before the connection is tested, the save button should stay disabled")

        attachScreenshot(app: app, name: "tvos-firstboot-core-elements-disabled-save")
    }

    @MainActor
    func testTVOSFirstBootAPIKeyHelpSheet() throws {
        let app = launchApp(shouldResetState: true)
        assertFirstBootCoreElements(app: app)

        let helpButton = firstBootAPIKeyHelpButton(in: app)
        let testConnectionButton = firstBootTestConnectionButton(in: app)
        let saveButton = firstBootSaveButton(in: app)
        XCTAssertTrue(
            helpButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "The tvOS first-launch action row should provide a focusable help entry")
        XCTAssertTrue(
            testConnectionButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "The tvOS first-launch action row should provide the Test Connection button")
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "The tvOS first-launch action row should provide the Save Settings button")
        // ui-label-lookup: These assertions verify localized copy after finding each control by identifier.
        XCTAssertEqual(helpButton.label, "需要帮助？")
        XCTAssertEqual(testConnectionButton.label, "测试连接")
        XCTAssertEqual(saveButton.label, "保存配置")
        XCTAssertLessThan(
            helpButton.frame.maxX, testConnectionButton.frame.minX,
            "The tvOS action row should be ordered 'Need Help? / Test Connection / Save Settings'")
        XCTAssertLessThan(
            testConnectionButton.frame.maxX, saveButton.frame.minX,
            "The tvOS action row should be ordered 'Need Help? / Test Connection / Save Settings'")

        let sheet = app.descendants(matching: .any)["server.apiKey.help.sheet"]

        XCUIRemote.shared.press(.down)
        XCTAssertTrue(
            firstBootApiField(in: app).waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "The first-launch page should keep the API Key input row")

        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            sheet.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "After tapping the help entry, the API Key help sheet should be shown")
        let helpTitle = app.staticTexts["server.apiKey.help.sheet"]
        let stepsTitle = app.staticTexts["server.apiKey.help.section.list.number.title"]
        let permissionsTitle = app.staticTexts["server.apiKey.help.section.checklist.title"]
        XCTAssertTrue(helpTitle.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds))
        // ui-label-lookup: These checks verify translated help copy after identifier lookup.
        XCTAssertEqual(helpTitle.label, "如何创建 Immich API Key")
        XCTAssertTrue(stepsTitle.exists)
        XCTAssertEqual(stepsTitle.label, "创建步骤")
        XCTAssertTrue(permissionsTitle.exists)
        XCTAssertEqual(permissionsTitle.label, "需要勾选的权限")
        attachScreenshot(app: app, name: "tvos-firstboot-api-key-help-sheet")

        let closeButton = app.buttons["server.apiKey.help.close.button"]
        XCTAssertTrue(
            closeButton.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "The tvOS help sheet must have a clear close button")
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(
            sheet.waitForExistence(timeout: WaitTiming.briefElementTimeoutSeconds),
            "After closing the help sheet, the app should not stay on the sheet")
        XCTAssertTrue(firstBootApiField(in: app).waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds))
    }

    @MainActor
    func testTVOSFirstBootTestConnectionSelectShowsValidationAlertInline() throws {
        let app = launchApp(shouldResetState: true)
        assertFirstBootCoreElements(app: app)

        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let alert = app.alerts["连接测试失败"]
        XCTAssertTrue(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            alert.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "Select on Test Connection should show the validation alert at once on this page, not only after going back"
        )
        XCTAssertTrue(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            alert.staticTexts["服务器地址必须以 http 或 https 开头\n\n请检查服务器地址和 API Key，确保 Immich 服务器可访问后重试。"].exists
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                || alert.staticTexts["服务器地址格式无效\n\n请检查服务器地址和 API Key，确保 Immich 服务器可访问后重试。"].exists,
            "Testing the connection with an empty form should show the local server address validation error"
        )
    }

    @MainActor
    func testTVOSFirstBootInputCapsulesKeepSameHeightAndWidth() throws {
        let app = launchApp(shouldResetState: true)

        let serverField = firstBootServerField(in: app)
        let apiField = firstBootApiField(in: app)

        XCTAssertTrue(serverField.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(apiField.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))

        let serverFrame = serverField.frame
        let apiFrame = apiField.frame

        XCTAssertLessThanOrEqual(
            abs(serverFrame.height - apiFrame.height), 2.0, "The two input capsules should keep the same height")
        XCTAssertLessThanOrEqual(
            abs(serverFrame.width - apiFrame.width), 2.0, "The two input capsules should keep the same width")

        attachScreenshot(app: app, name: "tvos-firstboot-input-capsule-size-regression")
    }

    @MainActor
    func testTVOSFirstBootDarkModeSnapshot() throws {
        // Launching light and dark back to back is unstable in the full test plan, so light mode has its own test.

        let app = launchApp(shouldResetState: true, colorScheme: "dark")
        assertFirstBootCoreElements(app: app)
        attachScreenshot(app: app, name: "tvos-firstboot-dark-mode")
    }

    @MainActor
    func testTVOSFirstBootLightModeSnapshot() throws {
        // The light first-launch screenshot is a separate test so it is easy to export from the xcresult.

        let app = launchApp(shouldResetState: true, colorScheme: "light")
        assertFirstBootCoreElements(app: app)
        attachScreenshot(app: app, name: "tvos-firstboot-light-mode")
    }

    @MainActor
    func testTVOSFirstBootAccessibilityTextSnapshot() throws {
        // Screenshot evidence for manual review of large-text fit; this test does not assert clipping or overlap.

        let app = launchApp(shouldResetState: true, dynamicTypeSize: "accessibility3")
        assertFirstBootCoreElements(app: app)
        attachScreenshot(app: app, name: "tvos-firstboot-accessibility-text")
    }

    @MainActor
    func testTVOSFirstBootEnglishLocalizationSnapshot() throws {
        let app = launchApp(shouldResetState: true, shouldForceEnglishLocalization: true)
        assertFirstBootCoreElements(
            app: app,
            expectedWizardTitle: "Setup Wizard",
            expectedPageTitle: "Connect to Immich Server"
        )
        attachScreenshot(app: app, name: "tvos-firstboot-english-localization")
    }

    @MainActor
    func testTVOSFirstBootIdleStateCollapsesStatusCard() throws {
        let app = launchApp(shouldResetState: true)
        assertFirstBootCoreElements(app: app)

        let statusCard = app.otherElements["firstboot.status.card"].firstMatch

        XCTAssertFalse(
            statusCard.waitForExistence(timeout: WaitTiming.briefElementTimeoutSeconds),
            "The idle state should not render the status card, or light mode shows an extra blank rectangle"
        )

        attachScreenshot(app: app, name: "tvos-firstboot-idle-state-collapsed-status")
    }

    // Visual coverage for editing long text with the tvOS remote is still a gap.
}

private extension ServerConfigFormTVOSUITests {
    func requireTVOSDestination(file: StaticString = #filePath, line: UInt = #line) throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            throw XCTSkip(
                "The destination is not tvOS (detected: \(UIDevice.current.model)); skipping the tvOS UI test.")
        }
    }

    func launchApp(
        shouldResetState: Bool,
        colorScheme: String? = nil,
        dynamicTypeSize: String? = nil,
        shouldForceEnglishLocalization: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        if shouldResetState {
            app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        }
        if let colorScheme {
            app.launchEnvironment["UI_TEST_COLOR_SCHEME"] = colorScheme
        }
        if let dynamicTypeSize {
            app.launchEnvironment["UI_TEST_DYNAMIC_TYPE_SIZE"] = dynamicTypeSize
        }
        if shouldForceEnglishLocalization {
            app.launchArguments += [
                "-AppleLanguages", "(en)",
                "-AppleLocale", "en_US"
            ]
        }
        app.launch()
        return app
    }

    func firstBootServerField(in app: XCUIApplication) -> XCUIElement {
        let textField = app.textFields["firstboot.serverURL.field"]
        if textField.exists { return textField }
        let fallbackField = app.descendants(matching: .any)["firstboot.serverURL.field"]
        if fallbackField.exists { return fallbackField }
        return app.otherElements["firstboot.serverURL.row"]
    }

    func firstBootApiField(in app: XCUIApplication) -> XCUIElement {
        let secure = app.secureTextFields["firstboot.apiKey.field"]
        if secure.exists { return secure }
        let textField = app.textFields["firstboot.apiKey.field"]
        if textField.exists { return textField }
        let fallbackField = app.descendants(matching: .any)["firstboot.apiKey.field"]
        if fallbackField.exists { return fallbackField }
        return app.otherElements["firstboot.apiKey.row"]
    }

    func firstBootTestConnectionButton(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["firstboot.testConnection.button"]
        if button.exists { return button }
        return app.descendants(matching: .any).matching(identifier: "firstboot.testConnection.button").firstMatch
    }

    func firstBootSaveButton(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["firstboot.saveConfig.button"]
        if button.exists { return button }
        return app.descendants(matching: .any).matching(identifier: "firstboot.saveConfig.button").firstMatch
    }

    func firstBootAPIKeyHelpButton(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["server.apiKey.help.button"]
        if button.exists { return button }
        return app.descendants(matching: .any).matching(identifier: "server.apiKey.help.button").firstMatch
    }

    func attachScreenshot(app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        saveRuntimeScreenshot(screenshot, name: name)
    }

    func saveRuntimeScreenshot(_ screenshot: XCUIScreenshot, name: String) {
        // Optional PNG export for manual review; the XCTAttachment above is always kept.
        let environment = ProcessInfo.processInfo.environment
        guard
            let exportPath = environment["IMMICHSLIDES_SCREENSHOT_EXPORT_DIR"]
                ?? environment["TEST_RUNNER_IMMICHSLIDES_SCREENSHOT_EXPORT_DIR"],
            !exportPath.isEmpty
        else { return }
        let directory = URL(fileURLWithPath: exportPath)
        let safeName = name.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let fileURL = directory.appendingPathComponent("\(safeName).png")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: fileURL, options: .atomic)
        } catch {
            XCTFail("Failed to write runtime screenshot: \(fileURL.path), error: \(error.localizedDescription)")
        }
    }

    func assertFirstBootCoreElements(
        app: XCUIApplication,
        expectedWizardTitle: String = "首次设置向导",
        expectedPageTitle: String = "连接 Immich 服务器"
    ) {
        let wizardTitle = app.staticTexts["onboardingWizard.title"]

        XCTAssertTrue(
            wizardTitle.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "The first-launch page should show the setup progress capsule in the top-left corner")
        XCTAssertEqual(wizardTitle.label, expectedWizardTitle)
        XCTAssertLessThan(
            wizardTitle.frame.minX, CapsuleGeometry.maximumLeadingPositionPoints,
            "The progress capsule should stay in the top-left safe area, not return to the large centered shell")
        XCTAssertLessThan(
            wizardTitle.frame.minY, CapsuleGeometry.maximumTopPositionPoints,
            "The progress capsule should stay in the top-left safe area, not take over the title area")

        let pageTitle = app.staticTexts["firstboot.page.title"]
        XCTAssertTrue(
            pageTitle.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "The first-launch main title should describe the current step, not repeat a welcome or wizard message")
        XCTAssertEqual(pageTitle.label, expectedPageTitle)
        XCTAssertTrue(
            firstBootServerField(in: app).waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(firstBootApiField(in: app).waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(
            firstBootTestConnectionButton(in: app).waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds)
        )
        XCTAssertTrue(
            firstBootSaveButton(in: app).waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
    }
}
#endif
