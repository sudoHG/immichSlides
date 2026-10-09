import XCTest

#if os(tvOS)
extension PlaybackSettingsTVOSUITests {
    func requireTVOSDestination() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            throw XCTSkip(
                "The destination is not tvOS (detected: \(UIDevice.current.model)); skipping the tvOS UI test.")
        }
    }

    func launchApp(
        shouldResetState: Bool,
        shouldSeedFilterSelection: Bool = false,
        colorScheme: String? = nil,
        shouldDisablePlaybackEntryHint: Bool = true,
        shouldForceEnglishLocalization: Bool = false,
        shouldEnableDebugSettingsEntry: Bool? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()

        if shouldResetState {
            app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        }
        if shouldSeedFilterSelection {
            app.launchEnvironment["UI_TEST_SEED_FILTER_SELECTION"] = "1"
        }
        if let colorScheme {
            app.launchEnvironment["UI_TEST_COLOR_SCHEME"] = colorScheme
        }
        if shouldDisablePlaybackEntryHint {
            app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        }
        if shouldForceEnglishLocalization {
            // Pin the English locale with launchArguments instead of relying only on xcodebuild -testLanguage.

            app.launchArguments += [
                "-AppleLanguages", "(en)",
                "-AppleLocale", "en_US"
            ]
        }
        if let shouldEnableDebugSettingsEntry {
            // Toggle the debug entry through the launch environment, without depending on the local env.xcconfig.

            app.launchEnvironment["UI_TEST_ENABLE_DEBUG_SETTINGS_ENTRY"] = shouldEnableDebugSettingsEntry ? "1" : "0"
        }

        return app
    }

    @MainActor
    func launchIntoFilterSummary(
        colorScheme: String = "dark",
        shouldEnableDebugSettingsEntry: Bool? = nil
    ) throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = launchApp(
            shouldResetState: true,
            shouldSeedFilterSelection: true,
            colorScheme: colorScheme,
            shouldDisablePlaybackEntryHint: true,
            shouldEnableDebugSettingsEntry: shouldEnableDebugSettingsEntry
        )

        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        try requireServerAlbumAndPerson()
        app.launchEnvironment["UI_TEST_PREPARE_FILTER_SUMMARY_VISUAL_SELECTIONS"] = "1"
        app.launchEnvironment["UI_TEST_PREPARE_FILTER_EDITOR_VISUAL_SELECTIONS"] = "1"
        app.launch()

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(15))),
            "After injecting the test server config, the app should go straight to mode selection")

        startFilteredFlowFromModeSelection(app: app)

        XCTAssertTrue(
            app.buttons["filterSummary.album.button"].waitForExistence(
                timeout: PlaybackSettingsTVOSUITestsWaitTiming.navigationTimeoutSeconds),
            "The filter summary page should show the album entry")
        XCTAssertTrue(
            app.buttons["filterSummary.person.button"].waitForExistence(
                timeout: PlaybackSettingsTVOSUITestsWaitTiming.navigationTimeoutSeconds),
            "The filter summary page should show the people entry")
        return app
    }

    func startFilteredFlowFromModeSelection(app: XCUIApplication) {
        let modeFilteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(
            modeFilteredButton.waitForExistence(
                timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The mode selection page should show the 'Filtered Playback' entry")

        // Filtered Playback is the second card: press Right, then Select.

        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(
                timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After entering the filtered playback flow, the Continue button should be visible")
        XCTAssertTrue(
            continueButton.isEnabled,
            "The test seed already presets filter conditions, so the Continue button should be enabled")

        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            app.buttons["filterSummary.startPlayback.button"].waitForExistence(
                timeout: PlaybackSettingsTVOSUITestsWaitTiming.screenTransitionTimeoutSeconds),
            "After entering the filter summary page, the 'Start Playback' button should be visible")
    }

    @MainActor
    func launchIntoSlideShow(
        colorScheme: String = "dark",
        shouldEnableDebugSettingsEntry: Bool? = nil
    ) throws -> XCUIApplication {
        let app = try launchIntoFilterSummary(
            colorScheme: colorScheme,
            shouldEnableDebugSettingsEntry: shouldEnableDebugSettingsEntry
        )
        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startPlaybackButton.waitForExistence(
                timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The filter summary page should show the 'Start Playback' button")

        if startPlaybackButton.hasFocus == false {
            for _ in 0..<8 {
                XCUIRemote.shared.press(.down)
                RunLoop.current.run(
                    until: Date().addingTimeInterval(PlaybackSettingsTVOSUITestsWaitTiming.remotePressSettleSeconds))
                if startPlaybackButton.hasFocus {
                    break
                }
            }
        }

        XCTAssertTrue(
            startPlaybackButton.hasFocus,
            "After entering the filter summary page, focus should be able to move to 'Start Playback'")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: TestWait.seconds(.infrastructure(18))),
            "After playback starts, the slideshow should open and show the control bar"
        )

        return app
    }

    @MainActor
    func openPlaybackSettingsFromSlideShow(
        colorScheme: String = "dark",
        shouldEnableDebugSettingsEntry: Bool? = nil
    ) throws -> XCUIApplication {
        let app = try launchIntoSlideShow(
            colorScheme: colorScheme,
            shouldEnableDebugSettingsEntry: shouldEnableDebugSettingsEntry
        )
        openSettingsFromSlideShow(app: app)

        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForExistence(
                timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The settings main page should show the 'Playback Settings' entry")
        waitForFocusableElementToGainFocus(
            playbackItem,
            timeout: TestWait.seconds(.product(8)),
            failureMessage: "Entering the settings main page should put default focus on 'Playback Settings' first"
        )

        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.playback.autoPlay.link",
                timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "Selecting 'Playback Settings' should open the playback settings subpage"
        )

        return app
    }

    @MainActor
    func openFilterEditorFromPlaybackSettings(colorScheme: String = "dark") throws -> XCUIApplication {
        let app = try openPlaybackSettingsFromSlideShow(colorScheme: colorScheme)

        _ = moveFocusToSettingsControl(
            app: app,
            identifier: "settings.playback.filterConfig.button",
            maxSteps: 6,
            failureMessage: "On the Playback Settings page, focus should be able to move to the 'Edit Filters' entry"
        )

        XCUIRemote.shared.press(.select)

        let didOpenEditor = waitUntil(timeout: PlaybackSettingsTVOSUITestsWaitTiming.navigationTimeoutSeconds) {
            app.buttons["filter.editor.album.entry"].exists && app.buttons["filter.editor.person.entry"].exists
                && app.staticTexts["filterEditor.page.title"].exists
        }
        if didOpenEditor == false {

            attachScreenshot(app: app, name: "tvos-filter-editor-open-failed-helper")
        }
        XCTAssertTrue(
            didOpenEditor,
            "Selecting 'Edit Filters' should open the filter editor"
        )

        waitForReadinessMarker(app: app, identifier: "filterEditor.visual.ready")

        return app
    }

    @MainActor
    func assertFilterEditorPresentsEditorWithDoneFocused(
        colorScheme: String,
        rootScreenshotName: String,
        doneFocusedScreenshotName: String,
        failedOpenScreenshotName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let app = try openPlaybackSettingsFromSlideShow(colorScheme: colorScheme)

        _ = moveFocusToSettingsControl(
            app: app,
            identifier: "settings.playback.filterConfig.button",
            maxSteps: 6,
            failureMessage: "Moving down from the Playback Settings main page should focus the 'Edit Filters' entry",
            file: file,
            line: line
        )

        XCUIRemote.shared.press(.select)

        let didPresentEditor = waitUntil(timeout: PlaybackSettingsTVOSUITestsWaitTiming.navigationTimeoutSeconds) {
            app.buttons["filter.editor.album.entry"].exists && app.buttons["filter.editor.person.entry"].exists
                && app.staticTexts["filterEditor.page.title"].exists
        }
        if didPresentEditor == false {
            attachScreenshot(app: app, name: failedOpenScreenshotName)
        }
        XCTAssertTrue(
            didPresentEditor,
            "After opening the filter editor, the page title and the Albums/People entries should be visible",
            file: file,
            line: line
        )

        waitForReadinessMarker(app: app, identifier: "filterEditor.visual.ready", file: file, line: line)
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: rootScreenshotName)

        let doneButton = moveFocusToFilterEditorEntry(
            app: app,
            identifier: "filter.editor.done.button",
            maxSteps: 6,
            failureMessage: "On the filter editor main page, focus should be able to move to the 'Done' button",
            file: file,
            line: line
        )
        waitForFocusableElementToGainFocus(
            doneButton,
            timeout: TestWait.seconds(.product(6)),
            failureMessage: "On the filter editor main page, the 'Done' button should be able to take focus",
            file: file,
            line: line
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: doneFocusedScreenshotName)
    }

    @MainActor
    func openSettingsFromSlideShow(app: XCUIApplication) {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: PlaybackSettingsTVOSUITestsWaitTiming.navigationTimeoutSeconds),
            "The slideshow should show the settings button")

        // Bring focus back to the leftmost settings button before pressing Select.

        for _ in 0..<5 {
            if settingsButton.hasFocus { break }
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(
                until: Date().addingTimeInterval(PlaybackSettingsTVOSUITestsWaitTiming.remotePressSettleSeconds))
        }

        waitForFocusableElementToGainFocus(
            settingsButton,
            timeout: TestWait.seconds(.product(6)),
            failureMessage: "Before opening settings, focus should settle on the control bar's left settings button"
        )

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForAnySettingsSurface(
                app: app, timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Pressing Select on the settings button should open the settings page")
    }

    @MainActor
    func moveFocusToSettingsControl(
        app: XCUIApplication,
        identifier: String,
        maxSteps: Int,
        failureMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let target = waitForSettingsControl(
            app: app,
            identifier: identifier,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: failureMessage,
            file: file,
            line: line
        )

        for _ in 0...maxSteps {
            if isAnySettingsControlFocused(app: app, identifier: identifier) {
                return target
            }
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.18)))
            if isAnySettingsControlFocused(app: app, identifier: identifier) {
                return target
            }
        }

        XCTFail(failureMessage, file: file, line: line)
        return target
    }

    @MainActor
    func moveFocusToFilterEditorEntry(
        app: XCUIApplication,
        identifier: String,
        maxSteps: Int,
        failureMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let target = waitForSettingsControl(
            app: app,
            identifier: identifier,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: failureMessage,
            file: file,
            line: line
        )

        let albumIdentifier = "filter.editor.album.entry"
        let personIdentifier = "filter.editor.person.entry"
        let doneIdentifier = "filter.editor.done.button"

        for _ in 0...maxSteps {
            if isAnySettingsControlFocused(app: app, identifier: identifier) {
                return target
            }

            // The Done button at the bottom may take focus first; press Up to return to the card area.

            if isAnySettingsControlFocused(app: app, identifier: doneIdentifier) {
                XCUIRemote.shared.press(.up)
                waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.18)))
                if isAnySettingsControlFocused(app: app, identifier: identifier) {
                    return target
                }
            }

            if identifier == personIdentifier && isAnySettingsControlFocused(app: app, identifier: albumIdentifier) {
                XCUIRemote.shared.press(.right)
                waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.18)))
                if isAnySettingsControlFocused(app: app, identifier: identifier) {
                    return target
                }
            } else if identifier == albumIdentifier
                && isAnySettingsControlFocused(app: app, identifier: personIdentifier)
            {
                XCUIRemote.shared.press(.left)
                waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.18)))
                if isAnySettingsControlFocused(app: app, identifier: identifier) {
                    return target
                }
            }

            XCUIRemote.shared.press(.up)
            waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.16)))
            if isAnySettingsControlFocused(app: app, identifier: identifier) {
                return target
            }

            XCUIRemote.shared.press(.right)
            waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.18)))
            if isAnySettingsControlFocused(app: app, identifier: identifier) {
                return target
            }

            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.18)))
            if isAnySettingsControlFocused(app: app, identifier: identifier) {
                return target
            }

            XCUIRemote.shared.press(.left)
            waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.16)))
            if isAnySettingsControlFocused(app: app, identifier: identifier) {
                return target
            }
        }

        XCTFail(failureMessage, file: file, line: line)
        return target
    }

    func isElementFocused(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        if element.hasFocus {
            return true
        }

        let value = accessibilityValueString(for: element)
        return value.contains("focused") || value.contains("已聚焦")
    }

    func isAnySettingsControlFocused(app: XCUIApplication, identifier: String) -> Bool {
        settingsControlCandidates(app: app, identifier: identifier).contains(where: isElementFocused)
    }

    func waitForAnySettingsSurface(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.otherElements["settings.item.playback"].exists || app.buttons["settings.item.playback"].exists
                || app.staticTexts["settings.item.playback"].exists
                || app.otherElements["settings.item.accessProtection"].exists
                || app.buttons["settings.item.accessProtection"].exists
                || app.staticTexts["settings.item.accessProtection"].exists
            {
                return true
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(PlaybackSettingsTVOSUITestsWaitTiming.shortFocusSettleSeconds))
        }
        return false
    }

    func settingsControlCandidates(app: XCUIApplication, identifier: String) -> [XCUIElement] {
        [
            app.buttons[identifier],
            app.otherElements[identifier],
            app.staticTexts[identifier]
        ]
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
                until: Date().addingTimeInterval(PlaybackSettingsTVOSUITestsWaitTiming.pollIntervalSeconds))
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
                until: Date().addingTimeInterval(PlaybackSettingsTVOSUITestsWaitTiming.pollIntervalSeconds))
        }

        XCTFail(failureMessage, file: file, line: line)
        return app.otherElements[identifier]
    }

    @MainActor
    func waitForFocusableElementToGainFocus(
        _ element: XCUIElement,
        timeout: TimeInterval,
        failureMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isElementFocused(element) {
                return
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(PlaybackSettingsTVOSUITestsWaitTiming.pollIntervalSeconds))
        }

        XCTFail(failureMessage, file: file, line: line)
    }

    @MainActor
    func waitForElementValueToContain(
        _ element: XCUIElement,
        expectedFragment: String,
        timeout: TimeInterval,
        failureMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // ui-label-lookup: Assert localized accessibility state on an element already found by identifier.
        let predicate = NSPredicate(format: "value CONTAINS %@", expectedFragment)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, failureMessage, file: file, line: line)
    }

    func accessibilityValueString(for element: XCUIElement) -> String {
        guard let rawValue = element.value else { return "" }
        return String(describing: rawValue)
    }

    // Callers resolve the TestWait budget once; polling cadence stays fixed.
    func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(
                until: Date().addingTimeInterval(PlaybackSettingsTVOSUITestsWaitTiming.pollIntervalSeconds))
        }
        return condition()
    }

    @MainActor
    func waitForReadinessMarker(
        app: XCUIApplication,
        identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let readinessLabel = app.staticTexts[identifier]
        XCTAssertTrue(
            readinessLabel.waitForExistence(
                timeout: PlaybackSettingsTVOSUITestsWaitTiming.screenTransitionTimeoutSeconds),
            "A readable UI test readiness marker should be exposed: \(identifier)",
            file: file,
            line: line
        )

        // ui-label-lookup: Assert localized accessibility state on an element already found by identifier.
        let predicate = NSPredicate(
            format: "label MATCHES[c] %@ OR value MATCHES[c] %@",
            "ready",
            "ready"
        )
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: readinessLabel)
        let result = XCTWaiter.wait(for: [expectation], timeout: TestWait.seconds(.infrastructure(20)))
        XCTAssertEqual(
            result,
            .completed,
            "Timed out waiting for the page to finish loading: \(identifier)",
            file: file,
            line: line
        )
    }

    func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func waitForFocusVisualSettle(seconds: TimeInterval = TestWait.seconds(.product(0.45))) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
#endif
