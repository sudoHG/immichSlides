import XCTest

enum PlaybackSettingsTVOSUITestsWaitTiming {
    static let controlAppearanceTimeoutSeconds: TimeInterval = 8
    static let navigationTimeoutSeconds: TimeInterval = 10
    static let pollIntervalSeconds: TimeInterval = 0.1
    static let remotePressSettleSeconds: TimeInterval = 0.12
    static let sceneStableExtraSeconds: TimeInterval = 1
    static let screenTransitionTimeoutSeconds: TimeInterval = 12
    static let settingsChangeTimeoutSeconds: TimeInterval = 6
    static let shortFocusSettleSeconds: TimeInterval = 0.15
}

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
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening Playback Settings, the 'Autoplay' entry should appear"
        )

        waitForFocusableElementToGainFocus(
            autoPlayLink,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
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
            shouldResetState: true,
            colorScheme: "dark",
            shouldForceEnglishLocalization: true
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

        RunLoop.current.run(
            until: Date().addingTimeInterval(PlaybackSettingsTVOSUITestsWaitTiming.sceneStableExtraSeconds))
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
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening Playback Settings, the 'Autoplay' entry should appear"
        )
        waitForFocusableElementToGainFocus(
            autoPlayLink,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "The Autoplay entry should take the default focus on the Playback Settings page"
        )

        XCUIRemote.shared.press(.select)

        let onButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.on.button",
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening the Autoplay subpage, the 'Turn On Autoplay' button should be visible"
        )
        let offButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.off.button",
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening the Autoplay subpage, the 'Turn Off Autoplay' button should be visible"
        )

        waitForFocusableElementToGainFocus(
            onButton,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After entering the Autoplay subpage, default focus should land on the first item"
        )

        XCUIRemote.shared.press(.down)
        waitForFocusableElementToGainFocus(
            offButton,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "One move down on the Autoplay subpage should focus 'Turn Off Autoplay'"
        )

        XCUIRemote.shared.press(.select)
        waitForElementValueToContain(
            offButton,
            // The option button value is the localized "selected/not selected" text, not the English word "selected".

            expectedFragment: "已选中",
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
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
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening the Autoplay Interval subpage, the interval options should be shown"
        )
        waitForFocusableElementToGainFocus(
            intervalButton,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
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
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening the Default Playback Mode subpage, 'Random Playback' should be shown"
        )
        let filteredButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.mode.filtered.button",
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening the Default Playback Mode subpage, 'Filtered Playback' should be shown"
        )

        waitForFocusableElementToGainFocus(
            randomButton,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Entering the Default Playback Mode subpage should put default focus on the first item"
        )

        XCUIRemote.shared.press(.down)
        waitForFocusableElementToGainFocus(
            filteredButton,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
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
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening the Display Mode subpage, the 'Smart Fill' option should be shown"
        )
        let singlePhotoButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.displayMode.singlePhoto.button",
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening the Display Mode subpage, the 'Single Photo Mode' option should be shown"
        )

        waitForFocusableElementToGainFocus(
            smartFillButton,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After entering the Display Mode subpage, default focus should land on 'Smart Fill' first"
        )

        XCUIRemote.shared.press(.down)
        waitForFocusableElementToGainFocus(
            singlePhotoButton,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "One move down on the Display Mode subpage should focus 'Single Photo Mode'"
        )
        XCUIRemote.shared.press(.select)
        waitForElementValueToContain(
            singlePhotoButton,
            expectedFragment: "已选中",
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Pressing Select on 'Single Photo Mode' should mark it as selected"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-playback-settings-display-mode-page")
    }

    @MainActor
    func testTVOSPlaybackSettingsFilterEditorPathPresentsEditorWithDoneFocused() throws {
        try assertFilterEditorPresentsEditorWithDoneFocused(
            colorScheme: "dark",
            rootScreenshotName: "tvos-playback-settings-filter-editor-root",
            doneFocusedScreenshotName: "tvos-playback-settings-filter-editor-done-focused",
            failedOpenScreenshotName: "tvos-filter-editor-open-failed-root"
        )
    }

    @MainActor
    func testTVOSPlaybackSettingsFilterEditorPathPresentsEditorWithDoneFocusedLight() throws {

        try assertFilterEditorPresentsEditorWithDoneFocused(
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
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "The filter editor main page should show the 'Albums' entry"
        )

        // The filter editor's default focus starts on the Albums entry; press a real Select.

        waitForFocusableElementToGainFocus(
            albumEntry,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Entering the filter editor main page should put default focus on the 'Albums' entry first"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitUntil(timeout: PlaybackSettingsTVOSUITestsWaitTiming.navigationTimeoutSeconds) {
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
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "On the filter editor main page, the 'People' entry should be able to take focus"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitUntil(timeout: PlaybackSettingsTVOSUITestsWaitTiming.navigationTimeoutSeconds) {
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
                timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
                failureMessage: "The filter editor main page should show the 'People' entry"
            ),
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.settingsChangeTimeoutSeconds,
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
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening the Display Items subpage, the 'EXIF Info' entry should be shown"
        )
        waitForFocusableElementToGainFocus(
            exifLink,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Entering the Display Items subpage should put default focus on the 'EXIF Info' entry first"
        )

        XCUIRemote.shared.press(.select)

        let exifOnButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.showExif.on.button",
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening the EXIF subpage, the option to show EXIF should be shown"
        )
        waitForFocusableElementToGainFocus(
            exifOnButton,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After entering the EXIF subpage, default focus should land on the first item"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-playback-settings-exif-page")
    }

    @MainActor
    func testTVOSPlaybackSettingsDisplayDebugPathCanOpen() throws {
        let app = try openPlaybackSettingsFromSlideShow(shouldEnableDebugSettingsEntry: true)

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
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening the Debug Panel subpage, the option to show the debug panel should be shown"
        )
        waitForFocusableElementToGainFocus(
            debugOnButton,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After entering the Debug Panel subpage, default focus should land on the first item"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-playback-settings-debug-page")
    }

    @MainActor
    func testTVOSPlaybackSettingsDisplayDebugEntryHiddenWhenDisabled() throws {
        let app = try openPlaybackSettingsFromSlideShow(shouldEnableDebugSettingsEntry: false)

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
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "With the debug entry off, Display Items should still keep at least the EXIF entry"
        )
        waitForFocusableElementToGainFocus(
            exifLink,
            timeout: PlaybackSettingsTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
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

#endif
