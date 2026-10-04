import XCTest

#if os(tvOS)
extension FilterSummaryTVOSVisualUITests {
    @MainActor
    func testTVOSSettingsServerPageShowsFormAndStatusBanner() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.server",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.serverSteps,
            failureMessage: "Settings home should reliably reach the 'Server' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "firstboot.serverURL.row",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The server page should show the server URL input row"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "firstboot.apiKey.row",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The server page should show the API Key input row"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "firstboot.testConnection.button",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The server page should show the Test Connection button"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "server.apiKey.help.button",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The server page should show the API Key help entry"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.server.hero.summary",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Server page should show the connection status summary in the Hero area"
        )

        _ = waitForSettingsControl(
            app: app,
            identifier: "firstboot.serverURL.row",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "The server page should show the server URL input row"
        )
        let serverURLField = waitForSettingsControl(
            app: app,
            identifier: "firstboot.serverURL.field",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "The server page should expose the server URL text field itself"
        )
        waitForButtonToGainFocus(
            serverURLField,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the server page, default focus should land reliably on the server URL field"
        )

        assertTVOSServerSettingsAPIKeyHelpSheet(
            app: app,
            context: "tvOS server settings page",
            shouldVerifySimplifiedChineseContent: true,
            screenshotName: "tvos-settings-server-api-key-help-sheet-dark"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-server-page-dark")
    }

    @MainActor
    func testTVOSSettingsServerDetailTestConnectionAlertAppearsInline() throws {
        let app = try launchIntoSlideShow(extraLaunchEnvironment: [
            "UI_TEST_APP_STORE_SCREENSHOT_PREFILL_CONNECTION": "1",
            "UI_TEST_APP_STORE_SCREENSHOT_SERVER_URL": "foo://invalid-host",
            "UI_TEST_APP_STORE_SCREENSHOT_API_KEY": "ui-test-invalid-key"
        ])
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.server",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.serverSteps,
            failureMessage: "Settings home should reliably reach the 'Server' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.server.hero.summary",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The server detail page should show the server settings Hero"
        )

        let testConnectionButton = waitForSettingsControl(
            app: app,
            identifier: "firstboot.testConnection.button",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Server detail page should show the Test Connection button"
        )
        for _ in 0..<4 {
            if testConnectionButton.hasFocus { break }
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.shortFocusSettleSeconds))
        }
        waitForButtonToGainFocus(
            testConnectionButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.stateChangeTimeoutSeconds,
            failureMessage:
                "On the server detail page, direction keys should be able to focus the Test Connection button"
        )
        XCUIRemote.shared.press(.select)

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let alert = app.alerts["连接测试失败"]
        XCTAssertTrue(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            alert.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.stateChangeTimeoutSeconds),
            "Test Connection on server detail should show the error there at once, not after returning to settings root"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.server.hero.summary",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.briefElementTimeoutSeconds),
            "When the alert appears, the server detail page should still be underneath, not the settings root"
        )
        XCTAssertTrue(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            alert.staticTexts["服务器地址必须以 http 或 https 开头"].exists
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                || alert.staticTexts["服务器地址格式无效"].exists,
            "A prefilled invalid URL should trigger the local server URL validation error"
        )
    }

    @MainActor
    func testTVOSSettingsCachePageShowsAllCacheMetrics() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.cache",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.cacheSteps,
            failureMessage: "Settings home should reliably reach the 'Cache Management' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.cache.disk.row",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Cache page should show the 'Disk Cache' metric"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.cache.trackedURL.row",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Cache page should show the 'Tracked URLs' metric"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.cache.trackedState.row",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Cache page should show the 'Tracked States' metric"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.cache.runningTask.row",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Cache page should show the 'Running Tasks' metric"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.cache.clearDisk.button",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Cache page should show the clear disk cache button"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-cache-page-dark")
    }

    @MainActor
    func testTVOSSettingsCacheClearShowsConfirmationImmediately() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.cache",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.cacheSteps,
            failureMessage: "Settings home should reliably reach the 'Cache Management' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        let clearCacheButton = waitForSettingsControl(
            app: app,
            identifier: "settings.cache.clearDisk.button",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Cache page should show the 'Clear Disk Cache' button"
        )

        for _ in 0..<8 {
            if clearCacheButton.hasFocus || accessibilityValueString(for: clearCacheButton).contains("focused") {
                break
            }
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.remotePressSettleSeconds))
        }

        waitForButtonToGainFocus(
            clearCacheButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the cache page, direction keys should be able to focus the 'Clear Disk Cache' button"
        )

        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.stateChangeTimeoutSeconds) {
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                self.waitForElementWithLabelExists(app: app, label: "确认清理磁盘缓存", timeout: 0)
                    // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                    || app.alerts.element(boundBy: 0).exists
                    // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                    || self.waitForElementWithLabelExists(app: app, label: "清理", timeout: 0)
                    // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                    || self.waitForElementWithLabelExists(app: app, label: "取消", timeout: 0)
            },
            "After choosing 'Clear Disk Cache', a confirmation should pop up right away on the cache page"
        )
        XCTAssertTrue(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            waitForElementWithLabelExists(
                app: app, label: "清理", timeout: FilterSummaryTVOSVisualUITestsWaitTiming.stateChangeTimeoutSeconds),
            "The confirmation dialog should show the 'Clear' action button"
        )
        XCTAssertTrue(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            waitForElementWithLabelExists(
                app: app, label: "取消", timeout: FilterSummaryTVOSVisualUITestsWaitTiming.stateChangeTimeoutSeconds),
            "The confirmation dialog should show the 'Cancel' button"
        )
    }

    @MainActor
    func testTVOSSettingsAboutPageShowsVersionAndPlatformInfo() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.about",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.aboutSteps,
            failureMessage: "Settings home should reliably reach the 'About' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.appName.row",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the app name"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.version.row",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the version number"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.platform.row",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "About page should show the platform info"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.feedback.hint",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the feedback hint"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.feedback.email",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the support email row (existence only; the address text is not read)"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.unofficialNotice.hint",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the unofficial notice"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.privacyPolicy.link",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the Privacy Policy entry"
        )
        XCTAssertTrue(
            // ui-label-lookup: This lookup asserts the displayed feedback hint copy.
            app.staticTexts["提交问题前，建议先确认版本号与运行平台。"].waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the real feedback text, not placeholder text"
        )
        XCTAssertTrue(
            // ui-label-lookup: This lookup asserts the displayed privacy description copy.
            app.staticTexts["查看完整隐私政策与数据处理说明。"].waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the privacy policy description"
        )
        XCTAssertFalse(
            // ui-label-lookup: This lookup rejects obsolete displayed placeholder copy.
            app.staticTexts["后续会在这里补齐反馈入口和开源协议链接。"].waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.briefElementTimeoutSeconds),
            "About page should no longer show 'to be added later' placeholder text"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-about-page-dark")
    }

    @MainActor
    func testTVOSSettingsAboutPageFocusCanReachPrivacyAndOpenSourceEntries() throws {

        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.about",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.aboutSteps,
            failureMessage: "Settings home should reliably reach the 'About' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        let appInfoSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.appInfo.section",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should expose the 'App Info' focus area"
        )
        waitForButtonToGainFocus(
            appInfoSection,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the About page, the first focus should land on the 'App Info' section"
        )

        let unofficialNoticeSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.unofficialNotice.section",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should expose the 'Unofficial Notice' focus area"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            unofficialNoticeSection,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down from 'App Info', focus should reach the 'Unofficial Notice' section"
        )

        let feedbackSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.feedback.section",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should expose the 'Feedback & Support' focus area"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            feedbackSection,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down again, focus should reach the 'Feedback & Support' section"
        )

        let privacyPolicyLink = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should show the 'Privacy Policy' entry"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            privacyPolicyLink,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down again, focus should reach the 'Privacy Policy' entry"
        )

        let openSourceLink = waitForSettingsControl(
            app: app,
            identifier: "settings.about.opensource.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should show the 'Open Source Licenses' entry"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            openSourceLink,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down again, focus should reach the 'Open Source Licenses' entry"
        )

        attachScreenshot(app: app, name: "tvos-settings-about-page-bottom-focus-dark")

        XCUIRemote.shared.press(.up)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            privacyPolicyLink,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "Moving back up from 'Open Source Licenses', focus should return reliably to the 'Privacy Policy' entry"
        )
    }

    @MainActor
    func testTVOSSettingsPrivacyPolicyEntryOpensBundledPage() throws {

        let app = try launchIntoSlideShow(
            languageCode: "zh-Hans",
            localeIdentifier: "zh_CN"
        )
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.about",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.aboutSteps,
            failureMessage: "Settings home should reliably reach the 'About' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        let appInfoSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.appInfo.section",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the About page, the top 'App Info' focus area should be found first"
        )
        waitForButtonToGainFocus(
            appInfoSection,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the About page, the first focus should land on the 'App Info' section"
        )

        let privacyPolicyLink = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should show the 'Privacy Policy' entry"
        )

        for _ in 0..<3 {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.22)
        }

        waitForButtonToGainFocus(
            privacyPolicyLink,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "In the lower half of the About page, focus should land reliably on the 'Privacy Policy' entry"
        )

        XCUIRemote.shared.press(.select)

        let chineseLanguageButton = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.language.zh.button",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Privacy policy page should show the 'Chinese' language button"
        )
        let englishLanguageButton = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.language.en.button",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Privacy policy page should show the 'English' language button"
        )
        let firstPolicySection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.section.0",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Privacy policy page should show at least the first body section"
        )
        XCTAssertTrue(
            firstPolicySection.label.contains("适用范围"),
            "tvOS privacy policy page should show the Chinese text first, not only the English version"
        )

        waitForButtonToGainFocus(
            chineseLanguageButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "On the privacy policy page, default focus should land directly on the 'Chinese' language button"
        )

        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            firstPolicySection,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down from the language button, focus should enter the privacy policy text"
        )

        attachScreenshot(app: app, name: "tvos-settings-privacy-policy-page-dark")

        XCUIRemote.shared.press(.up)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            chineseLanguageButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving back up from the text, focus should return to the current language button"
        )

        XCUIRemote.shared.press(.right)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            englishLanguageButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving right from the Chinese button, focus should reach the English button"
        )

        XCUIRemote.shared.press(.select)
        waitForFocusVisualSettle(seconds: 0.22)

        let englishFirstPolicySection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.section.0",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After choosing English, the privacy policy page should still show the first body section"
        )
        XCTAssertTrue(
            englishFirstPolicySection.label.contains("Scope"),
            "After choosing English, the first section should switch to English instead of staying in Chinese"
        )

        let tablePolicySection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.section.2",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "The privacy policy data processing section should remain a separate focusable section"
        )

        for _ in 0..<3 {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.22)
        }

        waitForButtonToGainFocus(
            tablePolicySection,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down again, focus should reach the section with the data processing table"
        )

        attachScreenshot(app: app, name: "tvos-settings-privacy-policy-table-section-dark")
    }

    @MainActor
    func testTVOSSettingsAccessProtectionScreenshotDark() throws {
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
            failureMessage: "In dark mode, opening 'Access Protection' should show the PIN input entry"
        )
        waitForButtonToGainFocus(
            enablePinInput,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "In dark mode, on the access protection page default focus should be on the 'Set PIN' input entry"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-access-protection-page-dark")
    }

    @MainActor
    func testTVOSSettingsServerPageScreenshotLight() throws {
        let app = try launchIntoSlideShow(colorScheme: "light")
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.server",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.serverSteps,
            failureMessage:
                "In light mode, the settings home should reliably reach the 'Server' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.server.hero.summary",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "In light mode, the server page should show the connection status summary in the Hero area"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "server.apiKey.help.button",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "In light mode, the server page should show the API Key help entry"
        )

        _ = waitForSettingsControl(
            app: app,
            identifier: "firstboot.serverURL.row",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In light mode, the server page should show the server URL input row"
        )
        let serverURLField = waitForSettingsControl(
            app: app,
            identifier: "firstboot.serverURL.field",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In light mode, the server page should expose the server URL text field itself"
        )
        waitForButtonToGainFocus(
            serverURLField,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In light mode, on the server page default focus should be on the server URL field"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-server-page-light")
    }

    @MainActor
    func testTVOSSettingsServerPageEnglishLocalizationScreenshotLight() throws {

        let app = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.server",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.serverSteps,
            failureMessage: "In English, the settings home should reliably reach the 'Server' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        let serverURLField = waitForSettingsControl(
            app: app,
            identifier: "firstboot.serverURL.field",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In English, the server page should expose the server URL text field itself"
        )
        waitForButtonToGainFocus(
            serverURLField,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In English, on the server page default focus should be on the server URL field"
        )

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "server.apiKey.help.button",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "In English, the server page should show the API Key help entry"
        )
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: app, label: "Test Connection",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "In English, the action buttons should still show English text"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-server-page-english-light")
    }

    @MainActor
    func testTVOSSettingsCachePageScreenshotLight() throws {
        let app = try launchIntoSlideShow(colorScheme: "light")
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.cache",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.cacheSteps,
            failureMessage:
                "In light mode, settings home should reliably reach the 'Cache Management' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.cache.disk.row",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "In light mode, the cache page should show the metrics area"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-cache-page-light")
    }

    @MainActor
    func testTVOSSettingsAboutPageScreenshotLight() throws {
        let app = try launchIntoSlideShow(colorScheme: "light")
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.about",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.aboutSteps,
            failureMessage:
                "In light mode, the settings home should reliably reach the 'About' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.version.row",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "In light mode, the About page should show the version info"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.unofficialNotice.hint",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "In light mode, the About page should show the unofficial notice"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-about-page-light")
    }

    @MainActor
    func testTVOSSettingsOpenSourceLicensesPageScreenshotDark() throws {

        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.about",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.aboutSteps,
            failureMessage: "Settings home should reliably reach the 'About' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        let openSourceLink = waitForSettingsControl(
            app: app,
            identifier: "settings.about.opensource.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should show the 'Open Source Licenses' entry"
        )
        let appInfoSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.appInfo.section",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should expose the 'App Info' focus area"
        )
        let unofficialNoticeSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.unofficialNotice.section",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should expose the 'Unofficial Notice' focus area"
        )
        let feedbackSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.feedback.section",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should expose the 'Feedback & Support' focus area"
        )
        let privacyPolicyLink = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should show the 'Privacy Policy' entry"
        )
        waitForButtonToGainFocus(
            appInfoSection,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the About page, default focus should land on the 'App Info' section"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            unofficialNoticeSection,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down from 'App Info', focus should reach the 'Unofficial Notice' section"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            feedbackSection,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down again, focus should reach the 'Feedback & Support' section"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            privacyPolicyLink,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down again, focus should reach the 'Privacy Policy' entry"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            openSourceLink,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down from 'Privacy Policy' should reliably focus the 'Open Source Licenses' entry"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-about-open-source-entry-dark")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.about.opensource.sdwebimage.summary",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "Open source licenses page should show the SDWebImage component info"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.about.opensource.sdwebimageswiftui.summary",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "Open source licenses page should show the SDWebImageSwiftUI component info"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.about.opensource.sharedLicense",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "Open source licenses page should show the shared license text"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-open-source-page-dark")
    }
}
extension FilterSummaryTVOSVisualUITests {

}
#endif
