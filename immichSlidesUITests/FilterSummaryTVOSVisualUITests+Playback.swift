import XCTest

#if os(tvOS)
extension FilterSummaryTVOSVisualUITests {
    @MainActor
    func testTVOSExifAlbumDiagnosticScreenshots() throws {
        let photoCount = try requireExifDiagnosticAlbumAssetCount()
        // The EXIF panel belongs to single-photo scenes; SmartFill, the default, shows several photos at once.
        let app = try launchIntoSlideShow(
            shouldForceAutoPlayOff: true,
            exifDiagnosticAlbumID: try requireExifDiagnosticAlbumID(),
            shouldPrepareFilterSummaryVisuals: false,
            extraLaunchEnvironment: ["UI_TEST_FORCE_PLAYBACK_DISPLAY_MODE": "singlePhoto"]
        )

        captureTVOSExifDiagnosticSlides(
            app: app,
            expectedCount: photoCount
        )
    }

    @MainActor
    func testTVOSSlideShowControlBarCanWakeByAnyDirectionalPress() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The four-direction key test must run on tvOS.")
            return
        }

        let input = try requireStrictE2EInput()
        let app = launchApp(shouldResetState: true, shouldDisablePlaybackEntryHint: true)
        app.launchEnvironment["UI_TEST_SERVER_URL"] = input.serverURL
        app.launchEnvironment["UI_TEST_API_KEY"] = input.publicKey
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launch()
        defer { app.terminate() }

        try enterRandomPlaybackFromModeSelection(app: app)

        let directionalScenarios: [(name: String, button: XCUIRemote.Button)] = [
            ("up", .up),
            ("down", .down),
            ("left", .left),
            ("right", .right)
        ]

        for scenario in directionalScenarios {
            try assertControlBarCanWakeFromHiddenState(
                app: app,
                scenarioName: "Arrow key \(scenario.name)",
                screenshotName: "tvos-slideshow-controlbar-wakeup-by-direction-\(scenario.name)"
            ) { _ in
                XCUIRemote.shared.press(scenario.button)
            }
        }
    }

    @MainActor
    func testTVOSSlideShowInitialDefaultFocusIsPlayPause() throws {
        let app = try launchIntoSlideShow()
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]

        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "After entering the playback page, the Play/Pause button should be shown")

        waitForButtonToGainFocus(
            playPauseButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage:
                "On first entering the tvOS playback page, default focus should land on the Play/Pause button"
        )
        attachScreenshot(app: app, name: "tvos-slideshow-default-focus-playpause")
    }

    @MainActor
    func testTVOSSlideShowPlaybackEntryHintScreenshot() throws {
        let app = try launchIntoSlideShow(shouldDisablePlaybackEntryHint: false)
        let entryHintTitle = app.staticTexts["slideshow.entryHint.title"]
        let entryHintAction = app.otherElements["slideshow.entryHint.action"]
        let entryHintKeycap = app.otherElements["slideshow.entryHint.keycap"]
        let settingsButton = app.buttons["slideshow.control.settings.button"]

        XCTAssertTrue(
            entryHintTitle.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "On first reaching the playback page after the first-launch flow, the one-time tip should appear"
        )
        XCTAssertEqual(
            entryHintTitle.label,
            "在这里调整照片播放范围和速度"
        )
        XCTAssertTrue(
            entryHintAction.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.readbackTimeoutSeconds),
            "The tip bubble should show a separate action sentence that helps the user understand the next step"
        )
        XCTAssertEqual(
            entryHintAction.label,
            "按 向下键 隐藏提示"
        )
        XCTAssertTrue(
            entryHintKeycap.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.readbackTimeoutSeconds),
            "The 'Down key' in the tip bubble should show as a separate keycap label"
        )
        XCTAssertEqual(entryHintKeycap.label, "向下键")
        waitForButtonToGainFocus(
            settingsButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage:
                "First-run tip: focus should start on the settings button so the user sees what the bubble points to"
        )

        waitForPlaybackEntryHintAnimationToSettle()
        attachScreenshot(app: app, name: "tvos-slideshow-entry-hint")
    }

    @MainActor
    func testTVOSSlideShowPlaybackEntryHintEnglishScreenshot() throws {
        let app = try launchIntoSlideShow(
            shouldDisablePlaybackEntryHint: false,
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        let entryHintTitle = app.staticTexts["slideshow.entryHint.title"]
        let entryHintAction = app.otherElements["slideshow.entryHint.action"]
        let entryHintKeycap = app.otherElements["slideshow.entryHint.keycap"]
        let settingsButton = app.buttons["slideshow.control.settings.button"]

        XCTAssertTrue(
            entryHintTitle.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "In English, first entering the playback page should also show the one-time tip"
        )
        XCTAssertEqual(
            entryHintTitle.label,
            "Adjust photo range and speed here"
        )
        XCTAssertTrue(
            entryHintAction.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.readbackTimeoutSeconds),
            "In English, the action sentence should also be shown in full"
        )
        XCTAssertEqual(
            entryHintAction.label,
            "Press Down to hide this tip"
        )
        XCTAssertTrue(
            entryHintKeycap.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.readbackTimeoutSeconds),
            "In English, the Down key should still show as a separate keycap label"
        )
        XCTAssertEqual(entryHintKeycap.label, "Down")
        waitForButtonToGainFocus(
            settingsButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage:
                "In English, when the first-run tip appears, default focus should still land on the settings button"
        )

        waitForPlaybackEntryHintAnimationToSettle()
        attachScreenshot(app: app, name: "tvos-slideshow-entry-hint-en")
    }

    @MainActor
    func testTVOSSlideShowPlaybackEntryHintJapaneseScreenshot() throws {
        let app = try launchIntoSlideShow(
            shouldDisablePlaybackEntryHint: false,
            languageCode: "ja",
            localeIdentifier: "ja_JP"
        )
        let entryHintTitle = app.staticTexts["slideshow.entryHint.title"]
        let entryHintAction = app.otherElements["slideshow.entryHint.action"]
        let entryHintKeycap = app.otherElements["slideshow.entryHint.keycap"]
        let settingsButton = app.buttons["slideshow.control.settings.button"]

        XCTAssertTrue(
            entryHintTitle.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds))
        XCTAssertEqual(entryHintTitle.label, "ここで写真の範囲と速度を調整します")
        XCTAssertTrue(
            entryHintAction.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.readbackTimeoutSeconds))
        XCTAssertEqual(entryHintAction.label, "下キーを押すとヒントが閉じます")
        XCTAssertTrue(
            entryHintKeycap.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.readbackTimeoutSeconds))
        XCTAssertEqual(entryHintKeycap.label, "下キー")
        waitForButtonToGainFocus(
            settingsButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "When the Japanese tip appears, the settings button should still get default focus"
        )

        waitForPlaybackEntryHintAnimationToSettle()
        attachScreenshot(app: app, name: "ja-tvos-slideshow-entry-hint")
    }

    @MainActor
    func testTVOSSlideShowPlaybackEntryHintDismissesHintAndControlBarWithDown() throws {
        let app = try launchIntoSlideShow(shouldDisablePlaybackEntryHint: false)
        let entryHintBanner = app.otherElements["slideshow.entryHint.banner"]
        let settingsButton = app.buttons["slideshow.control.settings.button"]

        XCTAssertTrue(
            entryHintBanner.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "The first-run tip state should show a bubble anchored to the settings button")
        waitForButtonToGainFocus(
            settingsButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "In the first-run tip state, default focus should land on the settings button"
        )

        XCUIRemote.shared.press(.down)

        waitForElementToDisappear(
            entryHintBanner,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.stateChangeDeadlineSeconds,
            failureMessage: "After pressing Down, the tip bubble should disappear immediately"
        )
        waitForElementToDisappear(
            settingsButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.stateChangeDeadlineSeconds,
            failureMessage: "After pressing Down, the bottom control bar should hide too"
        )
    }

    @MainActor
    func testTVOSSlideShowPlaybackEntryHintShowsOnlyOncePerOnboardingFlow() throws {
        let app = try launchIntoSlideShow(shouldDisablePlaybackEntryHint: false)
        let entryHint = app.staticTexts["slideshow.entryHint.title"]

        XCTAssertTrue(
            entryHint.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "On first entering the playback page, the one-time tip should appear"
        )

        openSettingsFromSlideShow(app: app)
        exitSettingsToSlideShow(app: app)

        XCTAssertFalse(
            entryHint.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.readbackDeadlineSeconds),
            "The one-time tip should not reappear on return from settings to playback in the same first-launch flow"
        )
    }

    @MainActor
    func testTVOSSlideShowHasNoBackButtonScreenshot() throws {
        let app = try launchIntoSlideShow()
        let settingsButton = app.buttons["slideshow.control.settings.button"]

        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(18))),
            "After entering the playback page, the settings entry in the bottom control bar should be visible")
        XCTAssertFalse(
            app.buttons["global.back.button"].exists,
            "The playback page must not show a back button in the top-left corner")

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-slideshow-no-back-button")
    }

    @MainActor
    func testTVOSSlideShowPlayPauseCanToggleAndWakeControlBar() throws {
        let app = try launchIntoSlideShow()
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "After entering the playback page, the Play/Pause button should be visible")

        let initialValue = (playPauseButton.value as? String) ?? ""
        XCTAssertFalse(
            initialValue.isEmpty, "The Play/Pause button should expose its current state value (play or pause)")

        waitForElementToDisappear(
            playPauseButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.screenTransitionDeadlineSeconds,
            failureMessage: "The control bar should hide on its own before the Play/Pause wake path is verified"
        )

        // Play/Pause while the bar is hidden should toggle autoplay and bring back the control bar.
        XCUIRemote.shared.press(.playPause)

        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.elementAppearanceDeadlineSeconds),
            "Pressing Play/Pause while the control bar is hidden should wake the bar and show the playback state"
        )

        let updatedValue = (playPauseButton.value as? String) ?? ""
        XCTAssertNotEqual(
            updatedValue,
            initialValue,
            "After pressing Play/Pause, the playback state should toggle (play <-> pause)"
        )
        attachScreenshot(app: app, name: "tvos-slideshow-controlbar-wakeup-by-playpause")
    }

    @MainActor
    func testTVOSSlideShowWakeReturnsFocusToPlayPause() throws {
        let app = try launchIntoSlideShow()
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]

        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "After entering the playback page, the Play/Pause button should be visible")
        waitForButtonToGainFocus(
            playPauseButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "When the playback page first opens, focus should land on the Play/Pause button"
        )

        // Wake as soon as the bar starts hiding: a press during the fade-out is the hardest case for focus.
        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.screenTransitionDeadlineSeconds) {
                !playPauseButton.exists
            },
            "The control bar must hide on its own before it can be woken"
        )

        XCUIRemote.shared.press(.up)

        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.elementAppearanceDeadlineSeconds),
            "Pressing a direction key while the control bar is hidden should wake the bar first"
        )
        waitForButtonToGainFocus(
            playPauseButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "After the control bar wakes again, focus should return to the Play/Pause button"
        )
        attachScreenshot(app: app, name: "tvos-slideshow-wake-focus-playpause")

        // Then wake a bar that has fully faded out, the path most presses take. The invisible wake receiver takes
        // focus as the 0.3-second fade-out starts, so it has to keep focus for longer than the fade.
        let wakeReceiver = app.otherElements["slideshow.hiddenWakeReceiver"]
        var receiverFocusedSince: Date?
        // The bar hides 8 seconds after the first wake; the wait also covers the fade and the focus hold.
        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.connectionDeadlineSeconds) {
                guard !playPauseButton.exists, wakeReceiver.exists, wakeReceiver.hasFocus else {
                    receiverFocusedSince = nil
                    return false
                }
                let focusedSince = receiverFocusedSince ?? Date()
                receiverFocusedSince = focusedSince
                return Date().timeIntervalSince(focusedSince) >= TestWait.seconds(.product(0.6))
            },
            "The control bar must hide on its own again and leave focus on the wake receiver"
        )
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.elementAppearanceDeadlineSeconds),
            "A directional press must bring back a fully hidden control bar"
        )
        waitForButtonToGainFocus(
            playPauseButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "Waking a fully hidden control bar must focus Play/Pause"
        )
    }

    @MainActor
    func testTVOSSlideShowControlBarFocusStatesScreenshot() throws {
        let app = try launchIntoSlideShow()
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        let previousButton = app.buttons["slideshow.control.previous.button"]
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        let nextButton = app.buttons["slideshow.control.next.button"]

        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page should show the settings button")
        XCTAssertTrue(
            previousButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page should show the previous button")
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page should show the Play/Pause button")
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page should show the next button")

        for _ in 0..<5 {
            if settingsButton.hasFocus { break }
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.remotePressSettleSeconds))
        }

        waitForButtonToGainFocus(
            settingsButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "The control bar should be able to bring focus to the settings button (far left)"
        )
        attachScreenshot(app: app, name: "tvos-slideshow-controlbar-focus-settings")

        XCTAssertFalse(
            previousButton.isEnabled,
            "At the initial history boundary, previous should be disabled and skipped in the tvOS focus path")

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            playPauseButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage:
                "Previous is disabled at the initial history boundary, so moving right should jump focus to Play/Pause"
        )
        attachScreenshot(app: app, name: "tvos-slideshow-controlbar-focus-playpause")

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            nextButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "Moving right again, focus should reach the next button"
        )
        attachScreenshot(app: app, name: "tvos-slideshow-controlbar-focus-next")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds) {
                previousButton.isEnabled
            },
            "One next should create history to go back to and enable previous again"
        )

        XCUIRemote.shared.press(.left)
        waitForButtonToGainFocus(
            playPauseButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "Moving left from next, focus should return to the Play/Pause button"
        )

        XCUIRemote.shared.press(.left)
        waitForButtonToGainFocus(
            previousButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "Once history exists, moving left again should reach the previous button"
        )
        attachScreenshot(app: app, name: "tvos-slideshow-controlbar-focus-previous")
    }

    @MainActor
    func testTVOSSlideShowControlBarStaysWhileFocusKeepsMoving() throws {
        let app = try launchIntoSlideShow()
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        let nextButton = app.buttons["slideshow.control.next.button"]

        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page should show the Play/Pause button")

        // The auto-hide timer starts only after the first preload finishes. Waiting for the bar to hide on its own
        // proves the timer is running; the wake press then restarts it, so the presses below are measured against a
        // live timer however slow the first download was.
        waitForElementToDisappear(
            playPauseButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.screenTransitionDeadlineSeconds,
            failureMessage: "The control bar should hide on its own before focus movement is verified"
        )
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.elementAppearanceDeadlineSeconds),
            "A directional press should wake the hidden control bar")
        waitForButtonToGainFocus(
            playPauseButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "After waking, focus should land on the Play/Pause button"
        )

        // Each press below lands well inside the 8 second delay, so together they must keep the bar up for longer
        // than the delay.
        var isTargetingNext = true
        for _ in 0..<8 {
            XCUIRemote.shared.press(isTargetingNext ? .right : .left)
            waitForButtonToGainFocus(
                isTargetingNext ? nextButton : playPauseButton,
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
                failureMessage: "Each remote press should move focus along the control bar"
            )
            XCTAssertTrue(
                TestWait.observe(seconds: 1.5) { playPauseButton.exists },
                "The control bar must stay visible while the remote keeps moving focus along it")
            isTargetingNext.toggle()
        }
    }

    @MainActor
    func testTVOSSlideShowControlBarLightModeContrastScreenshot() throws {
        let app = try launchIntoSlideShow(colorScheme: "light")
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Light mode playback page should show the control bar")

        for _ in 0..<5 {
            if settingsButton.hasFocus { break }
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.remotePressSettleSeconds))
        }

        waitForButtonToGainFocus(
            settingsButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "Before the light mode screenshot, focus should land back on the settings button reliably"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-slideshow-controlbar-light-contrast")
    }

    @MainActor
    func testTVOSSlideShowControlBarButtonsCanActivateOnSelect() throws {
        let app = try launchIntoSlideShow()
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        let previousButton = app.buttons["slideshow.control.previous.button"]
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        let nextButton = app.buttons["slideshow.control.next.button"]
        let removedProgressLabel = app.staticTexts["slideshow.control.progress.label"]

        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page should show the settings button")
        XCTAssertTrue(
            previousButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page should show the previous button")
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page should show the Play/Pause button")
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page should show the next button")
        XCTAssertFalse(
            removedProgressLabel.exists, "The visible photo index above the control bar should have been removed")

        // Bring focus back to the far left first; the later path is only stable from there.
        for _ in 0..<5 {
            if settingsButton.hasFocus { break }
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.remotePressSettleSeconds))
        }

        waitForButtonToGainFocus(
            settingsButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage:
                "Before the control bar activation test starts, focus should return to the settings button reliably"
        )

        let initialSignature = try currentTVOSSceneSignature(app: app)

        XCTAssertFalse(
            previousButton.isEnabled,
            "At the initial history boundary, previous should be disabled and out of the tvOS focus path")

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            playPauseButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage:
                "Previous is disabled at the initial history boundary, so moving right should focus Play/Pause"
        )

        let initialPlayPauseValue = (playPauseButton.value as? String) ?? ""
        XCTAssertFalse(initialPlayPauseValue.isEmpty, "The Play/Pause button should expose its current state value")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.stateChangeDeadlineSeconds) {
                ((playPauseButton.value as? String) ?? "") != initialPlayPauseValue
            },
            "Pressing Select on the Play/Pause button should toggle the current playback state"
        )

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            nextButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "After moving right again, focus should reach the next button"
        )

        XCUIRemote.shared.press(.select)
        let signatureAfterNext = try waitForTVOSSceneSignatureChange(
            app: app,
            from: initialSignature,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds
        )
        XCTAssertNotEqual(signatureAfterNext, initialSignature, "The next button should move the visible scene forward")

        XCUIRemote.shared.press(.left)
        waitForButtonToGainFocus(
            playPauseButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "Moving left from next, focus should return to the Play/Pause button"
        )

        XCUIRemote.shared.press(.left)
        waitForButtonToGainFocus(
            previousButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "Moving left again, focus should reach the previous button"
        )

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds) {
                self.currentTVOSSceneSignatureValue(app: app) == initialSignature
            },
            "Pressing Select on the previous button should go back to the previous scene in playback history"
        )

        XCUIRemote.shared.press(.left)
        waitForButtonToGainFocus(
            settingsButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "Moving left again, focus should return to the settings button"
        )

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForAnySettingsSurface(
                app: app, timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds),
            "Pressing Select on the settings button should open the settings page or the PIN check page"
        )
    }

    @MainActor
    func testTVOSPreviousNextRetainedHistoryFromSlideshowControls() throws {
        let app = try launchIntoSlideShow(shouldForceAutoPlayOff: true)
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        let previousButton = app.buttons["slideshow.control.previous.button"]
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        let nextButton = app.buttons["slideshow.control.next.button"]

        ensureTVOSSlideshowControlBarVisible(app: app)
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page should show the settings button")
        XCTAssertTrue(
            previousButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page should show the previous button")
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page should show the Play/Pause button")
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page should show the next button")

        waitForButtonToGainFocus(
            playPauseButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.settingsChangeDeadlineSeconds,
            failureMessage: "Once the control bar appears, default focus should be on the Play/Pause button"
        )
        attachScreenshot(app: app, name: "tvos-retained-history-01-initial")

        let initialSignature = try currentTVOSSceneSignature(app: app)

        XCTAssertFalse(
            previousButton.isEnabled,
            "At the history boundary, previous should be disabled and out of the tvOS focus path")

        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        let secondSignature = try waitForTVOSSceneSignatureChange(
            app: app, from: initialSignature,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds)
        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.stateChangeDeadlineSeconds) {
                previousButton.isEnabled
            },
            "Once there is history to go back to, previous should be enabled again"
        )
        attachScreenshot(app: app, name: "tvos-retained-history-02-after-next")

        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        let thirdSignature = try waitForTVOSSceneSignatureChange(
            app: app, from: secondSignature,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds)
        XCTAssertNotEqual(thirdSignature, initialSignature, "Two nexts in a row should reach a new playback scene")
        attachScreenshot(app: app, name: "tvos-retained-history-03-after-second-next")

        ensureTVOSSlideshowControlBarVisible(app: app)
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.left)

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds) {
                self.currentTVOSSceneSignatureValue(app: app) == secondSignature
            },
            "The first previous should go back to the prior retained-history position"
        )
        attachScreenshot(app: app, name: "tvos-retained-history-04-previous-to-second")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds) {
                self.currentTVOSSceneSignatureValue(app: app) == initialSignature
            },
            "The second previous should continue along retained history back to the initial position"
        )
        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.stateChangeDeadlineSeconds) {
                previousButton.isEnabled == false
            },
            "Back at the oldest history boundary, previous should be disabled again"
        )
        attachScreenshot(app: app, name: "tvos-retained-history-05-previous-to-initial")
    }
}
extension FilterSummaryTVOSVisualUITests {

}
#endif
