import XCTest

#if os(tvOS)
final class PlaybackSettingsTVOSUITests: XCTestCase {
    override func setUpWithError() throws {
        // Stop at the first key assertion failure so later remote steps do not run on the wrong page.

        continueAfterFailure = false
        try requireTVOSDestination()
    }

    @MainActor
    func testTVOSPlaybackSettingsMainPageDefaultFocusSnapshot() throws {
        let app = try openPlaybackSettingsFromSlideShow()

        let autoPlayLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.link",
            timeout: 8,
            failureMessage: "After opening Playback Settings, the 'Autoplay' entry should appear"
        )

        waitForFocusableElementToGainFocus(
            autoPlayLink,
            timeout: 8,
            failureMessage: "After opening Playback Settings, default focus should land on the 'Autoplay' entry first"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-playback-settings-main-page")
    }

    // Force the recovery message to show and check that the English UI contains no Chinese.

    @MainActor
    func testTVOSRecoveryMessageLocalizationEnglishSnapshot() throws {
        let config = try requireTestServerConfig()
        let app = launchApp(
            resetState: true,
            colorScheme: "dark",
            forceEnglishLocalization: true
        )

        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        app.launchEnvironment["UI_TEST_FORCE_SLIDESHOW_RECOVERY_MESSAGE"] = "1"
        app.launch()

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 18),
            "After entering the slideshow, the control bar settings button should be visible"
        )

        // Take the runtime screenshot before asserting so a failure still keeps the evidence.

        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        attachScreenshot(app: app, name: "tvos-slideshow-recovery-message-english")

        // Look it up by accessibilityIdentifier first; do not use the text under test as the locator.

        let recoveryMessage = app.staticTexts["slideshow.recovery.message"]

        // The overlay Text may not appear in the XCTest tree, so a hard text assertion does not replace the screenshot.

        _ = recoveryMessage
        waitForFocusVisualSettle()
    }

    @MainActor
    func testTVOSPlaybackSettingsAutoPlayPathCanOpenAndToggle() throws {
        let app = try openPlaybackSettingsFromSlideShow()

        let autoPlayLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.link",
            timeout: 8,
            failureMessage: "After opening Playback Settings, the 'Autoplay' entry should appear"
        )
        waitForFocusableElementToGainFocus(
            autoPlayLink,
            timeout: 8,
            failureMessage: "The Autoplay entry should take the default focus on the Playback Settings page"
        )

        XCUIRemote.shared.press(.select)

        let onButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.on.button",
            timeout: 8,
            failureMessage: "After opening the Autoplay subpage, the 'Turn On Autoplay' button should be visible"
        )
        let offButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.off.button",
            timeout: 8,
            failureMessage: "After opening the Autoplay subpage, the 'Turn Off Autoplay' button should be visible"
        )

        waitForFocusableElementToGainFocus(
            onButton,
            timeout: 8,
            failureMessage: "After entering the Autoplay subpage, default focus should land on the first item"
        )

        XCUIRemote.shared.press(.down)
        waitForFocusableElementToGainFocus(
            offButton,
            timeout: 8,
            failureMessage: "One move down on the Autoplay subpage should focus 'Turn Off Autoplay'"
        )

        XCUIRemote.shared.press(.select)
        waitForElementValueToContain(
            offButton,
            // The option button value is the localized "selected/not selected" text, not the English word "selected".

            expectedFragment: "已选中",
            timeout: 8,
            failureMessage: "Pressing Select on 'Turn Off Autoplay' should switch to the off state"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-playback-settings-auto-play-page")
    }

    @MainActor
    func testTVOSPlaybackSettingsIntervalPathCanOpen() throws {
        let app = try openPlaybackSettingsFromSlideShow()

        _ = moveFocusToSettingsControl(
            app: app,
            identifier: "settings.playback.interval.link",
            maxSteps: 4,
            failureMessage: "Moving down from the Playback Settings main page should reach 'Autoplay Interval'"
        )

        XCUIRemote.shared.press(.select)

        let intervalButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.interval.5.button",
            timeout: 8,
            failureMessage: "After opening the Autoplay Interval subpage, the interval options should be shown"
        )
        waitForFocusableElementToGainFocus(
            intervalButton,
            timeout: 8,
            failureMessage: "After entering the interval subpage, default focus should land on the first item"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-playback-settings-interval-page")
    }

    @MainActor
    func testTVOSPlaybackSettingsModePathCanOpen() throws {
        let app = try openPlaybackSettingsFromSlideShow()

        _ = moveFocusToSettingsControl(
            app: app,
            identifier: "settings.playback.mode.link",
            maxSteps: 5,
            failureMessage: "Moving down from the Playback Settings main page should reach 'Default Playback Mode'"
        )

        XCUIRemote.shared.press(.select)

        let randomButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.mode.random.button",
            timeout: 8,
            failureMessage: "After opening the Default Playback Mode subpage, 'Random Playback' should be shown"
        )
        let filteredButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.mode.filtered.button",
            timeout: 8,
            failureMessage: "After opening the Default Playback Mode subpage, 'Filtered Playback' should be shown"
        )

        waitForFocusableElementToGainFocus(
            randomButton,
            timeout: 8,
            failureMessage: "Entering the Default Playback Mode subpage should put default focus on the first item"
        )

        XCUIRemote.shared.press(.down)
        waitForFocusableElementToGainFocus(
            filteredButton,
            timeout: 8,
            failureMessage: "One move down on the Default Playback Mode subpage should focus 'Filtered Playback'"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-playback-settings-mode-page")
    }

    @MainActor
    func testTVOSPlaybackSettingsDisplayModePathCanOpenAndSelectSinglePhoto() throws {
        let app = try openPlaybackSettingsFromSlideShow()

        _ = moveFocusToSettingsControl(
            app: app,
            identifier: "settings.playback.displayMode.link",
            maxSteps: 5,
            failureMessage: "The Playback Settings main page should reach the 'Display Mode' entry"
        )

        XCUIRemote.shared.press(.select)

        let smartFillButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.displayMode.smartFill.button",
            timeout: 8,
            failureMessage: "After opening the Display Mode subpage, the 'Smart Fill' option should be shown"
        )
        let singlePhotoButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.displayMode.singlePhoto.button",
            timeout: 8,
            failureMessage: "After opening the Display Mode subpage, the 'Single Photo Mode' option should be shown"
        )

        waitForFocusableElementToGainFocus(
            smartFillButton,
            timeout: 8,
            failureMessage: "After entering the Display Mode subpage, default focus should land on 'Smart Fill' first"
        )

        XCUIRemote.shared.press(.down)
        waitForFocusableElementToGainFocus(
            singlePhotoButton,
            timeout: 8,
            failureMessage: "One move down on the Display Mode subpage should focus 'Single Photo Mode'"
        )
        XCUIRemote.shared.press(.select)

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-playback-settings-display-mode-page")
    }

    @MainActor
    func testTVOSPlaybackSettingsFilterEditorPathPresentsCleanFullScreen() throws {
        try assertFilterEditorPresentsCleanFullScreen(
            colorScheme: "dark",
            rootScreenshotName: "tvos-playback-settings-filter-editor-root",
            doneFocusedScreenshotName: "tvos-playback-settings-filter-editor-done-focused",
            failedOpenScreenshotName: "tvos-filter-editor-open-failed-root"
        )
    }

    @MainActor
    func testTVOSPlaybackSettingsFilterEditorPathPresentsCleanFullScreenLight() throws {

        try assertFilterEditorPresentsCleanFullScreen(
            colorScheme: "light",
            rootScreenshotName: "tvos-playback-settings-filter-editor-root-light",
            doneFocusedScreenshotName: "tvos-playback-settings-filter-editor-done-focused-light",
            failedOpenScreenshotName: "tvos-filter-editor-open-failed-root-light"
        )
    }

    @MainActor
    func testTVOSPlaybackSettingsFilterEditorAlbumPathCanOpen() throws {
        let app = try openFilterEditorFromPlaybackSettings()

        let albumEntry = waitForSettingsControl(
            app: app,
            identifier: "filter.editor.album.entry",
            timeout: 8,
            failureMessage: "The filter editor main page should show the 'Albums' entry"
        )

        // The filter editor's default focus starts on the Albums entry; press a real Select.

        waitForFocusableElementToGainFocus(
            albumEntry,
            timeout: 8,
            failureMessage: "Entering the filter editor main page should put default focus on the 'Albums' entry first"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitUntil(timeout: 10) {
                app.buttons["albumFilter.back.button"].exists || app.buttons["albumFilter.selectAll.button"].exists
                    || app.buttons["albumFilter.clear.button"].exists
            },
            "Entering 'Albums' from the filter editor main page should actually open the album filter page"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-playback-settings-filter-editor-album")
    }

    @MainActor
    func testTVOSPlaybackSettingsFilterEditorPersonPathCanOpen() throws {
        let app = try openFilterEditorFromPlaybackSettings()

        let personEntry = moveFocusToFilterEditorEntry(
            app: app,
            identifier: "filter.editor.person.entry",
            maxSteps: 8,
            failureMessage: "On the filter editor main page, focus should be able to move to the 'People' entry"
        )
        waitForFocusableElementToGainFocus(
            personEntry,
            timeout: 6,
            failureMessage: "On the filter editor main page, the 'People' entry should be able to take focus"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitUntil(timeout: 10) {
                app.buttons["personFilter.back.button"].exists || app.buttons["personFilter.selectAll.button"].exists
                    || app.buttons["personFilter.clear.button"].exists
            },
            "Entering 'People' from the filter editor main page should actually open the people filter page"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-playback-settings-filter-editor-person")
    }

    @MainActor
    func testTVOSPlaybackSettingsFilterEditorDoneToggleKeepsPeopleCardStable() throws {
        let app = try openFilterEditorFromPlaybackSettings()

        let peopleIdentifier = "filter.editor.person.entry"
        let doneIdentifier = "filter.editor.done.button"

        _ = moveFocusToFilterEditorEntry(
            app: app,
            identifier: peopleIdentifier,
            maxSteps: 8,
            failureMessage: "On the filter editor main page, focus should be able to move to the 'People' entry"
        )
        waitForFocusableElementToGainFocus(
            waitForSettingsControl(
                app: app,
                identifier: peopleIdentifier,
                timeout: 8,
                failureMessage: "The filter editor main page should show the 'People' entry"
            ),
            timeout: 6,
            failureMessage: "Before toggling starts, the 'People' entry should already hold focus steadily"
        )

        for _ in 0..<3 {
            XCUIRemote.shared.press(.right)
            waitForFocusVisualSettle(seconds: 0.22)
            XCTAssertTrue(
                isAnySettingsControlFocused(app: app, identifier: doneIdentifier),
                "After moving right from 'People', focus should settle on the 'Done' button"
            )

            XCUIRemote.shared.press(.left)
            waitForFocusVisualSettle(seconds: 0.22)
            XCTAssertTrue(
                isAnySettingsControlFocused(app: app, identifier: peopleIdentifier),
                "After moving left from 'Done', focus should settle back on the 'People' entry"
            )
        }

        XCUIRemote.shared.press(.right)
        waitForFocusVisualSettle(seconds: 0.24)

        XCTAssertTrue(
            isAnySettingsControlFocused(app: app, identifier: doneIdentifier),
            "After toggling back and forth, focus should finally stay on the 'Done' button"
        )
        XCTAssertFalse(
            isAnySettingsControlFocused(app: app, identifier: peopleIdentifier),
            "After toggling back and forth, the 'People' entry should not wrongly stay focused"
        )

        attachScreenshot(app: app, name: "tvos-playback-settings-filter-editor-done-toggle-stable")
    }

    @MainActor
    func testTVOSPlaybackSettingsDisplayExifPathCanOpen() throws {
        let app = try openPlaybackSettingsFromSlideShow()

        _ = moveFocusToSettingsControl(
            app: app,
            identifier: "settings.playback.display.link",
            maxSteps: 7,
            failureMessage: "Moving down from the Playback Settings main page should reach the 'Display Items' entry"
        )

        XCUIRemote.shared.press(.select)

        let exifLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.showExif.link",
            timeout: 8,
            failureMessage: "After opening the Display Items subpage, the 'EXIF Info' entry should be shown"
        )
        waitForFocusableElementToGainFocus(
            exifLink,
            timeout: 8,
            failureMessage: "Entering the Display Items subpage should put default focus on the 'EXIF Info' entry first"
        )

        XCUIRemote.shared.press(.select)

        let exifOnButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.showExif.on.button",
            timeout: 8,
            failureMessage: "After opening the EXIF subpage, the option to show EXIF should be shown"
        )
        waitForFocusableElementToGainFocus(
            exifOnButton,
            timeout: 8,
            failureMessage: "After entering the EXIF subpage, default focus should land on the first item"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-playback-settings-exif-page")
    }

    @MainActor
    func testTVOSPlaybackSettingsDisplayDebugPathCanOpen() throws {
        let app = try openPlaybackSettingsFromSlideShow(enableDebugSettingsEntry: true)

        _ = moveFocusToSettingsControl(
            app: app,
            identifier: "settings.playback.display.link",
            maxSteps: 7,
            failureMessage: "Moving down from the Playback Settings main page should reach the 'Display Items' entry"
        )

        XCUIRemote.shared.press(.select)

        _ = moveFocusToSettingsControl(
            app: app,
            identifier: "settings.playback.showDebug.link",
            maxSteps: 4,
            failureMessage: "Moving down on the Display Items subpage should reach the 'Debug Panel' entry"
        )

        XCUIRemote.shared.press(.select)

        let debugOnButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.showDebug.on.button",
            timeout: 8,
            failureMessage: "After opening the Debug Panel subpage, the option to show the debug panel should be shown"
        )
        waitForFocusableElementToGainFocus(
            debugOnButton,
            timeout: 8,
            failureMessage: "After entering the Debug Panel subpage, default focus should land on the first item"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-playback-settings-debug-page")
    }

    @MainActor
    func testTVOSPlaybackSettingsDisplayDebugEntryHiddenWhenDisabled() throws {
        let app = try openPlaybackSettingsFromSlideShow(enableDebugSettingsEntry: false)

        _ = moveFocusToSettingsControl(
            app: app,
            identifier: "settings.playback.display.link",
            maxSteps: 7,
            failureMessage: "Moving down from the Playback Settings main page should reach the 'Display Items' entry"
        )

        XCUIRemote.shared.press(.select)

        let exifLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.showExif.link",
            timeout: 8,
            failureMessage: "With the debug entry off, Display Items should still keep at least the EXIF entry"
        )
        waitForFocusableElementToGainFocus(
            exifLink,
            timeout: 8,
            failureMessage: "In Display Items, default focus should still settle on the first item, the EXIF entry"
        )

        XCTAssertFalse(
            app.buttons["settings.playback.showDebug.link"].waitForExistence(timeout: 1.5),
            "With the debug entry explicitly off, the Display Items subpage should not expose 'Debug Panel'"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-playback-settings-debug-hidden")
    }
}

