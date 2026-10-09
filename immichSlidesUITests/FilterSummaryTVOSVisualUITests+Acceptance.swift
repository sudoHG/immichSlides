import XCTest

#if os(tvOS)
extension FilterSummaryTVOSVisualUITests {
    @MainActor
    func testTVOSEnglishAcceptanceSettingsPagesScreenshots() throws {

        let playbackApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openSettingsFromSlideShow(app: playbackApp)
        _ = waitForSettingsHomeItem(
            app: playbackApp,
            identifier: "settings.item.playback",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.playbackSteps,
            failureMessage: "In English, the tvOS settings home should show Playback Settings"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: playbackApp, name: "english-tvos-settings-root")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: playbackApp, identifier: "settings.playback.autoPlay.link",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "English playback settings page should show the Autoplay entry"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: playbackApp, name: "english-tvos-settings-playback")
        playbackApp.terminate()

        let accessProtectionApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openSettingsFromSlideShow(app: accessProtectionApp)
        _ = waitForSettingsHomeItem(
            app: accessProtectionApp,
            identifier: "settings.item.accessProtection",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.accessProtectionSteps,
            failureMessage: "In English, the settings home should be able to open Access Protection"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: accessProtectionApp, label: "Access protection is disabled",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "English access protection page should show the disabled state"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: accessProtectionApp, name: "english-tvos-settings-access-protection")
        accessProtectionApp.terminate()

        let serverApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openSettingsFromSlideShow(app: serverApp)
        _ = waitForSettingsHomeItem(
            app: serverApp,
            identifier: "settings.item.server",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.serverSteps,
            failureMessage: "In English, the settings home should be able to open Server"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: serverApp, identifier: "server.apiKey.help.button",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "English server page should show the API Key help entry"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: serverApp, name: "english-tvos-settings-server")
        serverApp.terminate()

