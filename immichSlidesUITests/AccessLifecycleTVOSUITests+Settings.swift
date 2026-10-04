import XCTest

#if os(tvOS)
extension AccessLifecycleTVOSUITests {
    @MainActor
    func configureServerThroughFirstBoot(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 12), "A clean install must open the first-boot form.")
        replaceFocusedText(in: serverField, app: app, with: input.serverURL)

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "First-boot form must show the API Key field.")
        moveFocus(.down, to: apiKeyField, maximumPresses: 2, message: "URL submitted; focus must move down to API Key.")
        replaceFocusedText(in: apiKeyField, app: app, with: input.publicKey)

        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(
            testConnectionButton.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "First-boot form must show Test Connection.")
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)

        let success = app.staticTexts["firstboot.connection.success"]
        XCTAssertTrue(
            success.waitForExistence(timeout: 45),
            "With the real controlled service reachable, the connection test must show as passed."
        )

        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "After connecting, the Save Settings button must show.")
        XCTAssertTrue(saveButton.isEnabled, "After a successful connection, Save Settings must be enabled.")
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    func enterRandomPlayback(app: XCUIApplication) throws {
        let randomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(randomButton.waitForExistence(timeout: 15), "After saving settings, mode selection must open.")
        XCTAssertTrue(
            waitForFocus(
                on: randomButton, timeout: AccessLifecycleTVOSUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "Mode selection focus must start on random playback.")
        XCUIRemote.shared.press(.select)
        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "After choosing random play, Continue must show.")
        XCTAssertTrue(continueButton.isEnabled, "After choosing random play, Continue must be enabled.")
        moveFocus(
            .down,
            to: continueButton,
            maximumPresses: 2,
            message: "After choosing random play, focus must move down to Continue."
        )
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    func changePlaybackSettingsThroughRealUI(app: XCUIApplication) throws {
        openSettingsFromSlideShow(app: app)
        record("settings.open")

        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home must show playback settings.")
        XCTAssertTrue(
            waitForFocus(on: playbackItem, timeout: AccessLifecycleTVOSUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "Settings home must first focus playback settings.")
        XCUIRemote.shared.press(.select)

        selectPlaybackToggle(
            app: app,
            link: "settings.playback.autoPlay.link",
            option: "settings.playback.autoPlay.off.button",
            stepsToLink: 0
        )
        record("settings.save.autoplay")

        selectPlaybackToggle(
            app: app,
            link: "settings.playback.interval.link",
            option: "settings.playback.interval.8.button",
            stepsToLink: 2
        )
        record("settings.save.interval")

        selectPlaybackToggle(
            app: app,
            link: "settings.playback.displayMode.link",
            option: "settings.playback.displayMode.singlePhoto.button",
            stepsToLink: 4
        )
        record("settings.save.display_mode")

        moveFocusToSettingsControl(app: app, identifier: "settings.playback.display.link", maxSteps: 7)
        XCUIRemote.shared.press(.select)
        let exifLink = app.buttons["settings.playback.showExif.link"]
        XCTAssertTrue(
            exifLink.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Display items page must have the EXIF entry.")
        XCTAssertTrue(
            waitForFocus(on: exifLink, timeout: AccessLifecycleTVOSUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "Default focus on display items must be on EXIF.")
        XCUIRemote.shared.press(.select)
        let exifOff = app.buttons["settings.playback.showExif.off.button"]
        XCTAssertTrue(
            exifOff.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "EXIF subpage must have the off option.")
        moveFocus(.down, to: exifOff, maximumPresses: 3, message: "Must be able to focus EXIF off.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(valueContainsSelected(exifOff), "After turning EXIF off, that option must be selected.")
        record("settings.save.exif")
        XCUIRemote.shared.press(.menu)
        waitForFocusVisualSettle()
        XCUIRemote.shared.press(.menu)
        waitForFocusVisualSettle()

        try writePNG(app: app, name: "settings-before-restart")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-settings-before-restart")
        returnToSlideShow(app: app)
    }

    @MainActor
    func enablePinThroughRealUI(app: XCUIApplication) throws {
        openSettingsFromSlideShow(app: app)
        record("settings.open")
        let accessProtectionItem = app.buttons["settings.item.accessProtection"]
        XCTAssertTrue(
            accessProtectionItem.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home must show access protection.")
        moveFocus(.down, to: accessProtectionItem, maximumPresses: 3, message: "Must move down to access protection.")
        XCUIRemote.shared.press(.select)

        let enableInput = app.buttons["settings.pin.input.enable"]
        XCTAssertTrue(
            enableInput.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Access protection page must have the Set PIN entry.")
        XCTAssertTrue(
            waitForFocus(on: enableInput, timeout: AccessLifecycleTVOSUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "Default focus must be on Set PIN.")
        XCUIRemote.shared.press(.select)
        enterPin(app: app, digit: 1, shouldExpectDismiss: true)
        record("settings.pin.enable")

        let confirmInput = app.buttons["settings.pin.input.enableConfirm"]
        moveFocus(.down, to: confirmInput, maximumPresses: 3, message: "Must be able to focus confirm PIN.")
        XCUIRemote.shared.press(.select)
        enterPin(app: app, digit: 1, shouldExpectDismiss: true)
        record("settings.pin.confirm")

        let enableButton = app.buttons["settings.pin.enable.button"]
        moveFocus(.down, to: enableButton, maximumPresses: 4, message: "Must focus enable access protection.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["settings.pin.disable.button"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After enabling PIN, the page must switch to the disable-access-protection actions."
        )
        try writePNG(app: app, name: "pin-enabled")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-pin-enabled")
        returnToSlideShow(app: app)
    }

    @MainActor
    func exercisePinWrongRetryAndCancel(app: XCUIApplication) throws {
        openSettingsFromSlideShow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "With PIN enabled, opening settings must show the PIN gate first."
        )
        try writePNG(app: app, name: "pin-gate")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-pin-gate")

        enterPin(app: app, digit: 0, shouldExpectDismiss: false)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds),
            "A wrong PIN must not open settings; the overlay must remain."
        )
        XCTAssertFalse(
            app.buttons["settings.item.playback"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.briefElementTimeoutSeconds),
            "A wrong PIN must not reveal settings home."
        )
        try writePNG(app: app, name: "pin-wrong")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-pin-wrong")

        focusPinOne(app: app)
        enterPin(app: app, digit: 1, shouldExpectDismiss: true)
        record("settings.pin.unlock")
        XCTAssertTrue(
            app.buttons["settings.item.playback"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Retrying the correct PIN in the same overlay after a wrong one must open settings."
        )
        returnToSlideShow(app: app)

        openSettingsFromSlideShow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Opening settings again must still require the PIN."
        )
        focusPinCloseAndSelect(app: app)
        record("settings.pin.cancel")
        if app.buttons["pinEntry.close.button"].exists == false {
            openSettingsFromSlideShow(app: app)
        }
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After cancel, protection must remain and opening settings again still requires the PIN."
        )
        enterPin(app: app, digit: 1, shouldExpectDismiss: true)
        record("settings.pin.unlock")
        XCTAssertTrue(
            app.buttons["settings.item.playback"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The correct PIN must open settings."
        )
        returnToSlideShow(app: app)
    }

    @MainActor
    func enablePasswordFromSettingsUI(app: XCUIApplication, pin: String) throws {
        openSettingsFromSlideShow(app: app)
        record("settings.open")
        let accessProtectionItem = app.buttons["settings.item.accessProtection"]
        XCTAssertTrue(
            accessProtectionItem.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home must show access protection.")
        moveFocus(.down, to: accessProtectionItem, maximumPresses: 3, message: "Must move down to access protection.")
        XCUIRemote.shared.press(.select)

        let enableInput = app.buttons["settings.pin.input.enable"]
        XCTAssertTrue(
            enableInput.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Access protection page must have the Set PIN entry.")
        XCTAssertTrue(
            waitForFocus(on: enableInput, timeout: AccessLifecycleTVOSUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "Default focus must be on Set PIN.")
        XCUIRemote.shared.press(.select)
        enterPrivatePIN(app: app, pin: pin, shouldExpectDismiss: true)
        record("settings.pin.enable")

        let confirmInput = app.buttons["settings.pin.input.enableConfirm"]
        moveFocus(.down, to: confirmInput, maximumPresses: 3, message: "Must be able to focus confirm PIN.")
        XCUIRemote.shared.press(.select)
        enterPrivatePIN(app: app, pin: pin, shouldExpectDismiss: true)
        record("settings.pin.confirm")

        let enableButton = app.buttons["settings.pin.enable.button"]
        moveFocus(.down, to: enableButton, maximumPresses: 4, message: "Must focus enable access protection.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["settings.pin.disable.button"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After enabling PIN, the page must switch to the disable-access-protection actions."
        )
        try writePNG(app: app, name: "pin-enabled")
        attachScreenshot(app: app, name: "tvos-password-pin-enabled")
        returnToSlideShow(app: app)
    }

    @MainActor
    func provePasswordGateAfterRestart(
        app: XCUIApplication,
        pins: StrictE2EPrivatePINInput
    ) throws {
        try relaunchStrictE2EApp(app)
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.playbackStartupTimeoutSeconds),
            "After terminate and relaunch, must return to playback, not first boot."
        )
        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.readbackTimeoutSeconds),
            "Must not return to first boot after relaunch."
        )

        openSettingsFromSlideShow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After relaunch, opening a protected entry must show the gate."
        )
        try writePNG(app: app, name: "pin-restart-gate")
        attachScreenshot(app: app, name: "tvos-password-pin-restart-gate")

        enterPrivatePIN(app: app, pin: pins.wrong, shouldExpectDismiss: false)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds),
            "A wrong PIN must not open settings; the overlay must remain."
        )
        XCTAssertFalse(
            app.buttons["settings.item.playback"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.briefElementTimeoutSeconds),
            "A wrong PIN must not reveal settings home."
        )
        try writePNG(app: app, name: "pin-wrong")
        attachScreenshot(app: app, name: "tvos-password-pin-wrong")

        enterPrivatePIN(app: app, pin: pins.correct, shouldExpectDismiss: true)
        record("settings.pin.unlock")
        XCTAssertTrue(
            app.buttons["settings.item.playback"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Retrying the correct PIN in the same overlay after a wrong one must open settings."
        )
        try writePNG(app: app, name: "pin-unlocked")
        attachScreenshot(app: app, name: "tvos-password-pin-unlocked")
        returnToSlideShow(app: app)

        openSettingsFromSlideShow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Opening settings again must still require the PIN."
        )
        focusPinCloseAndSelect(app: app)
        record("settings.pin.cancel")
        if app.buttons["pinEntry.close.button"].exists == false {
            XCTAssertTrue(
                isOnSlideShowLayer(app: app)
                    || app.buttons["slideshow.control.settings.button"].waitForExistence(
                        timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds),
                "After cancel, should return to a safe page; the gate need not stay on screen."
            )
        }
        try writePNG(app: app, name: "pin-cancel-safe")
        attachScreenshot(app: app, name: "tvos-password-pin-cancel-safe")

        if app.buttons["pinEntry.close.button"].exists == false {
            openSettingsFromSlideShow(app: app)
        }
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After cancel, protection must remain and opening settings again still requires the PIN."
        )
        try writePNG(app: app, name: "pin-cancel-still-gated")
        attachScreenshot(app: app, name: "tvos-password-pin-cancel-still-gated")
    }

    // The overlay appearing does not mean system focus is in the keypad; wait for a digit key to have hasFocus,
    // then walk the 4x3 grid (2 is right of 1).
    @MainActor
    func enterPrivatePIN(app: XCUIApplication, pin: String, shouldExpectDismiss: Bool) {
        XCTAssertTrue(
            app.buttons["pinEntry.digit.1.button"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "PIN overlay must show the digit keys."
        )
        if waitUntil(
            timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            condition: { focusedPinDigit(in: app) != nil })
            == false
        {
            let backgroundEnablePIN = app.buttons["settings.pin.input.enable"]
            if backgroundEnablePIN.exists && backgroundEnablePIN.hasFocus {
                attachScreenshot(app: app, name: "tvos-password-pin-wait-background-focus")
                XCTFail("After waiting, system focus is still on 'Set PIN' behind; no overlay digit key has hasFocus.")
                return
            }
            attachScreenshot(app: app, name: "tvos-password-pin-wait-no-digit-focus")
            XCTFail("After waiting, no PIN digit key got remote focus.")
            return
        }
        for character in pin {
            guard let digit = character.wholeNumberValue else {
                XCTFail("Private PIN input must be digits")
                return
            }
            let digitButton = app.buttons["pinEntry.digit.\(digit).button"]
            XCTAssertTrue(
                digitButton.waitForExistence(
                    timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
                "PIN overlay must show the digit keys.")
            if digitButton.hasFocus == false {
                moveFocusAlongPinPad(in: app, to: digit)
            }
            XCTAssertTrue(
                waitForFocus(on: digitButton, timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds),
                "The digit key must be focused before input.")
            XCUIRemote.shared.press(.select)
            RunLoop.current.run(
                until: Date().addingTimeInterval(AccessLifecycleTVOSUITestsWaitTiming.pinDigitSettleSeconds))
        }
        if shouldExpectDismiss {
            XCTAssertTrue(
                waitUntil(timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds) {
                    app.buttons["pinEntry.close.button"].exists == false
                },
                "The overlay must close after a full PIN."
            )
        }
    }

    @MainActor
    func focusedPinDigit(in app: XCUIApplication) -> Int? {
        for digit in 0...9 {
            let button = app.buttons["pinEntry.digit.\(digit).button"]
            if button.exists && button.hasFocus {
                return digit
            }
        }
        return nil
    }

    // 4x3: 1 2 3 / 4 5 6 / 7 8 9 / close 0 delete; move left/right first, then up/down; 2 is right of 1.
    @MainActor
    func moveFocusAlongPinPad(in app: XCUIApplication, to target: Int) {
        guard let current = focusedPinDigit(in: app) else {
            XCTFail("A digit key must have focus before walking the PIN grid.")
            return
        }
        let from = pinPadCell(current)
        let destination = pinPadCell(target)
        let targetButton = app.buttons["pinEntry.digit.\(target).button"]
        let horizontal: XCUIRemote.Button = destination.x >= from.x ? .right : .left
        for _ in 0..<abs(destination.x - from.x) {
            if targetButton.hasFocus { return }
            XCUIRemote.shared.press(horizontal)
            waitForFocusVisualSettle()
        }
        let vertical: XCUIRemote.Button = destination.y >= from.y ? .down : .up
        for _ in 0..<abs(destination.y - from.y) {
            if targetButton.hasFocus { return }
            XCUIRemote.shared.press(vertical)
            waitForFocusVisualSettle()
        }
    }

    // Digit 0 is in the middle of the bottom row, next to close and delete; 1-9 are laid out in 3 columns.
    func pinPadCell(_ digit: Int) -> (x: Int, y: Int) {
        let columnCount = 3
        if digit == 0 { return (1, 3) }
        return ((digit - 1) % columnCount, (digit - 1) / columnCount)
    }

    func writePasswordProtectionPayload(pins: StrictE2EPrivatePINInput) throws {
        try AccessLifecycleContract.assertKnownRequests(requests)
        let d01 = try AccessLifecycleContract.pinStorageVerdict(
            storageKind: "uitest_userdefaults",
            isXCTestConfigPresent: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        )
        let screenshotNames = [
            "pin-enabled",
            "pin-restart-gate",
            "pin-wrong",
            "pin-unlocked",
            "pin-cancel-safe",
            "pin-cancel-still-gated"
        ]
        let payload: [String: Any] = [
            "status": "ran",
            "suite": "password-protection-normal-ui",
            "device": "tvos",
            "settings_source": AccessLifecycleContract.allowedSettingsSource,
            "pin_injected": false,
            "pin_enable_path": "ordinary_settings_ui",
            "storage_kind": "uitest_userdefaults",
            "storage_boundary": "xctest_userdefaults_not_keychain",
            "d01_verdict": d01,
            "xctest_config_present": ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
            "requests": requests,
            "screenshots": screenshotNames,
            "pin_flow": [
                "wrong_pin_entered": false,
                "cancel_still_protected": true,
                "correct_pin_entered": true,
                "restart_gated": true
            ]
        ]
        let evidenceText =
            (StrictE2EVisualEvidence.directory()?.path ?? "")
            + requests.joined()
            + screenshotNames.joined()
            + screenshotOrder.joined()
            + AccessLifecycleContract.serializedText(of: payload)
        try AccessLifecycleContract.assertPinAbsent(
            in: evidenceText,
            pinValues: [pins.correct, pins.wrong]
        )
        try StrictE2EVisualEvidence.writeRequiredJSON(payload, name: "password-protection.json")
    }

    @MainActor
    func turnAutoplayOnThroughRealUI(app: XCUIApplication) throws {
        // Four-setting relaunch already proved autoplay stays off; pause and system-pause must run with autoplay on.
        openSettingsFromSlideShow(app: app)
        reachSettingsHomeThroughOptionalPin(app: app, message: "Must enter settings before turning autoplay on.")
        let playbackItem = app.buttons["settings.item.playback"]
        if playbackItem.hasFocus == false {
            moveFocus(.up, to: playbackItem, maximumPresses: 4, message: "Must return to playback settings.")
        }
        XCUIRemote.shared.press(.select)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.autoPlay.link",
            option: "settings.playback.autoPlay.on.button",
            stepsToLink: 0
        )
        record("settings.save.autoplay")
        returnToSlideShow(app: app)
    }

    @MainActor
    func relaunchAndVerifyPinAndSettings(app: XCUIApplication) throws {
        try relaunchStrictE2EApp(app)
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.playbackStartupTimeoutSeconds),
            "After terminate and relaunch, must return to playback, not first boot."
        )
        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.readbackTimeoutSeconds),
            "Must not return to first boot after relaunch."
        )

        openSettingsFromSlideShow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After relaunch, opening settings must still require the PIN."
        )
        try writePNG(app: app, name: "pin-restart-gate")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-pin-restart-gate")
        enterPin(app: app, digit: 1, shouldExpectDismiss: true)
        record("settings.pin.unlock")

        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Playback settings must be visible after unlock.")
        XCTAssertTrue(
            waitForFocus(on: playbackItem, timeout: AccessLifecycleTVOSUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "Unlock should default focus to playback settings.")
        XCUIRemote.shared.press(.select)

        assertSelectedOption(
            app: app,
            link: "settings.playback.autoPlay.link",
            option: "settings.playback.autoPlay.off.button",
            stepsToLink: 0,
            message: "After relaunch, autoplay must still be off."
        )
        assertSelectedOption(
            app: app,
            link: "settings.playback.interval.link",
            option: "settings.playback.interval.8.button",
            stepsToLink: 2,
            message: "After relaunch, the interval must still be 8 seconds."
        )
        assertSelectedOption(
            app: app,
            link: "settings.playback.displayMode.link",
            option: "settings.playback.displayMode.singlePhoto.button",
            stepsToLink: 4,
            message: "After relaunch, display mode must still be single photo."
        )

        moveFocusToSettingsControl(app: app, identifier: "settings.playback.display.link", maxSteps: 7)
        XCUIRemote.shared.press(.select)
        let exifLink = app.buttons["settings.playback.showExif.link"]
        XCTAssertTrue(
            exifLink.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After relaunch, display items must still have EXIF.")
        XCUIRemote.shared.press(.select)
        let exifOff = app.buttons["settings.playback.showExif.off.button"]
        XCTAssertTrue(
            exifOff.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After relaunch, the EXIF subpage must still exist.")
        XCTAssertTrue(valueContainsSelected(exifOff), "After relaunch, EXIF must still be off.")
        XCUIRemote.shared.press(.menu)
        waitForFocusVisualSettle()
        XCUIRemote.shared.press(.menu)
        waitForFocusVisualSettle()

        try writePNG(app: app, name: "settings-after-restart")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-settings-after-restart")
        returnToSlideShow(app: app)
    }
}
#endif