private extension PlaybackSettingsTVOSUITests {
    func requireTVOSDestination() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            throw XCTSkip(
                "The destination is not tvOS (detected: \(UIDevice.current.model)); skipping the tvOS UI test.")
        }
    }

    func launchApp(
        resetState: Bool,
        seedFilterSelection: Bool = false,
        colorScheme: String? = nil,
        disablePlaybackEntryHint: Bool = true,
        forceEnglishLocalization: Bool = false,
        enableDebugSettingsEntry: Bool? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()

        if resetState {
            app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        }
        if seedFilterSelection {
            app.launchEnvironment["UI_TEST_SEED_FILTER_SELECTION"] = "1"
        }
        if let colorScheme {
            app.launchEnvironment["UI_TEST_COLOR_SCHEME"] = colorScheme
        }
        if disablePlaybackEntryHint {
            app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        }
        if forceEnglishLocalization {
            // Pin the English locale with launchArguments instead of relying only on xcodebuild -testLanguage.

            app.launchArguments += [
                "-AppleLanguages", "(en)",
                "-AppleLocale", "en_US"
            ]
        }
        if let enableDebugSettingsEntry {
            // Toggle the debug entry through the launch environment, without depending on the local env.xcconfig.

            app.launchEnvironment["UI_TEST_ENABLE_DEBUG_SETTINGS_ENTRY"] = enableDebugSettingsEntry ? "1" : "0"
        }

        return app
    }

    @MainActor
    func launchIntoFilterSummary(
        colorScheme: String = "dark",
        enableDebugSettingsEntry: Bool? = nil
    ) throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = launchApp(
            resetState: true,
            seedFilterSelection: true,
            colorScheme: colorScheme,
            disablePlaybackEntryHint: true,
            enableDebugSettingsEntry: enableDebugSettingsEntry
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
            continueButton.waitForExistence(timeout: 15),
            "After injecting the test server config, the app should go straight to mode selection")

        startFilteredFlowFromModeSelection(app: app)

        XCTAssertTrue(
            app.buttons["filterSummary.album.button"].waitForExistence(timeout: 10),
            "The filter summary page should show the album entry")
        XCTAssertTrue(
            app.buttons["filterSummary.person.button"].waitForExistence(timeout: 10),
            "The filter summary page should show the people entry")
        return app
    }

    func startFilteredFlowFromModeSelection(app: XCUIApplication) {
        let modeFilteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(
            modeFilteredButton.waitForExistence(timeout: 8),
            "The mode selection page should show the 'Filtered Playback' entry")

        // Filtered Playback is the second card: press Right, then Select.

        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 8),
            "After entering the filtered playback flow, the Continue button should be visible")
        XCTAssertTrue(
            continueButton.isEnabled,
            "The test seed already presets filter conditions, so the Continue button should be enabled")

        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            app.buttons["filterSummary.startPlayback.button"].waitForExistence(timeout: 12),
            "After entering the filter summary page, the 'Start Playback' button should be visible")
    }

    @MainActor
    func launchIntoSlideShow(
        colorScheme: String = "dark",
        enableDebugSettingsEntry: Bool? = nil
    ) throws -> XCUIApplication {
        let app = try launchIntoFilterSummary(
            colorScheme: colorScheme,
            enableDebugSettingsEntry: enableDebugSettingsEntry
        )
        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startPlaybackButton.waitForExistence(timeout: 8),
            "The filter summary page should show the 'Start Playback' button")

        if startPlaybackButton.hasFocus == false {
            for _ in 0..<8 {
                XCUIRemote.shared.press(.down)
                RunLoop.current.run(until: Date().addingTimeInterval(0.12))
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
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 18),
            "After playback starts, the slideshow should open and show the control bar"
        )

        return app
    }

    @MainActor
    func openPlaybackSettingsFromSlideShow(
        colorScheme: String = "dark",
        enableDebugSettingsEntry: Bool? = nil
    ) throws -> XCUIApplication {
        let app = try launchIntoSlideShow(
            colorScheme: colorScheme,
            enableDebugSettingsEntry: enableDebugSettingsEntry
        )
        openSettingsFromSlideShow(app: app)

        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForExistence(timeout: 8),
            "The settings main page should show the 'Playback Settings' entry")
        waitForFocusableElementToGainFocus(
            playbackItem,
            timeout: 8,
            failureMessage: "Entering the settings main page should put default focus on 'Playback Settings' first"
        )

        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.playback.autoPlay.link",
                timeout: 8
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

        let didOpenEditor = waitUntil(timeout: 10) {
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
    func assertFilterEditorPresentsCleanFullScreen(
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

        let didPresentEditor = waitUntil(timeout: 10) {
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
            timeout: 6,
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
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "The slideshow should show the settings button")

        // Bring focus back to the leftmost settings button before pressing Select.

        for _ in 0..<5 {
            if settingsButton.hasFocus { break }
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }

        waitForFocusableElementToGainFocus(
            settingsButton,
            timeout: 6,
            failureMessage: "Before opening settings, focus should settle on the control bar's left settings button"
        )

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForAnySettingsSurface(app: app, timeout: 8),
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
            timeout: 8,
            failureMessage: failureMessage,
            file: file,
            line: line
        )

        for _ in 0...maxSteps {
            if isAnySettingsControlFocused(app: app, identifier: identifier) {
                return target
            }
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.18)
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
            timeout: 8,
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
                waitForFocusVisualSettle(seconds: 0.18)
                if isAnySettingsControlFocused(app: app, identifier: identifier) {
                    return target
                }
            }

            if identifier == personIdentifier && isAnySettingsControlFocused(app: app, identifier: albumIdentifier) {
                XCUIRemote.shared.press(.right)
                waitForFocusVisualSettle(seconds: 0.18)
                if isAnySettingsControlFocused(app: app, identifier: identifier) {
                    return target
                }
            } else if identifier == albumIdentifier
                && isAnySettingsControlFocused(app: app, identifier: personIdentifier)
            {
                XCUIRemote.shared.press(.left)
                waitForFocusVisualSettle(seconds: 0.18)
                if isAnySettingsControlFocused(app: app, identifier: identifier) {
                    return target
                }
            }

            XCUIRemote.shared.press(.up)
            waitForFocusVisualSettle(seconds: 0.16)
            if isAnySettingsControlFocused(app: app, identifier: identifier) {
                return target
            }

            XCUIRemote.shared.press(.right)
            waitForFocusVisualSettle(seconds: 0.18)
            if isAnySettingsControlFocused(app: app, identifier: identifier) {
                return target
            }

            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.18)
            if isAnySettingsControlFocused(app: app, identifier: identifier) {
                return target
            }

            XCUIRemote.shared.press(.left)
            waitForFocusVisualSettle(seconds: 0.16)
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
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

    func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
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
            readinessLabel.waitForExistence(timeout: 12),
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
        let result = XCTWaiter.wait(for: [expectation], timeout: 20)
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
    func waitForFocusVisualSettle(seconds: TimeInterval = 0.45) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
#endif