        let cacheApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openSettingsFromSlideShow(app: cacheApp)
        _ = waitForSettingsHomeItem(
            app: cacheApp,
            identifier: "settings.item.cache",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.cacheSteps,
            failureMessage: "In English, the settings home should be able to open Cache Management"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: cacheApp, identifier: "settings.cache.disk.row",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "English cache page should show the disk cache metric"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: cacheApp, name: "english-tvos-settings-cache")
    }

    @MainActor
    func testTVOSEnglishAcceptanceAboutPrivacyAndOpenSourceScreenshots() throws {

        let app = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.about",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.aboutSteps,
            failureMessage: "In English, the settings home should be able to open About"
        )
        XCUIRemote.shared.press(.select)

        let appInfoSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.appInfo.section",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should show the App Information section"
        )
        waitForButtonToGainFocus(
            appInfoSection,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "On the English About page, the first focus should land on App Information"
        )
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: app, label: "App Information",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "English About page should show App Information"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "english-tvos-settings-about")

        let privacyPolicyLink = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should show the Privacy Policy entry"
        )
        for _ in 0..<3 {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.22)))
        }
        waitForButtonToGainFocus(
            privacyPolicyLink,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "English About page should let focus move to Privacy Policy"
        )
        attachScreenshot(app: app, name: "english-tvos-settings-about-bottom")
        XCUIRemote.shared.press(.select)

        let chineseLanguageButton = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.language.zh.button",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Privacy policy page should show the Chinese language button"
        )
        let englishLanguageButton = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.language.en.button",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Privacy policy page should show the English language button"
        )
        let chineseLanguageValue = accessibilityValueString(for: chineseLanguageButton)
        let englishLanguageValue = accessibilityValueString(for: englishLanguageButton)
        XCTAssertTrue(
            englishLanguageValue.contains("Selected") && englishLanguageValue.contains("Not Selected") == false,
            "In English, the English button should be selected by default on the privacy policy page"
        )
        XCTAssertTrue(
            chineseLanguageValue.contains("Not Selected") || chineseLanguageValue.contains("未选中"),
            "In English, the Chinese button should not still be selected on the privacy policy page"
        )

        let englishFirstPolicySection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.section.0",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In English, the privacy policy page should show the English text right away"
        )
        XCTAssertTrue(
            englishFirstPolicySection.label.contains("Scope"),
            "The English privacy policy page should show Scope as its first section by default, not the Chinese text"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "english-tvos-settings-privacy-policy")
        app.terminate()

        let openSourceApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openSettingsFromSlideShow(app: openSourceApp)
        _ = waitForSettingsHomeItem(
            app: openSourceApp,
            identifier: "settings.item.about",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.aboutSteps,
            failureMessage: "In English, the settings home should be able to open About again"
        )
        XCUIRemote.shared.press(.select)

        let openSourceAppInfoSection = waitForSettingsControl(
            app: openSourceApp,
            identifier: "settings.about.appInfo.section",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should expose the App Information section"
        )
        let openSourceUnofficialSection = waitForSettingsControl(
            app: openSourceApp,
            identifier: "settings.about.unofficialNotice.section",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should expose the Unofficial Notice section"
        )
        let openSourceFeedbackSection = waitForSettingsControl(
            app: openSourceApp,
            identifier: "settings.about.feedback.section",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should expose the Feedback & Support section"
        )
        let openSourcePrivacyLink = waitForSettingsControl(
            app: openSourceApp,
            identifier: "settings.about.privacyPolicy.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should show the Privacy Policy entry"
        )
        let openSourceLink = waitForSettingsControl(
            app: openSourceApp,
            identifier: "settings.about.opensource.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should show the Open Source Licenses entry"
        )
        waitForButtonToGainFocus(
            openSourceAppInfoSection,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "English About page default focus should land on App Information"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.22)))
        waitForButtonToGainFocus(
            openSourceUnofficialSection,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "English About page should let focus go from App Information to Unofficial Notice"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.22)))
        waitForButtonToGainFocus(
            openSourceFeedbackSection,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "English About page should let focus go from Unofficial Notice to Feedback & Support"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.22)))
        waitForButtonToGainFocus(
            openSourcePrivacyLink,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "English About page should let focus go from Feedback & Support to Privacy Policy"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.22)))
        waitForButtonToGainFocus(
            openSourceLink,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "English About page should let focus move to Open Source Licenses"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: openSourceApp, label: "Open Source Licenses",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "English open source licenses page should show Open Source Licenses"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: openSourceApp, name: "english-tvos-settings-open-source")
    }

    @MainActor
    func testTVOSFullFlowModeSelectionToAccessProtectionCanReachTargetPage() throws {

        let app = try launchIntoFilterSummary()

        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startPlaybackButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Filter summary page should show the 'Start Playback' button")

        if startPlaybackButton.hasFocus == false {
            for _ in 0..<8 {
                XCUIRemote.shared.press(.down)
                RunLoop.current.run(
                    until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.remotePressSettleSeconds))
                if startPlaybackButton.hasFocus {
                    break
                }
            }
        }

        XCTAssertTrue(startPlaybackButton.hasFocus, "Focus should move reliably to the 'Start Playback' button")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: TestWait.seconds(.infrastructure(18))),
            "Starting playback from filter summary should open playback with the control bar settings button"
        )

        openSettingsFromSlideShow(app: app)
        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.accessProtection",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.accessProtectionSteps,
            failureMessage: "Settings home should reliably reach the 'Access Protection' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.pin.input.enable",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "On the access protection page, the 'Set PIN' input entry should be shown"
        )
    }

    @MainActor
    func testTVOSFullFlowPinGateBlocksSettingsUntilPinValidated() throws {

        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.accessProtection",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.accessProtectionSteps,
            failureMessage: "Settings home should reliably reach the 'Access Protection' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Set PIN' input entry"
        )
        let enablePinConfirmInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enableConfirm",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Confirm PIN' input entry"
        )
        let enableProtectionButton = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.enable.button",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Enable Access Protection' button"
        )

        waitForButtonToGainFocus(
            enablePinInput,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "On the access protection page, default focus should land on the 'Set PIN' input entry"
        )
        XCUIRemote.shared.press(.select)
        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Set PIN")

        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            enablePinConfirmInput,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After filling 'Set PIN', moving down should focus the 'Confirm PIN' input entry"
        )
        XCUIRemote.shared.press(.select)
        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Confirm PIN")

        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            enableProtectionButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage:
                "After entering and confirming the PIN, moving down should focus the 'Enable Access Protection' button"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.pin.disable.button",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "After access protection is enabled, the page should switch to the 'Disable Access Protection' controls"
        )

        exitSettingsToSlideShow(app: app)
        openSettingsFromSlideShow(app: app)

        let pinCloseButton = app.buttons["pinEntry.close.button"]
        XCTAssertTrue(
            pinCloseButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "With access protection enabled, opening settings again should first show the PIN check sheet"
        )

        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Settings unlock")
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.item.playback",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After the correct PIN, the settings home should open"
        )
    }

    @MainActor
    func testTVOSAlbumCardAccessibilityFramesIgnoreCoverShape() throws {
        let app = try launchIntoFilterSummary()
        openAlbumFilter(from: app)
        waitForAlbumFilterReady(app: app)

        try AlbumCardSnapshot.assertFramesIgnoreCoverShape(in: app)
    }
}
extension FilterSummaryTVOSVisualUITests {

}
#endif
