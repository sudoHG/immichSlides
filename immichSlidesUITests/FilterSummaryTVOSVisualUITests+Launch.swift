import XCTest

#if os(tvOS)
extension FilterSummaryTVOSVisualUITests {
    func requireTVOSDestination(file: StaticString = #filePath, line: UInt = #line) throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            throw XCTSkip(
                "The current target is not tvOS (detected: \(UIDevice.current.model)); skipping tvOS UI tests.")
        }
    }

    func launchApp(
        shouldResetState: Bool,
        shouldSeedFilterSelection: Bool = false,
        colorScheme: String? = nil,
        dynamicTypeSize: String? = nil,
        shouldDisablePlaybackEntryHint: Bool = true,
        shouldUseLongPersonNames: Bool = false,
        shouldForceAutoPlayOff: Bool = false,
        exifDiagnosticAlbumID: String? = nil,
        languageCode: String? = nil,
        localeIdentifier: String? = nil
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
        if let dynamicTypeSize {

            app.launchEnvironment["UI_TEST_DYNAMIC_TYPE_SIZE"] = dynamicTypeSize
        }
        if shouldDisablePlaybackEntryHint {

            app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        }
        if shouldUseLongPersonNames {

            app.launchEnvironment["UI_TEST_FORCE_LONG_PERSON_NAMES"] = "1"
        }
        if shouldForceAutoPlayOff {

            app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        }
        if let exifDiagnosticAlbumID {

            app.launchEnvironment["UI_TEST_EXIF_DIAGNOSTIC_ALBUM_ID"] = exifDiagnosticAlbumID
        }
        if let languageCode, let localeIdentifier {

            app.launchArguments += [
                "-AppleLanguages", "(\(languageCode))",
                "-AppleLocale", localeIdentifier
            ]
        }
        return app
    }

    @MainActor
    func launchIntoFilterSummary(
        colorScheme: String = "dark",
        dynamicTypeSize: String? = nil,
        shouldDisablePlaybackEntryHint: Bool = true,
        shouldUseLongPersonNames: Bool = false,
        shouldForceAutoPlayOff: Bool = false,
        exifDiagnosticAlbumID: String? = nil,
        shouldPrepareFilterSummaryVisuals: Bool = true,
        languageCode: String? = nil,
        localeIdentifier: String? = nil,
        extraLaunchEnvironment: [String: String] = [:]
    ) throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = launchApp(
            shouldResetState: true,
            shouldSeedFilterSelection: true,
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            shouldDisablePlaybackEntryHint: shouldDisablePlaybackEntryHint,
            shouldUseLongPersonNames: shouldUseLongPersonNames,
            shouldForceAutoPlayOff: shouldForceAutoPlayOff,
            exifDiagnosticAlbumID: exifDiagnosticAlbumID,
            languageCode: languageCode,
            localeIdentifier: localeIdentifier
        )
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        if shouldPrepareFilterSummaryVisuals {
            try requireServerAlbumAndPerson()
            app.launchEnvironment["UI_TEST_PREPARE_FILTER_SUMMARY_VISUAL_SELECTIONS"] = "1"
        }
        for (key, value) in extraLaunchEnvironment {
            app.launchEnvironment[key] = value
        }
        app.launch()

        let expectedOnboardingTitles = expectedLocalizedTextCandidates(
            languageCode: languageCode,
            chinese: "首次设置向导",
            english: "Setup Wizard"
        )
        let expectedModeSelectionPageTitles = expectedLocalizedTextCandidates(
            languageCode: languageCode,
            chinese: "选择播放方式",
            english: "Choose Playback Mode"
        )
        let expectedFilterSummaryPageTitles = expectedLocalizedTextCandidates(
            languageCode: languageCode,
            chinese: "设置照片范围",
            english: "Set Photo Range"
        )

        assertModeSelectionInlineOnboardingHeader(
            app: app,
            expectedModeSelectionOnboardingTitles: expectedOnboardingTitles,
            expectedModeSelectionPageTitles: expectedModeSelectionPageTitles
        )

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.connectionTimeoutSeconds),
            "After injecting the test server config, the app should go straight to the mode selection page")
        startFilteredFlowFromModeSelection(app: app)

        if shouldPrepareFilterSummaryVisuals {
            assertFilterSummaryMinimalOnboardingHeader(
                app: app,
                expectedFilterSummaryOnboardingTitles: expectedOnboardingTitles,
                expectedFilterSummaryPageTitles: expectedFilterSummaryPageTitles
            )
        } else {
            XCTAssertTrue(
                app.buttons["filterSummary.startPlayback.button"].waitForExistence(
                    timeout: FilterSummaryTVOSVisualUITestsWaitTiming.screenTransitionTimeoutSeconds),
                "Without visual prep, the filter summary page should still open and show the Start Playback button"
            )
        }

        let albumButton = app.buttons["filterSummary.album.button"]
        let peopleButton = app.buttons["filterSummary.person.button"]
        XCTAssertTrue(
            albumButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds))
        XCTAssertTrue(
            peopleButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds))
        return app
    }

    @MainActor
    func launchIntoModeSelection(
        colorScheme: String = "dark",
        dynamicTypeSize: String? = nil,
        languageCode: String? = nil,
        localeIdentifier: String? = nil
    ) throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = launchApp(
            shouldResetState: true,
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            languageCode: languageCode,
            localeIdentifier: localeIdentifier
        )
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launch()

        let expectedOnboardingTitles = expectedLocalizedTextCandidates(
            languageCode: languageCode,
            chinese: "首次设置向导",
            english: "Setup Wizard"
        )
        let expectedModeSelectionPageTitles = expectedLocalizedTextCandidates(
            languageCode: languageCode,
            chinese: "选择播放方式",
            english: "Choose Playback Mode"
        )

        assertModeSelectionInlineOnboardingHeader(
            app: app,
            expectedModeSelectionOnboardingTitles: expectedOnboardingTitles,
            expectedModeSelectionPageTitles: expectedModeSelectionPageTitles
        )

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.connectionTimeoutSeconds),
            "After injecting the test server config, the app should go straight to the mode selection page")
        return app
    }

    func startFilteredFlowFromModeSelection(app: XCUIApplication) {
        let modeFilteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(
            modeFilteredButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)

        let modeContinueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            modeContinueButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(modeContinueButton.isEnabled)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            app.buttons["filterSummary.startPlayback.button"].waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.screenTransitionTimeoutSeconds))
    }

    @MainActor
    func launchIntoSlideShow(
        colorScheme: String = "dark",
        dynamicTypeSize: String? = nil,
        shouldDisablePlaybackEntryHint: Bool = true,
        shouldForceAutoPlayOff: Bool = false,
        exifDiagnosticAlbumID: String? = nil,
        shouldPrepareFilterSummaryVisuals: Bool = true,
        languageCode: String? = nil,
        localeIdentifier: String? = nil,
        extraLaunchEnvironment: [String: String] = [:]
    ) throws -> XCUIApplication {
        let app = try launchIntoFilterSummary(
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            shouldDisablePlaybackEntryHint: shouldDisablePlaybackEntryHint,
            shouldForceAutoPlayOff: shouldForceAutoPlayOff,
            exifDiagnosticAlbumID: exifDiagnosticAlbumID,
            shouldPrepareFilterSummaryVisuals: shouldPrepareFilterSummaryVisuals,
            languageCode: languageCode,
            localeIdentifier: localeIdentifier,
            extraLaunchEnvironment: extraLaunchEnvironment
        )
        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startPlaybackButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Filter summary page should show the 'Start Playback' button")

        if startPlaybackButton.hasFocus == false {
            // tvOS UI tests cannot tap directly; move focus first, then press Select.

            for _ in 0..<8 {
                XCUIRemote.shared.press(.down)
                RunLoop.current.run(
                    until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.remotePressSettleSeconds))
                if startPlaybackButton.hasFocus {
                    break
                }
            }
        }

        XCTAssertTrue(
            startPlaybackButton.hasFocus,
            "On the filter summary page, focus should be able to move to the 'Start Playback' button")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: TestWait.seconds(.infrastructure(18))),
            "After starting playback, the playback page should open and show the control bar"
        )
        return app
    }

    @MainActor
    func captureTVOSExifDiagnosticSlides(
        app: XCUIApplication,
        expectedCount: Int,
        screenshotNamePrefix: String = "tvos-exif-diagnostic"
    ) {
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.screenTransitionTimeoutSeconds),
            "The tvOS playback page should show the Play/Pause button")
        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds) {
                ((playPauseButton.value as? String) ?? "").lowercased() == "play"
            },
            "Autoplay should be off in tvOS EXIF diagnostic mode so photos do not advance during screenshots"
        )

        for index in 0..<expectedCount {
            XCTAssertTrue(
                waitForTVOSExifToneReady(
                    app: app, timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
                "EXIF text color sampling should be done before the screenshot of photo \(index + 1)"
            )

            let toneLabel = currentTVOSExifToneDebugLabel(app: app)
            attachScreenshot(
                app: app,
                name: "\(screenshotNamePrefix)-\(String(format: "%02d", index + 1))-\(toneLabel)"
            )

            guard index < expectedCount - 1 else { continue }

            let indexProbe = app.otherElements["slideshow.control.indexProbe"]
            let currentIndexValue = indexProbe.exists ? accessibilityValueString(for: indexProbe) : ""
            let currentDateLabel = currentTVOSExifDateLabel(app: app)
            ensureTVOSSlideshowControlBarVisible(app: app)
            moveFocusToTVOSSlideshowNextButton(app: app)
            XCUIRemote.shared.press(.select)

            if !currentIndexValue.isEmpty {
                XCTAssertTrue(
                    waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds) {
                        self.accessibilityValueString(for: indexProbe) != currentIndexValue
                    },
                    "After next, the playback index probe should change so the same photo is not captured twice"
                )
            } else if let currentDateLabel {
                XCTAssertTrue(
                    waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds) {
                        self.currentTVOSExifDateLabel(app: app) != currentDateLabel
                    },
                    "After next, the EXIF date at the top should change so the same photo is not captured twice"
                )
            } else {
                RunLoop.current.run(
                    until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.screenSettleSeconds))
            }
        }
    }

    func waitForTVOSExifToneReady(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let readyFlag = app.descendants(matching: .any)["slideshow.exifForegroundTone.ready"]
        return readyFlag.waitForExistence(timeout: timeout)
    }

    func currentTVOSExifToneDebugLabel(app: XCUIApplication) -> String {
        let toneFlag = app.descendants(matching: .any)["slideshow.exifForegroundTone.flag"]
        XCTAssertTrue(
            toneFlag.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "tvOS playback page should expose the current EXIF text color diagnostic flag")

        let candidates = [
            toneFlag.label,
            toneFlag.value as? String ?? ""
        ]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "unknownTone"
    }

    func currentTVOSExifDateLabel(app: XCUIApplication) -> String? {

        let pattern = #"^\d{4}-\d{2}-\d{2}$"#
        // ui-label-lookup: This predicate validates displayed EXIF date formatting.
        let predicate = NSPredicate(format: "label MATCHES %@", pattern)
        let match = app.staticTexts.matching(predicate).firstMatch
        return match.exists ? match.label : nil
    }

    @MainActor
    func ensureTVOSSlideshowControlBarVisible(app: XCUIApplication) {
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        if playPauseButton.exists { return }

        XCUIRemote.shared.press(.up)
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.elementAppearanceDeadlineSeconds),
            "Once hidden, the control bar should wake again with a direction key"
        )
    }

    @MainActor
    func moveFocusToTVOSSlideshowNextButton(app: XCUIApplication) {
        let nextButton = app.buttons["slideshow.control.next.button"]
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "Playback page should show the next button")

        for _ in 0..<4 {
            if nextButton.hasFocus || accessibilityValueString(for: nextButton).contains("focused") {
                return
            }
            XCUIRemote.shared.press(.right)
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.focusSettleSeconds))
        }

        waitForButtonToGainFocus(
            nextButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.shortInteractionTimeoutSeconds,
            failureMessage: "During per-photo EXIF screenshots, focus should move to the next button"
        )
    }

    @MainActor
    func enterRandomPlaybackFromModeSelection(app: XCUIApplication) throws {
        let randomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(
            randomButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.connectionTimeoutSeconds),
            "After injecting the public fixture, the app must reach the mode selection page")
        if randomButton.hasFocus == false {
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.focusSettleSeconds))
        }
        XCUIRemote.shared.press(.select)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "After choosing random playback, the Continue button must be shown")
        XCTAssertTrue(continueButton.isEnabled, "After choosing random playback, the Continue button must be enabled")
        for _ in 0..<2 where continueButton.hasFocus == false {
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.focusSettleSeconds))
        }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["slideshow.control.playPause.button"].waitForExistence(
                timeout: TestWait.seconds(.infrastructure(30))),
            "The control bar must appear after random playback starts"
        )
    }

    @MainActor
    func assertControlBarCanWakeFromHiddenState(
        app: XCUIApplication,
        scenarioName: String,
        screenshotName: String,
        trigger: (XCUIApplication) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "\(scenarioName): the control bar should be visible after entering the playback page",
            file: file,
            line: line
        )

        waitForElementToDisappear(
            settingsButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.screenTransitionDeadlineSeconds,
            failureMessage:
                "\(scenarioName): the control bar should hide on its own before waking from hidden can be verified",
            file: file,
            line: line
        )
        let wakeReceiver = app.descendants(matching: .any)["slideshow.hiddenWakeReceiver"]
        XCTAssertTrue(
            wakeReceiver.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.stateChangeDeadlineSeconds)
                || settingsButton.exists == false,
            "\(scenarioName): the wake receiver should appear after hiding",
            file: file,
            line: line
        )
        let focusDeadline = Date().addingTimeInterval(TestWait.seconds(.product(4)))
        while Date() < focusDeadline, wakeReceiver.exists, wakeReceiver.hasFocus == false {
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.focusPollSeconds))
        }

        let beforePNG = app.screenshot().pngRepresentation
        let beforeAttachment = XCTAttachment(data: beforePNG, uniformTypeIdentifier: "public.png")
        beforeAttachment.name = "\(screenshotName)-before"
        beforeAttachment.lifetime = .keepAlways
        add(beforeAttachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(beforePNG, name: "\(screenshotName)-before")
        trigger(app)

        XCTAssertTrue(
            settingsButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.elementAppearanceDeadlineSeconds),
            "\(scenarioName): the hidden control bar should wake successfully",
            file: file,
            line: line
        )
        let afterPNG = app.screenshot().pngRepresentation
        let afterAttachment = XCTAttachment(data: afterPNG, uniformTypeIdentifier: "public.png")
        afterAttachment.name = "\(screenshotName)-after"
        afterAttachment.lifetime = .keepAlways
        add(afterAttachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(afterPNG, name: "\(screenshotName)-after")
    }

    @MainActor
    func openSettingsFromSlideShow(app: XCUIApplication) {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page should show the settings button")

        for _ in 0..<5 {
            if settingsButton.hasFocus { break }
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.remotePressSettleSeconds))
        }

        waitForButtonToGainFocus(
            settingsButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "Before opening settings, focus should return reliably to the leftmost settings button"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForAnySettingsSurface(
                app: app, timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds),
            "Pressing Select on the settings button should open the settings page")
    }

    @MainActor
    func exitSettingsToSlideShow(app: XCUIApplication, maxMenuPresses: Int = 5) {
        for _ in 0..<maxMenuPresses {
            if app.buttons["slideshow.control.settings.button"].exists {
                return
            }
            XCUIRemote.shared.press(.menu)
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.navigationFocusSettleSeconds))
        }

        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds) {
                if app.buttons["slideshow.control.settings.button"].exists {
                    return true
                }
                XCUIRemote.shared.press(.down)
                RunLoop.current.run(
                    until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.focusSettleSeconds))
                return app.buttons["slideshow.control.settings.button"].exists
            },
            "Should be able to return from settings to playback and wake the control bar"
        )
    }
}
#endif
