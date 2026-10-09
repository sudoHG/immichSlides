import XCTest

#if os(tvOS)
extension FilterSummaryTVOSVisualUITests {
    func settingsControlCandidates(app: XCUIApplication, identifier: String) -> [XCUIElement] {

        [
            app.buttons[identifier],
            app.otherElements[identifier],
            app.staticTexts[identifier],
            app.textFields[identifier],
            app.secureTextFields[identifier]
        ]
    }

    func waitForElementWithLabelExists(
        app: XCUIApplication,
        label: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {

            // ui-label-lookup: This helper is reserved for assertions about displayed copy and localization.
            if app.buttons[label].exists
                // ui-label-lookup: This helper is reserved for assertions about displayed copy and localization.
                || app.otherElements[label].exists
                // ui-label-lookup: This helper is reserved for assertions about displayed copy and localization.
                || app.staticTexts[label].exists
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                || app.alerts[label].exists
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                || app.alerts.buttons[label].exists
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                || app.alerts.staticTexts[label].exists
            {
                return true
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.pollIntervalSeconds))
        }
        // ui-label-lookup: This helper is reserved for assertions about displayed copy and localization.
        return app.buttons[label].exists
            // ui-label-lookup: This helper is reserved for assertions about displayed copy and localization.
            || app.otherElements[label].exists
            // ui-label-lookup: This helper is reserved for assertions about displayed copy and localization.
            || app.staticTexts[label].exists
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            || app.alerts[label].exists
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            || app.alerts.buttons[label].exists
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            || app.alerts.staticTexts[label].exists
    }

    @MainActor
    func assertTVOSServerSettingsAPIKeyHelpSheet(
        app: XCUIApplication,
        context: String,
        shouldVerifySimplifiedChineseContent: Bool = false,
        screenshotName: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        _ = waitForSettingsControl(
            app: app,
            identifier: "server.apiKey.help.button",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "\(context) should show the API Key help entry",
            file: file,
            line: line
        )

        let sheet = app.descendants(matching: .any)["server.apiKey.help.sheet"]
        // Focus starts on the server URL: API Key -> Test Connection -> Help.

        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.22)))
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.22)))
        XCUIRemote.shared.press(.left)
        waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.22)))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            sheet.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.shortInteractionTimeoutSeconds),
            "\(context) should open the API Key help sheet after the help entry is selected", file: file, line: line)
        if shouldVerifySimplifiedChineseContent {
            let title = app.staticTexts["server.apiKey.help.sheet"]
            let stepsTitle = app.staticTexts["server.apiKey.help.section.list.number.title"]
            let permissionsTitle = app.staticTexts["server.apiKey.help.section.checklist.title"]
            let securityTitle = app.staticTexts["server.apiKey.help.section.key.fill.title"]
            XCTAssertTrue(
                title.waitForExistence(
                    timeout: FilterSummaryTVOSVisualUITestsWaitTiming.shortInteractionTimeoutSeconds),
                "\(context) help sheet should show the title", file: file, line: line)
            // ui-label-lookup: These assertions verify translated help copy after identifier lookup.
            XCTAssertEqual(title.label, "如何创建 Immich API Key", file: file, line: line)
            XCTAssertTrue(
                stepsTitle.waitForExistence(
                    timeout: FilterSummaryTVOSVisualUITestsWaitTiming.shortInteractionTimeoutSeconds),
                "\(context) help sheet should show the creation steps",
                file: file, line: line)
            XCTAssertEqual(stepsTitle.label, "创建步骤", file: file, line: line)
            XCTAssertTrue(
                permissionsTitle.waitForExistence(
                    timeout: FilterSummaryTVOSVisualUITestsWaitTiming.shortInteractionTimeoutSeconds),
                "\(context) help sheet should show the permissions section",
                file: file, line: line)
            XCTAssertEqual(permissionsTitle.label, "需要勾选的权限", file: file, line: line)
            if !securityTitle.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.briefElementTimeoutSeconds)
            {
                XCUIRemote.shared.press(.down)
                waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.22)))
            }
            XCTAssertTrue(
                securityTitle.waitForExistence(
                    timeout: FilterSummaryTVOSVisualUITestsWaitTiming.readbackDeadlineSeconds),
                "\(context) help sheet should show the security reminder",
                file: file, line: line)
            XCTAssertEqual(securityTitle.label, "安全提醒", file: file, line: line)
        }

        if let screenshotName {
            attachScreenshot(app: app, name: screenshotName)
        }

        _ = waitForSettingsControl(
            app: app,
            identifier: "server.apiKey.help.close.button",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.shortInteractionTimeoutSeconds,
            failureMessage: "\(context) help sheet should have a close button",
            file: file,
            line: line
        )
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(
            sheet.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.briefElementDeadlineSeconds),
            "\(context) should not stay on the help sheet after closing",
            file: file, line: line)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "firstboot.serverURL.row",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.shortInteractionTimeoutSeconds)
                || waitForSettingsControlExists(
                    app: app, identifier: "firstboot.serverURL.field",
                    timeout: FilterSummaryTVOSVisualUITestsWaitTiming.shortInteractionTimeoutSeconds),
            "\(context) should return to the server settings form after closing the help sheet",
            file: file,
            line: line
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "firstboot.apiKey.row",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.shortInteractionTimeoutSeconds),
            "\(context) should return to the API Key input row after closing the help sheet",
            file: file,
            line: line
        )
    }

    func waitForSettingsControlExists(
        app: XCUIApplication,
        identifier: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if settingsControlCandidates(app: app, identifier: identifier).contains(where: \.exists) {
                return true
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.pollIntervalSeconds))
        }
        return settingsControlCandidates(app: app, identifier: identifier).contains(where: \.exists)
    }

    func waitForSettingsControl(
        app: XCUIApplication,
        identifier: String,
        timeout: TimeInterval,
        failureMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let matchedElement = settingsControlCandidates(app: app, identifier: identifier).first(where: \.exists) {
                return matchedElement
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.pollIntervalSeconds))
        }

        XCTFail(failureMessage, file: file, line: line)
        return app.otherElements[identifier]
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
        // Optional PNG export for manual review; the XCTAttachment is always kept. Screenshots can show private
        // photos, so the directory must be set explicitly, outside Git, and is created with owner-only permissions.
        let environment = ProcessInfo.processInfo.environment
        let directory: URL
        do {
            guard
                let resolved = try PrivateEvidenceDirectory.resolve(
                    rootPath: environment["IMMICHSLIDES_SCREENSHOT_EXPORT_DIR"]
                        ?? environment["TEST_RUNNER_IMMICHSLIDES_SCREENSHOT_EXPORT_DIR"],
                    components: []
                )
            else { return }
            directory = resolved
        } catch {
            XCTFail("Cannot prepare runtime screenshot export directory: \(error.localizedDescription)")
            return
        }
        let safeName = name.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let fileURL = directory.appendingPathComponent("\(safeName).png")

        do {
            try screenshot.pngRepresentation.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            XCTFail("Failed to write runtime screenshot: \(fileURL.path), error: \(error.localizedDescription)")
        }
    }

    func assertModeSelectionInlineOnboardingHeader(
        app: XCUIApplication,
        expectedModeSelectionOnboardingTitles: [String] = ["首次设置向导", "Setup Wizard"],
        expectedModeSelectionPageTitles: [String] = ["选择播放方式", "Choose Playback Mode"]
    ) {

        let onboardingTitle = app.staticTexts["mode.onboarding.title"]
        XCTAssertTrue(
            onboardingTitle.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "Mode selection page should keep using the minimal capsule to show the user is still in first-time setup")
        assertText(
            onboardingTitle.label,
            matchesAnyOf: expectedModeSelectionOnboardingTitles,
            failureMessage:
                "The wizard capsule at the top left of the mode selection page should show the correct localized title"
        )
        assertOnboardingCapsuleIsTopLeading(onboardingTitle, pageName: "Mode selection page")

        let pageTitle = app.staticTexts["mode.page.title"]
        XCTAssertTrue(
            pageTitle.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "Mode selection main title should describe this step's task, not repeat the wizard capsule's flow level"
        )
        assertText(
            pageTitle.label,
            matchesAnyOf: expectedModeSelectionPageTitles,
            failureMessage: "The mode selection page main title should show the task title for the current language"
        )
    }

    func assertFilterSummaryMinimalOnboardingHeader(
        app: XCUIApplication,
        expectedFilterSummaryOnboardingTitles: [String] = ["首次设置向导", "Setup Wizard"],
        expectedFilterSummaryPageTitles: [String] = ["设置照片范围", "Set Photo Range"]
    ) {

        let onboardingTitle = app.staticTexts["filterSummary.onboarding.title"]
        XCTAssertTrue(
            onboardingTitle.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "Filter summary page should show the minimal capsule to indicate the user is still in first-time setup")
        assertText(
            onboardingTitle.label,
            matchesAnyOf: expectedFilterSummaryOnboardingTitles,
            failureMessage:
                "The wizard capsule at the top left of the filter summary page should show the correct localized title"
        )
        assertOnboardingCapsuleIsTopLeading(onboardingTitle, pageName: "Filter summary page")

        let pageTitle = app.staticTexts["filterSummary.page.title"]
        XCTAssertTrue(
            pageTitle.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "Filter summary main title should describe this step's task, not repeat the top-left wizard's meaning"
        )
        assertText(
            pageTitle.label,
            matchesAnyOf: expectedFilterSummaryPageTitles,
            failureMessage: "The filter summary page main title should show the task title for the current language"
        )
    }

    func expectedLocalizedTextCandidates(
        languageCode: String?,
        chinese: String,
        english: String
    ) -> [String] {

        switch languageCode {
        case "en":
            return [english]
        case "ja", "ja_JP", "ja-JP":
            return japaneseTextCandidates(for: chinese)
        case "es", "es_ES", "es-ES":
            return spanishTextCandidates(for: chinese)
        case let code? where code.hasPrefix("zh-Hant"):
            return traditionalChineseTextCandidates(for: chinese)
        case "zh", "zh-Hans", "zh_CN", "zh-CN":
            return [chinese]
        default:
            return [chinese, english]
        }
    }

    func traditionalChineseTextCandidates(for simplifiedText: String) -> [String] {

        switch simplifiedText {
        case "首次设置向导":
            return ["首次設定精靈"]
        case "选择播放方式":
            return ["選擇播放方式"]
        case "设置照片范围":
            return ["設定相片範圍", "設定照片範圍"]
        default:
            return [simplifiedText]
        }
    }

    func japaneseTextCandidates(for simplifiedText: String) -> [String] {

        switch simplifiedText {
        case "首次设置向导":
            return ["初期設定ウィザード"]
        case "选择播放方式":
            return ["再生方法を選択"]
        case "设置照片范围":
            return ["写真範囲を設定"]
        default:
            return [simplifiedText]
        }
    }

    func spanishTextCandidates(for simplifiedText: String) -> [String] {

        switch simplifiedText {
        case "首次设置向导":
            return ["Asistente inicial"]
        case "选择播放方式":
            return ["Elegir modo de reproducción"]
        case "设置照片范围":
            return ["Rango de fotos"]
        default:
            return [simplifiedText]
        }
    }

    func assertText(
        _ actualText: String,
        matchesAnyOf expectedTexts: [String],
        failureMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            expectedTexts.contains(actualText),
            "\(failureMessage). Got: \(actualText), allowed: \(expectedTexts.joined(separator: " / "))",
            file: file,
            line: line
        )
    }

    func assertOnboardingCapsuleIsTopLeading(_ element: XCUIElement, pageName: String) {

        XCTAssertLessThan(
            element.frame.minX, FilterSummaryTVOSVisualUITestsCapsuleGeometry.maximumLeadingPositionPoints,
            "\(pageName): the first-time setup capsule should stay inside the top-left safe area")
        XCTAssertLessThan(
            element.frame.minY, FilterSummaryTVOSVisualUITestsCapsuleGeometry.maximumTopPositionPoints,
            "\(pageName): the first-time setup capsule should stay inside the top-left safe area")
    }

    @MainActor
    func waitForFocusVisualSettle(seconds: TimeInterval = TestWait.seconds(.product(0.45))) {

        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    func waitForPlaybackEntryHintAnimationToSettle() {

        waitForFocusVisualSettle(seconds: TestWait.seconds(.product(1.2)))
    }
}
#endif
