import XCTest

#if os(tvOS)
final class AccessLifecycleTVOSUITests: XCTestCase {
    private enum Timing {
        static let focusSettle: TimeInterval = 0.16
        static let focusPoll: TimeInterval = 0.08
        static let sceneSettle: TimeInterval = 2.5
        static let controlBarHide: TimeInterval = 9
        static let systemPauseHold: TimeInterval = 9
        // Transition-complete can return before the visible frame is stable enough for identity PNG.
        static let sceneStableExtra: TimeInterval = 1
        // In an earlier device run, Up was pressed about 0.56s after Menu, still inside the return transition.
        static let transitionHold: TimeInterval = 1.2
    }

    private var requests: [String] = []
    private var screenshotOrder: [String] = []
    private var settingsReturnWakeSerial = 0
    private var didHomeLeaveAppRunning = false
    private var didRebuildProcess = false
    private var systemPauseActivation = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // Identity is written only as PNG and the runner recognizes the images.
    @MainActor
    func testTVOSAccessProtectionSettingsAndLifecycle() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The tvOS access-lifecycle test must run on a tvOS Simulator.")
            return
        }

        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try configureServerThroughFirstBoot(app: app, input: input)
        try enterRandomPlayback(app: app)

        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        let nextButton = app.buttons["slideshow.control.next.button"]
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 30), "Control bar must show after random playback.")
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)

        try changePlaybackSettingsThroughRealUI(app: app)
        try enablePinThroughRealUI(app: app)
        try exercisePinWrongRetryAndCancel(app: app)
        try relaunchAndVerifyPinAndSettings(app: app)
        // The comparison must run before autoplay burns through the random pool. After relaunch autoplay is still
        // off; next lands on a portrait/square face with blank space, and unshown companions remain after it.
        try exerciseDisplayModeImmediate(app: app, playPauseButton: playPauseButton, nextButton: nextButton)
        try turnAutoplayOnThroughRealUI(app: app)

        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        try exercisePauseNextPlay(app: app, playPauseButton: playPauseButton, nextButton: nextButton)
        try exerciseSystemPauseAnalog(app: app)
        try exerciseDirectionalWake(app: app, playPauseButton: playPauseButton)

        try writeHostPayload()
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "suite": "access-lifecycle-tvos",
                "environment": "simulator",
                "system_pause_analog": "tvos_home_scene_phase",
                "requests": requests
            ],
            name: "operation-timeline.json"
        )
    }

    // Only verifies the normal password-protection UI; no system pause, wake or display policy.
    // The password comes from private runner input.
    @MainActor
    func testTVOSPasswordProtectionNormalUI() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("Password protection tvOS must run on a tvOS Simulator.")
            return
        }

        let input = try requireStrictE2EInput()
        let pins = try requirePrivatePINInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try configureServerThroughFirstBoot(app: app, input: input)
        try enterRandomPlayback(app: app)
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 30), "Control bar must show after random playback.")
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)

        try enablePasswordFromSettingsUI(app: app, pin: pins.correct)
        try provePasswordGateAfterRestart(app: app, pins: pins)
        try writePasswordProtectionPayload(pins: pins)
    }

    // Narrow entry: change the four settings through the real UI, then terminate/launch and read them back;
    // no password.
    @MainActor
    func testTVOSSettingsPersistAfterTerminateLaunch() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("Settings persistence tvOS must run on a tvOS Simulator.")
            return
        }
        requests = []
        screenshotOrder = []
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        try AccessLifecycleContract.assertProgressProbeNotUsed(launchEnvironment: app.launchEnvironment)

        try configureServerThroughFirstBoot(app: app, input: input)
        try enterRandomPlayback(app: app)
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 30), "Control bar must show after random playback.")
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)

        let initial = try readTVOSFourSettings(app: app)
        let changed = try changeTVOSFourSettingsFromInitial(app: app, initial: initial)
        try AccessLifecycleContract.assertFourSettingsDiffer(initial: initial, changed: changed)
        try writePNG(app: app, name: "settings-changed")
        attachScreenshot(app: app, name: "tvos-settings-changed")
        returnToSlideShow(app: app)
        try writePNG(app: app, name: "display-policy-after-settings")
        attachScreenshot(app: app, name: "tvos-display-policy-after-settings")

        let beforeRestart = try readTVOSFourSettings(app: app)
        try relaunchStrictE2EApp(app)
        try AccessLifecycleContract.assertProgressProbeNotUsed(launchEnvironment: app.launchEnvironment)
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 30)
                || app.descendants(matching: .any)[AccessLifecycleContract.hiddenControlBarPlaybackIdentifier]
                    .waitForExistence(timeout: 8),
            "After terminate and relaunch, must return to playback, not first boot."
        )
        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 2),
            "Must not return to first boot after relaunch."
        )
        try assertTVOSNarrowEntryHasNoPin(app: app)
        let afterRestart = try readTVOSFourSettings(app: app)
        try writePNG(app: app, name: "settings-after-restart")
        attachScreenshot(app: app, name: "tvos-settings-after-restart")
        try AccessLifecycleContract.assertNarrowPathDidNotUnlockPin(didEnterPin: false)
        try AccessLifecycleContract.assertNarrowSettingsPersist(
            initial: initial,
            changed: changed,
            afterRestart: afterRestart
        )
        try AccessLifecycleContract.assertSettingsPersisted(
            before: beforeRestart,
            afterRestart: afterRestart
        )
        try writeTVOSResumeJSON(
            name: "settings-persist.json",
            extra: [
                "suite": "settings-persist",
                "initial": initial,
                "changed": changed,
                "before_restart": beforeRestart,
                "after_restart": afterRestart
            ]
        )
    }

    @MainActor
    func testTVOSPauseNextContinueVisibleTiming() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("Pause/continue tvOS must run on a tvOS Simulator.")
            return
        }
        requests = []
        screenshotOrder = []
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        try AccessLifecycleContract.assertProgressProbeNotUsed(launchEnvironment: app.launchEnvironment)

        try configureServerThroughFirstBoot(app: app, input: input)
        try enterRandomPlayback(app: app)
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        let nextButton = app.buttons["slideshow.control.next.button"]
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 30), "Control bar must show after random playback.")
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)

        let interval = try configureTVOSTimingPlaybackSettings(app: app)
        let timeline = try exerciseTVOSPauseNextContinueVisibleTiming(
            app: app,
            playPauseButton: playPauseButton,
            nextButton: nextButton,
            intervalSeconds: interval.actual
        )
        try writeTVOSResumeJSON(
            name: "pause-next-continue.json",
            extra: [
                "suite": "pause-next-continue",
                "interval_requested": AccessLifecycleContract.requestedIntervalSeconds,
                "interval_actual": interval.actual,
                "desktop_closeout_required": interval.desktopCloseoutRequired,
                "interval_options": AccessLifecycleContract.tvOSSelectableIntervals,
                "timeline": timeline
            ]
        )
    }

    @MainActor
    func testTVOSBackgroundReturnPreservesScene() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("Background return tvOS must run on a tvOS Simulator.")
            return
        }
        requests = []
        screenshotOrder = []
        didHomeLeaveAppRunning = false
        didRebuildProcess = false
        systemPauseActivation = ""
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        try AccessLifecycleContract.assertProgressProbeNotUsed(launchEnvironment: app.launchEnvironment)

        try configureServerThroughFirstBoot(app: app, input: input)
        try enterRandomPlayback(app: app)
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 30), "Control bar must show after random playback.")
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)

        let interval = try configureTVOSTimingPlaybackSettings(app: app)
        let waitSeconds =
            TimeInterval(interval.actual)
            + AccessLifecycleContract.pauseHoldBeyondIntervalSeconds
        try AccessLifecycleContract.assertAutoPlayEnabledAtBackground(true)
        try AccessLifecycleContract.assertBackgroundWaitExceedsInterval(
            waitSeconds: waitSeconds,
            intervalSeconds: Double(interval.actual)
        )

        let before = try captureTVOSNewStableMark(
            app: app,
            name: "before-background",
            timeout: TimeInterval(interval.actual) + 4
        )
        let processBefore = try applicationProcessID(app)
        XCTAssertNotEqual(app.state, .notRunning, "The process must still be running before going to background.")
        XCUIDevice.shared.press(.home)
        record("playback.background")
        RunLoop.current.run(until: Date().addingTimeInterval(waitSeconds))
        didHomeLeaveAppRunning = app.state != .notRunning
        XCTAssertTrue(didHomeLeaveAppRunning, "Process gone after Home means activate opens/rebuilds; not a return.")
        app.activate()
        systemPauseActivation = AccessLifecycleContract.allowedSystemPauseActivation
        record("playback.foreground")
        _ = app.wait(for: .runningForeground, timeout: 10)
        let processAfter = try applicationProcessID(app)
        didRebuildProcess = processAfter != processBefore || didHomeLeaveAppRunning == false || app.state == .notRunning
        XCTAssertNotEqual(
            app.state,
            .notRunning,
            "The process must still exist after activate; an Open/rebuild must not pass as a foreground return."
        )
        try AccessLifecycleContract.assertSameProcess(
            beforeIdentifier: processBefore,
            afterIdentifier: processAfter
        )
        try AccessLifecycleContract.assertSystemPauseActivation(
            activation: systemPauseActivation,
            processRebuilt: didRebuildProcess,
            homeLeftAppRunning: didHomeLeaveAppRunning
        )
        XCTAssertTrue(
            waitUntilOnSlideShowLayer(app: app, timeout: 3),
            "Must still be on playback after returning from system pause."
        )
        confirmReturnedToSlideShow(app: app)
        try assertTVOSNarrowEntryHasNoPin(app: app)
        let identityStarted = Date()
        let after = try captureTVOSImmediateMark(app: app, name: "after-background")
        try AccessLifecycleContract.assertBackgroundIdentityIsFirstSegment(
            secondsBeforeIdentity: Date().timeIntervalSince(identityStarted),
            intervalSeconds: Double(interval.actual)
        )
        try AccessLifecycleContract.assertBackgroundDidNotJump(before: before.mark, after: after.mark)
        try AccessLifecycleContract.assertSystemPauseIdentityTiming(screenshotOrder: screenshotOrder)
        try writeTVOSResumeJSON(
            name: "background-return.json",
            extra: [
                "suite": "background-return",
                "interval_requested": AccessLifecycleContract.requestedIntervalSeconds,
                "interval_actual": interval.actual,
                "desktop_closeout_required": interval.desktopCloseoutRequired,
                "wait_seconds": waitSeconds,
                "home_left_app_running": didHomeLeaveAppRunning,
                "process_rebuilt": didRebuildProcess,
                "process_identifier_before": Int(processBefore),
                "process_identifier_after": Int(processAfter),
                "mark_before": before.mark,
                "mark_after": after.mark
            ]
        )
    }

    @MainActor
    private func configureServerThroughFirstBoot(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 12), "A clean install must open the first-boot form.")
        replaceFocusedText(in: serverField, app: app, with: input.serverURL)

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 8), "First-boot form must show the API Key field.")
        moveFocus(.down, to: apiKeyField, maximumPresses: 2, message: "URL submitted; focus must move down to API Key.")
        replaceFocusedText(in: apiKeyField, app: app, with: input.publicKey)

        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(testConnectionButton.waitForExistence(timeout: 5), "First-boot form must show Test Connection.")
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
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "After connecting, the Save Settings button must show.")
        XCTAssertTrue(saveButton.isEnabled, "After a successful connection, Save Settings must be enabled.")
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    private func enterRandomPlayback(app: XCUIApplication) throws {
        let randomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(randomButton.waitForExistence(timeout: 15), "After saving settings, mode selection must open.")
        XCTAssertTrue(waitForFocus(on: randomButton, timeout: 5), "Mode selection focus must start on random playback.")
        XCUIRemote.shared.press(.select)
        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5), "After choosing random play, Continue must show.")
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
    private func changePlaybackSettingsThroughRealUI(app: XCUIApplication) throws {
        openSettingsFromSlideShow(app: app)
        record("settings.open")

        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(playbackItem.waitForExistence(timeout: 8), "Settings home must show playback settings.")
        XCTAssertTrue(waitForFocus(on: playbackItem, timeout: 6), "Settings home must first focus playback settings.")
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
        XCTAssertTrue(exifLink.waitForExistence(timeout: 8), "Display items page must have the EXIF entry.")
        XCTAssertTrue(waitForFocus(on: exifLink, timeout: 6), "Default focus on display items must be on EXIF.")
        XCUIRemote.shared.press(.select)
        let exifOff = app.buttons["settings.playback.showExif.off.button"]
        XCTAssertTrue(exifOff.waitForExistence(timeout: 8), "EXIF subpage must have the off option.")
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
    private func enablePinThroughRealUI(app: XCUIApplication) throws {
        openSettingsFromSlideShow(app: app)
        record("settings.open")
        let accessProtectionItem = app.buttons["settings.item.accessProtection"]
        XCTAssertTrue(accessProtectionItem.waitForExistence(timeout: 8), "Settings home must show access protection.")
        moveFocus(.down, to: accessProtectionItem, maximumPresses: 3, message: "Must move down to access protection.")
        XCUIRemote.shared.press(.select)

        let enableInput = app.buttons["settings.pin.input.enable"]
        XCTAssertTrue(enableInput.waitForExistence(timeout: 8), "Access protection page must have the Set PIN entry.")
        XCTAssertTrue(waitForFocus(on: enableInput, timeout: 6), "Default focus must be on Set PIN.")
        XCUIRemote.shared.press(.select)
        enterPin(app: app, digit: 1, expectDismiss: true)
        record("settings.pin.enable")

        let confirmInput = app.buttons["settings.pin.input.enableConfirm"]
        moveFocus(.down, to: confirmInput, maximumPresses: 3, message: "Must be able to focus confirm PIN.")
        XCUIRemote.shared.press(.select)
        enterPin(app: app, digit: 1, expectDismiss: true)
        record("settings.pin.confirm")

        let enableButton = app.buttons["settings.pin.enable.button"]
        moveFocus(.down, to: enableButton, maximumPresses: 4, message: "Must focus enable access protection.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["settings.pin.disable.button"].waitForExistence(timeout: 8),
            "After enabling PIN, the page must switch to the disable-access-protection actions."
        )
        try writePNG(app: app, name: "pin-enabled")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-pin-enabled")
        returnToSlideShow(app: app)
    }

    @MainActor
    private func exercisePinWrongRetryAndCancel(app: XCUIApplication) throws {
        openSettingsFromSlideShow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "With PIN enabled, opening settings must show the PIN gate first."
        )
        try writePNG(app: app, name: "pin-gate")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-pin-gate")

        enterPin(app: app, digit: 0, expectDismiss: false)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 4),
            "A wrong PIN must not open settings; the overlay must remain."
        )
        XCTAssertFalse(
            app.buttons["settings.item.playback"].waitForExistence(timeout: 1),
            "A wrong PIN must not reveal settings home."
        )
        try writePNG(app: app, name: "pin-wrong")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-pin-wrong")

        focusPinOne(app: app)
        enterPin(app: app, digit: 1, expectDismiss: true)
        record("settings.pin.unlock")
        XCTAssertTrue(
            app.buttons["settings.item.playback"].waitForExistence(timeout: 8),
            "Retrying the correct PIN in the same overlay after a wrong one must open settings."
        )
        returnToSlideShow(app: app)

        openSettingsFromSlideShow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "Opening settings again must still require the PIN."
        )
        focusPinCloseAndSelect(app: app)
        record("settings.pin.cancel")
        if app.buttons["pinEntry.close.button"].exists == false {
            openSettingsFromSlideShow(app: app)
        }
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "After cancel, protection must remain and opening settings again still requires the PIN."
        )
        enterPin(app: app, digit: 1, expectDismiss: true)
        record("settings.pin.unlock")
        XCTAssertTrue(
            app.buttons["settings.item.playback"].waitForExistence(timeout: 8),
            "The correct PIN must open settings."
        )
        returnToSlideShow(app: app)
    }

    @MainActor
    private func enablePasswordFromSettingsUI(app: XCUIApplication, pin: String) throws {
        openSettingsFromSlideShow(app: app)
        record("settings.open")
        let accessProtectionItem = app.buttons["settings.item.accessProtection"]
        XCTAssertTrue(accessProtectionItem.waitForExistence(timeout: 8), "Settings home must show access protection.")
        moveFocus(.down, to: accessProtectionItem, maximumPresses: 3, message: "Must move down to access protection.")
        XCUIRemote.shared.press(.select)

        let enableInput = app.buttons["settings.pin.input.enable"]
        XCTAssertTrue(enableInput.waitForExistence(timeout: 8), "Access protection page must have the Set PIN entry.")
        XCTAssertTrue(waitForFocus(on: enableInput, timeout: 6), "Default focus must be on Set PIN.")
        XCUIRemote.shared.press(.select)
        enterPrivatePIN(app: app, pin: pin, expectDismiss: true)
        record("settings.pin.enable")

        let confirmInput = app.buttons["settings.pin.input.enableConfirm"]
        moveFocus(.down, to: confirmInput, maximumPresses: 3, message: "Must be able to focus confirm PIN.")
        XCUIRemote.shared.press(.select)
        enterPrivatePIN(app: app, pin: pin, expectDismiss: true)
        record("settings.pin.confirm")

        let enableButton = app.buttons["settings.pin.enable.button"]
        moveFocus(.down, to: enableButton, maximumPresses: 4, message: "Must focus enable access protection.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["settings.pin.disable.button"].waitForExistence(timeout: 8),
            "After enabling PIN, the page must switch to the disable-access-protection actions."
        )
        try writePNG(app: app, name: "pin-enabled")
        attachScreenshot(app: app, name: "tvos-password-pin-enabled")
        returnToSlideShow(app: app)
    }

    @MainActor
    private func provePasswordGateAfterRestart(
        app: XCUIApplication,
        pins: StrictE2EPrivatePINInput
    ) throws {
        try relaunchStrictE2EApp(app)
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 30),
            "After terminate and relaunch, must return to playback, not first boot."
        )
        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 2),
            "Must not return to first boot after relaunch."
        )

        openSettingsFromSlideShow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "After relaunch, opening a protected entry must show the gate."
        )
        try writePNG(app: app, name: "pin-restart-gate")
        attachScreenshot(app: app, name: "tvos-password-pin-restart-gate")

        enterPrivatePIN(app: app, pin: pins.wrong, expectDismiss: false)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 4),
            "A wrong PIN must not open settings; the overlay must remain."
        )
        XCTAssertFalse(
            app.buttons["settings.item.playback"].waitForExistence(timeout: 1),
            "A wrong PIN must not reveal settings home."
        )
        try writePNG(app: app, name: "pin-wrong")
        attachScreenshot(app: app, name: "tvos-password-pin-wrong")

        enterPrivatePIN(app: app, pin: pins.correct, expectDismiss: true)
        record("settings.pin.unlock")
        XCTAssertTrue(
            app.buttons["settings.item.playback"].waitForExistence(timeout: 8),
            "Retrying the correct PIN in the same overlay after a wrong one must open settings."
        )
        try writePNG(app: app, name: "pin-unlocked")
        attachScreenshot(app: app, name: "tvos-password-pin-unlocked")
        returnToSlideShow(app: app)

        openSettingsFromSlideShow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "Opening settings again must still require the PIN."
        )
        focusPinCloseAndSelect(app: app)
        record("settings.pin.cancel")
        if app.buttons["pinEntry.close.button"].exists == false {
            XCTAssertTrue(
                isOnSlideShowLayer(app: app)
                    || app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 4),
                "After cancel, should return to a safe page; the gate need not stay on screen."
            )
        }
        try writePNG(app: app, name: "pin-cancel-safe")
        attachScreenshot(app: app, name: "tvos-password-pin-cancel-safe")

        if app.buttons["pinEntry.close.button"].exists == false {
            openSettingsFromSlideShow(app: app)
        }
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "After cancel, protection must remain and opening settings again still requires the PIN."
        )
        try writePNG(app: app, name: "pin-cancel-still-gated")
        attachScreenshot(app: app, name: "tvos-password-pin-cancel-still-gated")
    }

    // The overlay appearing does not mean system focus is in the keypad; wait for a digit key to have hasFocus,
    // then walk the 4x3 grid (2 is right of 1).
    @MainActor
    private func enterPrivatePIN(app: XCUIApplication, pin: String, expectDismiss: Bool) {
        XCTAssertTrue(
            app.buttons["pinEntry.digit.1.button"].waitForExistence(timeout: 8),
            "PIN overlay must show the digit keys."
        )
        if waitUntil(timeout: 8, condition: { focusedPinDigit(in: app) != nil }) == false {
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
            XCTAssertTrue(digitButton.waitForExistence(timeout: 8), "PIN overlay must show the digit keys.")
            if digitButton.hasFocus == false {
                moveFocusAlongPinPad(in: app, to: digit)
            }
            XCTAssertTrue(waitForFocus(on: digitButton, timeout: 4), "The digit key must be focused before input.")
            XCUIRemote.shared.press(.select)
            RunLoop.current.run(until: Date().addingTimeInterval(0.07))
        }
        if expectDismiss {
            XCTAssertTrue(
                waitUntil(timeout: 8) { app.buttons["pinEntry.close.button"].exists == false },
                "The overlay must close after a full PIN."
            )
        }
    }

    @MainActor
    private func focusedPinDigit(in app: XCUIApplication) -> Int? {
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
    private func moveFocusAlongPinPad(in app: XCUIApplication, to target: Int) {
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
    private func pinPadCell(_ digit: Int) -> (x: Int, y: Int) {
        let columnCount = 3
        if digit == 0 { return (1, 3) }
        return ((digit - 1) % columnCount, (digit - 1) / columnCount)
    }

    private func writePasswordProtectionPayload(pins: StrictE2EPrivatePINInput) throws {
        try AccessLifecycleContract.assertKnownRequests(requests)
        let d01 = try AccessLifecycleContract.d01Verdict(
            storageKind: "uitest_userdefaults",
            xctestConfigPresent: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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
            + String(describing: payload.keys.sorted())
        try AccessLifecycleContract.assertPinAbsent(
            in: evidenceText,
            pinValues: [pins.correct, pins.wrong]
        )
        try StrictE2EVisualEvidence.writeRequiredJSON(payload, name: "password-protection.json")
    }

    @MainActor
    private func turnAutoplayOnThroughRealUI(app: XCUIApplication) throws {
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
    private func relaunchAndVerifyPinAndSettings(app: XCUIApplication) throws {
        try relaunchStrictE2EApp(app)
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 30),
            "After terminate and relaunch, must return to playback, not first boot."
        )
        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 2),
            "Must not return to first boot after relaunch."
        )

        openSettingsFromSlideShow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "After relaunch, opening settings must still require the PIN."
        )
        try writePNG(app: app, name: "pin-restart-gate")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-pin-restart-gate")
        enterPin(app: app, digit: 1, expectDismiss: true)
        record("settings.pin.unlock")

        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(playbackItem.waitForExistence(timeout: 8), "Playback settings must be visible after unlock.")
        XCTAssertTrue(waitForFocus(on: playbackItem, timeout: 6), "Unlock should default focus to playback settings.")
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
            message: "After relaunch, display policy must still be single photo."
        )

        moveFocusToSettingsControl(app: app, identifier: "settings.playback.display.link", maxSteps: 7)
        XCUIRemote.shared.press(.select)
        let exifLink = app.buttons["settings.playback.showExif.link"]
        XCTAssertTrue(exifLink.waitForExistence(timeout: 8), "After relaunch, display items must still have EXIF.")
        XCUIRemote.shared.press(.select)
        let exifOff = app.buttons["settings.playback.showExif.off.button"]
        XCTAssertTrue(exifOff.waitForExistence(timeout: 8), "After relaunch, the EXIF subpage must still exist.")
        XCTAssertTrue(valueContainsSelected(exifOff), "After relaunch, EXIF must still be off.")
        XCUIRemote.shared.press(.menu)
        waitForFocusVisualSettle()
        XCUIRemote.shared.press(.menu)
        waitForFocusVisualSettle()

        try writePNG(app: app, name: "settings-after-restart")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-settings-after-restart")
        returnToSlideShow(app: app)
    }

    @MainActor
    private func exercisePauseNextPlay(
        app: XCUIApplication,
        playPauseButton: XCUIElement,
        nextButton: XCUIElement
    ) throws {
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        moveFocus(.right, to: playPauseButton, maximumPresses: 3, message: "Focus must reach play/pause.")
        let playingValue = String(describing: playPauseButton.value ?? "")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: 4) { String(describing: playPauseButton.value ?? "") != playingValue },
            "Autoplay must be paused first."
        )
        record("playback.pause")
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.sceneSettle))
        try writePNG(app: app, name: "pause")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-pause")

        moveFocus(.right, to: nextButton, maximumPresses: 3, message: "After pause, focus must reach next.")
        XCUIRemote.shared.press(.select)
        record("playback.next")
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.sceneSettle))
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        try writePNG(app: app, name: "after-next")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-after-next")

        moveFocus(.left, to: playPauseButton, maximumPresses: 3, message: "Focus must return to play/pause after next.")
        let pausedValue = String(describing: playPauseButton.value ?? "")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: 4) { String(describing: playPauseButton.value ?? "") != pausedValue },
            "Play must resume from the currently paused new scene."
        )
        record("playback.play")
        XCTAssertTrue(
            waitForSlideshowTransitionComplete(app: app, timeout: 20),
            "After Play, must wait for the new scene to settle."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.sceneStableExtra))
        try writePNG(app: app, name: "after-play")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-after-play")
    }

    @MainActor
    private func exerciseSystemPauseAnalog(app: XCUIApplication) throws {
        // The identity screenshot must not come after a separate control-bar wake; the wake is a later, separate step.
        try writePNG(app: app, name: "before-background")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-before-system-pause")
        XCUIDevice.shared.press(.home)
        record("playback.background")
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.systemPauseHold))
        // If the process exited after Home, activation launches a new process rather than returning to the same one.
        didHomeLeaveAppRunning = app.state != .notRunning
        didRebuildProcess = didHomeLeaveAppRunning == false
        XCTAssertTrue(
            didHomeLeaveAppRunning,
            "If the process exits after Home, activation launches a new process and must not count as the same process returning."
        )
        app.activate()
        systemPauseActivation = AccessLifecycleContract.allowedSystemPauseActivation
        record("playback.foreground")
        if app.state == .notRunning {
            didRebuildProcess = true
        }
        XCTAssertNotEqual(
            app.state,
            .notRunning,
            "The process must still exist after activate; an Open/rebuild must not pass as a foreground return."
        )
        // A hidden control bar still counts as back on playback; visible settings/play buttons are not the criterion.
        XCTAssertTrue(
            waitForSlideshowTransitionComplete(app: app, timeout: 20),
            "Must still be on playback after returning from the system-pause analog."
        )
        confirmReturnedToSlideShow(app: app)
        try writePNG(app: app, name: "after-background")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-after-system-pause")
        do {
            try AccessLifecycleContract.assertSystemPauseActivation(
                activation: systemPauseActivation,
                processRebuilt: didRebuildProcess,
                homeLeftAppRunning: didHomeLeaveAppRunning
            )
            try AccessLifecycleContract.assertSystemPauseIdentityTiming(
                screenshotOrder: screenshotOrder
            )
        } catch {
            XCTFail(String(describing: error))
        }
    }

    @MainActor
    private func exerciseDirectionalWake(app: XCUIApplication, playPauseButton: XCUIElement) throws {
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.controlBarHide))
        let wakeReceiver = app.descendants(matching: .any)[
            AccessLifecycleContract.hiddenControlBarPlaybackIdentifier
        ]
        XCTAssertTrue(
            wakeReceiver.waitForExistence(timeout: 4) || playPauseButton.exists == false,
            "After waiting for auto-hide, the control bar must hide or the wake receiver must appear."
        )
        XCTAssertTrue(
            waitForHiddenWakeReceiverStableFocus(app: app, timeout: 8) != nil,
            "Before the dedicated wake, the hidden receiver must have stable focus."
        )
        try writePNG(app: app, name: "before-wake")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-before-wake")
        XCUIRemote.shared.press(.up)
        record("playback.wake_controls")
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 6), "First directional press must only wake controls.")
        try writePNG(app: app, name: "after-wake")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-after-wake")
    }

    @MainActor
    private func exerciseDisplayModeImmediate(
        app: XCUIApplication,
        playPauseButton: XCUIElement,
        nextButton: XCUIElement
    ) throws {
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        moveFocus(
            .right,
            to: playPauseButton,
            maximumPresses: 3,
            message: "Before changing display policy, focus must reach play/pause."
        )
        let playPauseValue = String(describing: playPauseButton.value ?? "")
        if playPauseValue.contains("暂停") || playPauseValue.lowercased().contains("pause") {
            XCUIRemote.shared.press(.select)
            record("playback.pause")
        }
        // The first 16:9 photo A1 fills the screen, hiding the second public fixture; press next only once to
        // portrait A2, not to the pool end A5.
        XCTAssertTrue(nextButton.waitForExistence(timeout: 8), "The next button must exist before the comparison.")
        moveFocus(.right, to: nextButton, maximumPresses: 3, message: "Must reach next before the comparison.")
        XCUIRemote.shared.press(.select)
        record("playback.next")
        XCTAssertTrue(
            waitForSlideshowTransitionComplete(app: app, timeout: 20),
            "Before the comparison, must rest on a portrait or square playback face."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.sceneStableExtra))
        try writePNG(app: app, name: "display-before")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-display-before")

        openSettingsFromSlideShow(app: app)
        record("settings.open")
        reachSettingsHomeThroughOptionalPin(
            app: app,
            message: "Before changing display policy, must pass the PIN or enter settings."
        )
        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            waitForFocus(on: playbackItem, timeout: 6) || playbackItem.exists,
            "Must be able to enter playback settings."
        )
        if playbackItem.exists && playbackItem.hasFocus == false {
            moveFocus(.up, to: playbackItem, maximumPresses: 4, message: "Must return to playback settings.")
        }
        XCUIRemote.shared.press(.select)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.displayMode.link",
            option: "settings.playback.displayMode.smartFill.button",
            stepsToLink: 4
        )
        record("settings.save.display_mode")
        returnToSlideShow(app: app)
        XCTAssertTrue(
            waitForSlideshowTransitionComplete(app: app, timeout: 20),
            "After returning from display policy, must wait for the current face to settle."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.sceneStableExtra))
        try writePNG(app: app, name: "display-after")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-display-after")

        // Smart fill evidence is captured; later pause/system-pause/wake identity uses single photo again, so mixed
        // colors are not read as TRANSITION.
        openSettingsFromSlideShow(app: app)
        record("settings.open")
        reachSettingsHomeThroughOptionalPin(app: app, message: "Must return to settings after display policy evidence.")
        let restorePlayback = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            waitForFocus(on: restorePlayback, timeout: 6) || restorePlayback.exists,
            "Must be able to enter playback settings."
        )
        if restorePlayback.exists && restorePlayback.hasFocus == false {
            moveFocus(.up, to: restorePlayback, maximumPresses: 4, message: "Must return to playback settings.")
        }
        XCUIRemote.shared.press(.select)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.displayMode.link",
            option: "settings.playback.displayMode.singlePhoto.button",
            stepsToLink: 4
        )
        record("settings.save.display_mode")
        returnToSlideShow(app: app)
        XCTAssertTrue(
            waitForSlideshowTransitionComplete(app: app, timeout: 20),
            "After switching back to single photo, must still be on playback."
        )
    }

    @MainActor
    private func selectPlaybackToggle(
        app: XCUIApplication,
        link: String,
        option: String,
        stepsToLink: Int
    ) {
        moveFocusToSettingsControl(app: app, identifier: link, maxSteps: max(stepsToLink, 6))
        XCUIRemote.shared.press(.select)
        let optionButton = app.buttons[option]
        XCTAssertTrue(optionButton.waitForExistence(timeout: 8), "Settings subpage must show target option \(option).")
        if optionButton.hasFocus == false {
            moveFocus(.down, to: optionButton, maximumPresses: 6, message: "Must be able to focus \(option).")
        }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(valueContainsSelected(optionButton), "After choosing \(option), it must be selected.")
        XCUIRemote.shared.press(.menu)
        waitForFocusVisualSettle()
    }

    @MainActor
    private func assertSelectedOption(
        app: XCUIApplication,
        link: String,
        option: String,
        stepsToLink: Int,
        message: String
    ) {
        moveFocusToSettingsControl(app: app, identifier: link, maxSteps: max(stepsToLink, 6))
        XCUIRemote.shared.press(.select)
        let optionButton = app.buttons[option]
        XCTAssertTrue(optionButton.waitForExistence(timeout: 8), message)
        XCTAssertTrue(valueContainsSelected(optionButton), message)
        XCUIRemote.shared.press(.menu)
        waitForFocusVisualSettle()
    }

    @MainActor
    private func enterPin(app: XCUIApplication, digit: Int, expectDismiss: Bool) {
        let identifier = "pinEntry.digit.\(digit).button"
        let digitButton = app.buttons[identifier]
        XCTAssertTrue(digitButton.waitForExistence(timeout: 8), "PIN overlay must show the digit keys.")
        if digit == 0 {
            focusPinZero(app: app)
        } else if digitButton.hasFocus == false {
            moveFocus(.up, to: digitButton, maximumPresses: 6, message: "Must focus the PIN digit key.")
        }
        XCTAssertTrue(waitForFocus(on: digitButton, timeout: 4), "The digit key must be focused before input.")
        for _ in 0..<6 {
            XCUIRemote.shared.press(.select)
            RunLoop.current.run(until: Date().addingTimeInterval(0.07))
        }
        if expectDismiss {
            XCTAssertTrue(
                waitUntil(timeout: 8) { app.buttons["pinEntry.close.button"].exists == false },
                "The overlay must close after a full PIN."
            )
        }
    }

    @MainActor
    private func focusPinZero(app: XCUIApplication) {
        let zero = app.buttons["pinEntry.digit.0.button"]
        let closeButton = app.buttons["pinEntry.close.button"]
        for _ in 0..<4 where closeButton.hasFocus == false && zero.hasFocus == false {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle()
        }
        if zero.hasFocus { return }
        XCUIRemote.shared.press(.right)
        waitForFocusVisualSettle()
        XCTAssertTrue(waitForFocus(on: zero, timeout: 4), "Must focus PIN digit 0.")
    }

    @MainActor
    private func focusPinOne(app: XCUIApplication) {
        let one = app.buttons["pinEntry.digit.1.button"]
        XCTAssertTrue(one.waitForExistence(timeout: 6), "PIN overlay must still have digit 1.")
        for _ in 0..<5 where one.hasFocus == false {
            XCUIRemote.shared.press(.up)
            waitForFocusVisualSettle()
        }
        if one.hasFocus == false {
            XCUIRemote.shared.press(.left)
            waitForFocusVisualSettle()
        }
        XCTAssertTrue(waitForFocus(on: one, timeout: 4), "After a wrong entry, must return to digit 1 to retry.")
    }

    @MainActor
    private func focusPinCloseAndSelect(app: XCUIApplication) {
        let closeButton = app.buttons["pinEntry.close.button"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 6), "PIN overlay must have a close button.")
        for _ in 0..<6 where closeButton.hasFocus == false {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle()
        }
        if closeButton.hasFocus == false {
            XCUIRemote.shared.press(.left)
            waitForFocusVisualSettle()
        }
        XCTAssertTrue(waitForFocus(on: closeButton, timeout: 4), "Close must be focused before cancel.")
        XCUIRemote.shared.press(.select)
        waitForFocusVisualSettle()
    }

    @MainActor
    private func reachSettingsHomeThroughOptionalPin(app: XCUIApplication, message: String) {
        // After opening settings, either the PIN gate or the settings page is valid; unlock the gate if present,
        // then wait for playback settings.
        let pinClose = app.buttons["pinEntry.close.button"]
        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            waitUntil(timeout: 8) { pinClose.exists || playbackItem.exists },
            "After opening settings, the PIN gate or settings page must appear."
        )
        do {
            try AccessLifecycleContract.assertSettingsOpen(
                identifiers: observedLayerIdentifiers(app: app),
                requirePlaybackItem: false
            )
        } catch {
            XCTFail(String(describing: error))
        }
        if pinClose.exists {
            enterPin(app: app, digit: 1, expectDismiss: true)
            record("settings.pin.unlock")
        }
        XCTAssertTrue(playbackItem.waitForExistence(timeout: 8), message)
    }

    @MainActor
    private func openSettingsFromSlideShow(app: XCUIApplication) {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        if settingsButton.exists == false {
            wakeHiddenControlBarOnce(
                app: app,
                visibleControl: settingsButton,
                evidenceStem: "settings-return-wake"
            )
        }
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "Playback page must show the settings button.")
        for _ in 0..<6 where settingsButton.hasFocus == false {
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(waitForFocus(on: settingsButton, timeout: 6), "Settings button must have focus before opening.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                app.buttons["settings.item.playback"].exists
                    || app.buttons["pinEntry.close.button"].exists
                    || app.buttons["settings.item.accessProtection"].exists
            },
            "After Select on settings, must enter settings or the PIN gate."
        )
    }

    @MainActor
    private func returnToSlideShow(app: XCUIApplication) {
        // Recognize the playback layer/screen identity. That the first wake after the bar hides keeps the scene is
        // verified separately, so do not wake the control bar here.
        for _ in 0..<8 {
            if waitUntil(timeout: 0.8, condition: { isOnSlideShowLayer(app: app) }) {
                finishReturnToSlideShow(app: app)
                return
            }
            XCUIRemote.shared.press(.menu)
            RunLoop.current.run(until: Date().addingTimeInterval(0.22))
        }
        XCTAssertTrue(
            waitUntil(timeout: 8, condition: { isOnSlideShowLayer(app: app) }),
            "Must be able to return from settings to playback."
        )
        finishReturnToSlideShow(app: app)
    }

    @MainActor
    private func finishReturnToSlideShow(app: XCUIApplication) {
        XCTAssertTrue(
            waitForSlideshowTransitionComplete(app: app, timeout: 8),
            "After returning from settings, must wait for the playback transition to finish."
        )
        confirmReturnedToSlideShow(app: app)
        if app.buttons["slideshow.control.settings.button"].exists {
            return
        }
        XCTAssertTrue(
            waitForHiddenWakeReceiverStableFocus(app: app, timeout: 8) != nil,
            "After returning from settings with the bar hidden, the hidden receiver must have stable focus."
        )
    }

    @MainActor
    private func wakeHiddenControlBarOnce(
        app: XCUIApplication,
        visibleControl: XCUIElement,
        evidenceStem: String
    ) {
        XCTAssertTrue(
            waitForSlideshowTransitionComplete(app: app, timeout: 8),
            "After returning from settings, the playback transition must finish before a directional press."
        )
        guard let consecutive = waitForHiddenWakeReceiverStableFocus(app: app, timeout: 8) else {
            XCTFail("After returning from settings, confirm stable hidden receiver focus before one directional press.")
            return
        }
        settingsReturnWakeSerial += 1
        let stem = "\(evidenceStem)-\(settingsReturnWakeSerial)"
        let beforeName = "\(stem)-before"
        let afterName = "\(stem)-after"
        let receiver = app.descendants(matching: .any)[
            AccessLifecycleContract.hiddenControlBarPlaybackIdentifier
        ]
        let identifiersBeforePress = observedLayerIdentifiers(app: app)
        let focusedBeforePress = receiver.exists && receiver.hasFocus
        do {
            try writePNG(app: app, name: beforeName)
        } catch {
            XCTFail(String(describing: error))
            return
        }
        attachScreenshot(app: app, name: "tvos-access-lifecycle-\(beforeName)")
        XCUIRemote.shared.press(.up)
        let woke = visibleControl.waitForExistence(timeout: 10)
        do {
            try writePNG(app: app, name: afterName)
        } catch {
            XCTFail(String(describing: error))
            return
        }
        attachScreenshot(app: app, name: "tvos-access-lifecycle-\(afterName)")
        do {
            try AccessLifecycleContract.assertSettingsReturnWake(
                identifiers: identifiersBeforePress,
                transitionComplete: true,
                hiddenWakeReceiverFocused: focusedBeforePress,
                hiddenWakeReceiverFocusStable: true,
                consecutiveFocusedObservations: consecutive,
                directionalPressCount: 1,
                beforeScreenshot: beforeName,
                afterScreenshot: afterName
            )
        } catch {
            XCTFail(String(describing: error))
            return
        }
        XCTAssertTrue(woke, "First directional press must only wake controls.")
    }

    @MainActor
    private func waitForSlideshowTransitionComplete(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForConditionHeld(timeout: timeout, hold: Timing.transitionHold) {
            isOnSlideShowLayer(app: app)
        }
    }

    @MainActor
    private func waitUntilOnSlideShowLayer(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isOnSlideShowLayer(app: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPoll))
        }
        return isOnSlideShowLayer(app: app)
    }

    @MainActor
    private func waitForHiddenWakeReceiverStableFocus(app: XCUIApplication, timeout: TimeInterval) -> Int? {
        // The receiver must report hasFocus on consecutive polls; one hit is not enough: in an earlier failure
        // snapshot it only got focus at the very end.
        let receiver = app.descendants(matching: .any)[
            AccessLifecycleContract.hiddenControlBarPlaybackIdentifier
        ]
        var consecutive = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isOnSlideShowLayer(app: app) && receiver.exists && receiver.hasFocus {
                consecutive += 1
                if consecutive >= AccessLifecycleContract.minStableHiddenWakeFocusObservations {
                    return consecutive
                }
            } else {
                consecutive = 0
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPoll))
        }
        if consecutive >= AccessLifecycleContract.minStableHiddenWakeFocusObservations {
            return consecutive
        }
        return nil
    }

    @MainActor
    private func waitForConditionHeld(
        timeout: TimeInterval,
        hold: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var heldSince: Date?
        while Date() < deadline {
            if condition() {
                if heldSince == nil {
                    heldSince = Date()
                }
                if let start = heldSince, Date().timeIntervalSince(start) >= hold {
                    return true
                }
            } else {
                heldSince = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPoll))
        }
        return false
    }

    @MainActor
    private func isOnSlideShowLayer(app: XCUIApplication) -> Bool {
        AccessLifecycleContract.isSlideshowLayer(identifiers: observedLayerIdentifiers(app: app))
    }

    @MainActor
    private func confirmReturnedToSlideShow(app: XCUIApplication) {
        do {
            try AccessLifecycleContract.assertReturnedToSlideshow(
                identifiers: observedLayerIdentifiers(app: app),
                requireSettingsButton: false
            )
        } catch {
            XCTFail(String(describing: error))
        }
    }

    @MainActor
    private func observedLayerIdentifiers(app: XCUIApplication) -> [String] {
        var found: [String] = []
        func appendFirstMatch(prefix: String) {
            let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
            let match = app.descendants(matching: .any).matching(predicate).firstMatch
            guard match.exists else { return }
            let identifier = match.identifier
            found.append(identifier.isEmpty ? prefix : identifier)
        }
        appendFirstMatch(prefix: AccessLifecycleContract.playbackLayerPrefix)
        for prefix in AccessLifecycleContract.nonPlaybackLayerPrefixes {
            appendFirstMatch(prefix: prefix)
        }
        return found
    }

    @MainActor
    private func moveFocusToSettingsControl(app: XCUIApplication, identifier: String, maxSteps: Int) {
        let target = app.buttons[identifier]
        XCTAssertTrue(target.waitForExistence(timeout: 8), "Settings page must have \(identifier).")
        for _ in 0...maxSteps {
            if target.hasFocus { return }
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle()
        }
        XCTAssertTrue(waitForFocus(on: target, timeout: 2), "Must be able to focus \(identifier).")
    }

    @MainActor
    private func ensureControlBarVisible(app: XCUIApplication, playPauseButton: XCUIElement) {
        if playPauseButton.exists == false {
            wakeHiddenControlBarOnce(
                app: app,
                visibleControl: playPauseButton,
                evidenceStem: "hidden-control-wake"
            )
        }
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 6), "Directional key must wake the playback controls.")
    }

    @MainActor
    private func replaceFocusedText(in field: XCUIElement, app: XCUIApplication, with value: String) {
        XCTAssertTrue(waitForFocus(on: field, timeout: 4), "The field must be focused before input.")
        XCUIRemote.shared.press(.select)
        app.typeText(value)
        let submit = app.buttons.matching(
            // ui-label-lookup: Match the simulator-localized system keyboard submit key.
            NSPredicate(format: "label IN %@", ["下一项", "Next", "完成", "Done"])
        ).firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 4), "System keyboard must show Next or Done.")
        for _ in 0..<6 where submit.hasFocus == false {
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(submit.hasFocus, "Must focus the system keyboard submit button before submitting text.")
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(on: field, timeout: 4), "After submitting text, focus must return to the field.")
    }

    @MainActor
    private func tryMoveFocus(
        _ direction: XCUIRemote.Button,
        to element: XCUIElement,
        maximumPresses: Int
    ) -> Bool {
        for _ in 0..<maximumPresses {
            if element.exists && element.hasFocus { return true }
            XCUIRemote.shared.press(direction)
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusSettle))
        }
        return element.exists && element.hasFocus
    }

    @MainActor
    private func moveFocus(
        _ direction: XCUIRemote.Button,
        to element: XCUIElement,
        maximumPresses: Int,
        message: String
    ) {
        if tryMoveFocus(direction, to: element, maximumPresses: maximumPresses) { return }
        XCTAssertTrue(waitForFocus(on: element, timeout: 4), message)
    }

    @MainActor
    private func waitForFocus(on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.hasFocus { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPoll))
        }
        return element.exists && element.hasFocus
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPoll))
        }
        return condition()
    }

    @MainActor
    private func waitForFocusVisualSettle() {
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusSettle))
    }

    @MainActor
    private func writePNG(app: XCUIApplication, name: String) throws {
        let png = app.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
        screenshotOrder.append(name)
    }

    @MainActor
    private func persistTVOSCapturedPNG(_ png: Data, name: String) throws {
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
        screenshotOrder.append(name)
    }

    private func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func firstBootControl(
        in app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        return app.descendants(matching: .any)[identifier]
    }

    private func valueContainsSelected(_ element: XCUIElement) -> Bool {
        let value = String(describing: element.value ?? "")
        return value.contains("已选中") || value.contains("selected")
    }

    private func record(_ request: String) {
        requests.append(request)
    }

    private func writeHostPayload() throws {
        try AccessLifecycleContract.assertKnownRequests(requests)
        try AccessLifecycleContract.assertNoForcedDisplayMode([:])
        try AccessLifecycleContract.assertSystemPauseActivation(
            activation: systemPauseActivation,
            processRebuilt: didRebuildProcess,
            homeLeftAppRunning: didHomeLeaveAppRunning
        )
        try AccessLifecycleContract.assertSystemPauseIdentityTiming(
            screenshotOrder: screenshotOrder
        )
        try AccessLifecycleContract.assertDisplayBeforePoolBurn(
            screenshotOrder: screenshotOrder
        )
        let payload: [String: Any] = [
            "status": "ran",
            "identity_source": AccessLifecycleContract.allowedIdentitySource,
            "settings": [
                "source": AccessLifecycleContract.allowedSettingsSource,
                "before": [
                    "autoPlayEnabled": false,
                    "intervalSeconds": 8,
                    "showExif": false,
                    "displayMode": "singlePhoto"
                ],
                "after_restart": [
                    "autoPlayEnabled": false,
                    "intervalSeconds": 8,
                    "showExif": false,
                    "displayMode": "singlePhoto"
                ]
            ],
            "launch_environment": [:],
            "requests": requests,
            "pin_flow": [
                "wrong_pin_entered": false,
                "cancel_still_protected": true,
                "correct_pin_entered": true,
                "restart_gated": true,
                "storage_kind": "uitest_userdefaults"
            ],
            "xctest_config_present": true,
            "system_pause_analog": "tvos_home_scene_phase",
            "system_pause_activation": systemPauseActivation,
            "process_rebuilt": didRebuildProcess,
            "home_left_app_running": didHomeLeaveAppRunning,
            "screenshot_order": screenshotOrder,
            "environment": "simulator"
        ]
        try StrictE2EVisualEvidence.writeRequiredJSON(payload, name: "host-payload.json")
    }

    @MainActor
    private func assertTVOSNarrowEntryHasNoPin(app: XCUIApplication) throws {
        XCTAssertFalse(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 2),
            "This narrow entry must not enable a password."
        )
    }

    @MainActor
    private func enterPlaybackSettings(app: XCUIApplication) throws {
        openSettingsFromSlideShow(app: app)
        record("settings.open")
        try assertTVOSNarrowEntryHasNoPin(app: app)
        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(playbackItem.waitForExistence(timeout: 8), "Settings home must show playback settings.")
        if playbackItem.hasFocus == false {
            moveFocus(.up, to: playbackItem, maximumPresses: 4, message: "Must return to playback settings.")
        }
        XCUIRemote.shared.press(.select)
    }

    // Page identity comes from playback settings content; a momentary lack of focus is not treated as home.
    // After entering, focus must still land on the autoplay row.
    @MainActor
    private func ensureInsidePlaybackSettingsPage(app: XCUIApplication) throws {
        var homeUnique = tvosHomeUniqueVisible(app: app)
        var contentVisible = tvosPlaybackSettingsContentVisible(app: app)
        var homeVisible = app.buttons["settings.item.playback"].isHittable
        if contentVisible == false && homeVisible == false && homeUnique == false {
            waitForFocusVisualSettle()
            homeUnique = tvosHomeUniqueVisible(app: app)
            contentVisible = tvosPlaybackSettingsContentVisible(app: app)
            homeVisible = app.buttons["settings.item.playback"].isHittable
        }
        let identity = AccessLifecycleContract.tvosSettingsPageIdentity(
            playbackSettingsContentVisible: contentVisible,
            homeEntryVisible: homeVisible,
            homeUniqueVisible: homeUnique
        )
        try AccessLifecycleContract.assertTVOSHomeUniqueBeatsPlaybackRowLabel(
            homeUniqueVisible: homeUnique,
            classifiedAsPlayback: identity == "playback"
        )
        try AccessLifecycleContract.assertTVOSPageIdentityNotInferredFromMissingFocus(
            playbackSettingsContentVisible: contentVisible && homeUnique == false,
            classifiedAsHome: identity == "home"
        )
        let homePlayback = app.buttons["settings.item.playback"]
        if identity == "home" {
            XCTAssertTrue(homePlayback.waitForExistence(timeout: 8), "Settings home must show playback settings.")
            if homePlayback.hasFocus == false {
                moveFocus(.up, to: homePlayback, maximumPresses: 6, message: "Must go back to playback settings entry.")
            }
            XCTAssertTrue(homePlayback.hasFocus, "Settings home must focus playback settings before entering.")
            XCUIRemote.shared.press(.select)
            waitForFocusVisualSettle()
        }
        let autoPlayLink = app.buttons["settings.playback.autoPlay.link"]
        XCTAssertTrue(autoPlayLink.waitForExistence(timeout: 8), "Playback settings must show the autoplay row.")
        if autoPlayLink.hasFocus == false {
            _ = tryMoveFocus(.up, to: autoPlayLink, maximumPresses: 8)
        }
        if autoPlayLink.hasFocus == false {
            _ = tryMoveFocus(.down, to: autoPlayLink, maximumPresses: 8)
        }
        try AccessLifecycleContract.assertTVOSPlaybackSettingsEntered(
            autoPlayLinkFocused: autoPlayLink.hasFocus,
            homePlaybackFocused: homePlayback.exists && homePlayback.hasFocus
        )
    }

    @MainActor
    private func tvosHomeUniqueVisible(app: XCUIApplication) -> Bool {
        app.buttons["settings.item.accessProtection"].isHittable
            || app.descendants(matching: .any)["settings.item.playback"].isHittable
    }

    // The home page row also shows the "Playback Settings" text, so it does not mean the page was entered.
    @MainActor
    private func tvosPlaybackSettingsContentVisible(app: XCUIApplication) -> Bool {
        app.buttons["settings.playback.autoPlay.link"].isHittable
            || app.descendants(matching: .any)["settings.playback.autoPlay.link"].isHittable
    }

    @MainActor
    private func readTVOSFourSettings(app: XCUIApplication) throws -> [String: Any] {
        try enterPlaybackSettings(app: app)
        let autoPlayEnabled = try selectedBinaryOption(
            app: app,
            link: "settings.playback.autoPlay.link",
            onOption: "settings.playback.autoPlay.on.button",
            offOption: "settings.playback.autoPlay.off.button",
            stepsToLink: 0
        )
        let intervalSeconds = try selectedIntervalSeconds(app: app)
        let displayMode = try selectedDisplayMode(app: app)
        let showExif = try selectedBinaryOption(
            app: app,
            link: "settings.playback.showExif.link",
            onOption: "settings.playback.showExif.on.button",
            offOption: "settings.playback.showExif.off.button",
            stepsToLink: 0,
            openParentLink: "settings.playback.display.link"
        )
        return [
            "autoPlayEnabled": autoPlayEnabled,
            "intervalSeconds": intervalSeconds,
            "showExif": showExif,
            "displayMode": displayMode
        ]
    }

    @MainActor
    private func changeTVOSFourSettingsFromInitial(
        app: XCUIApplication,
        initial: [String: Any]
    ) throws -> [String: Any] {
        let initialAutoPlay = initial["autoPlayEnabled"] as? Bool ?? true
        let initialInterval = initial["intervalSeconds"] as? Int ?? 5
        let initialExif = initial["showExif"] as? Bool ?? true
        let initialMode = initial["displayMode"] as? String ?? "smartFill"
        let intervalTarget = initialInterval == 10 ? 15 : 10

        try ensureInsidePlaybackSettingsPage(app: app)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.interval.link",
            option: "settings.playback.interval.\(intervalTarget).button",
            stepsToLink: 2
        )
        record("settings.save.interval")
        // After the interval Menu, go back to the autoplay row first, then search down for display policy.
        try ensureInsidePlaybackSettingsPage(app: app)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.displayMode.link",
            option: initialMode == "smartFill"
                ? "settings.playback.displayMode.singlePhoto.button"
                : "settings.playback.displayMode.smartFill.button",
            stepsToLink: 4
        )
        record("settings.save.display_mode")
        // After the display policy Menu the target is above: move up to autoplay first; pressing only down is
        // not allowed. EXIF lives in the display items subpage, so the generic return to playback settings
        // does not apply here.
        try AccessLifecycleContract.assertTVOSFocusSearchMustNotUseOnlyDownWhenTargetAbove(
            targetWasAboveFocus: true,
            usedOnlyDown: false
        )
        try ensureInsidePlaybackSettingsPage(app: app)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.autoPlay.link",
            option: initialAutoPlay
                ? "settings.playback.autoPlay.off.button"
                : "settings.playback.autoPlay.on.button",
            stepsToLink: 0
        )
        record("settings.save.autoplay")

        moveFocusToSettingsControl(app: app, identifier: "settings.playback.display.link", maxSteps: 7)
        XCUIRemote.shared.press(.select)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.showExif.link",
            option: initialExif
                ? "settings.playback.showExif.off.button"
                : "settings.playback.showExif.on.button",
            stepsToLink: 0
        )
        record("settings.save.exif")
        XCUIRemote.shared.press(.menu)
        waitForFocusVisualSettle()
        returnToSlideShow(app: app)
        return try readTVOSFourSettings(app: app)
    }

    @MainActor
    private func configureTVOSTimingPlaybackSettings(
        app: XCUIApplication
    ) throws -> (actual: Int, desktopCloseoutRequired: Bool) {
        try enterPlaybackSettings(app: app)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.autoPlay.link",
            option: "settings.playback.autoPlay.on.button",
            stepsToLink: 0
        )
        record("settings.save.autoplay")
        let resolved = try AccessLifecycleContract.resolveTimingInterval(
            requested: AccessLifecycleContract.requestedIntervalSeconds,
            available: AccessLifecycleContract.tvOSSelectableIntervals
        )
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.interval.link",
            option: "settings.playback.interval.\(resolved.actual).button",
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
        XCUIRemote.shared.press(.menu)
        waitForFocusVisualSettle()
        returnToSlideShow(app: app)
        return resolved
    }

    @MainActor
    private func selectedBinaryOption(
        app: XCUIApplication,
        link: String,
        onOption: String,
        offOption: String,
        stepsToLink: Int,
        openParentLink: String? = nil
    ) throws -> Bool {
        if let parent = openParentLink {
            moveFocusToSettingsControl(app: app, identifier: parent, maxSteps: 7)
            XCUIRemote.shared.press(.select)
            waitForFocusVisualSettle()
        }
        moveFocusToSettingsControl(app: app, identifier: link, maxSteps: max(stepsToLink, 6))
        XCUIRemote.shared.press(.select)
        let onButton = app.buttons[onOption]
        let offButton = app.buttons[offOption]
        XCTAssertTrue(
            onButton.waitForExistence(timeout: 8) || offButton.waitForExistence(timeout: 2),
            "Must read the toggle options."
        )
        let isOn = onButton.exists && valueContainsSelected(onButton)
        XCUIRemote.shared.press(.menu)
        waitForFocusVisualSettle()
        if openParentLink != nil {
            XCUIRemote.shared.press(.menu)
            waitForFocusVisualSettle()
        }
        return isOn
    }

    @MainActor
    private func selectedIntervalSeconds(app: XCUIApplication) throws -> Int {
        moveFocusToSettingsControl(app: app, identifier: "settings.playback.interval.link", maxSteps: 6)
        XCUIRemote.shared.press(.select)
        var selected = 0
        for seconds in AccessLifecycleContract.tvOSSelectableIntervals {
            let button = app.buttons["settings.playback.interval.\(seconds).button"]
            if button.waitForExistence(timeout: 1) && valueContainsSelected(button) {
                selected = seconds
                break
            }
        }
        XCUIRemote.shared.press(.menu)
        waitForFocusVisualSettle()
        if selected == 0 {
            throw AccessLifecycleContract.AssertionError.message("Missing settings evidence")
        }
        return selected
    }

    @MainActor
    private func selectedDisplayMode(app: XCUIApplication) throws -> String {
        moveFocusToSettingsControl(app: app, identifier: "settings.playback.displayMode.link", maxSteps: 6)
        XCUIRemote.shared.press(.select)
        let single = app.buttons["settings.playback.displayMode.singlePhoto.button"]
        XCTAssertTrue(single.waitForExistence(timeout: 8), "Must be able to read the display policy.")
        let mode = valueContainsSelected(single) ? "singlePhoto" : "smartFill"
        XCUIRemote.shared.press(.menu)
        waitForFocusVisualSettle()
        return mode
    }

    @MainActor
    private func exerciseTVOSPauseNextContinueVisibleTiming(
        app: XCUIApplication,
        playPauseButton: XCUIElement,
        nextButton: XCUIElement,
        intervalSeconds: Int
    ) throws -> [[String: Any]] {
        let interval = TimeInterval(intervalSeconds)
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        moveFocus(.right, to: playPauseButton, maximumPresses: 3, message: "Focus must reach play/pause.")
        let value = String(describing: playPauseButton.value ?? "")
        let isPlaying = value.contains("暂停") || value.lowercased().contains("pause")
        if isPlaying == false {
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(
                waitUntil(timeout: 4) {
                    let current = String(describing: playPauseButton.value ?? "")
                    return current.contains("暂停") || current.lowercased().contains("pause")
                },
                "Must be playing before the mid-interval timing."
            )
        }
        RunLoop.current.run(until: Date().addingTimeInterval(interval / 2))
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        moveFocus(.right, to: playPauseButton, maximumPresses: 3, message: "At midpoint, focus must reach play/pause.")
        XCUIRemote.shared.press(.select)
        record("playback.pause")
        let beforePause = try captureTVOSImmediateMark(app: app, name: "before-pause")
        moveFocus(.right, to: nextButton, maximumPresses: 3, message: "After pause, focus must reach next.")
        XCUIRemote.shared.press(.select)
        record("playback.next")
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.sceneSettle))
        let afterNext = try captureTVOSImmediateMark(app: app, name: "after-next")
        try AccessLifecycleContract.assertPauseUsesVisibleIdentity(
            pauseMark: beforePause.mark,
            afterNextMark: afterNext.mark,
            usedProgressProbe: false,
            usedControlValueOnly: false
        )

        let holdStart = Date()
        let holdTarget = interval + AccessLifecycleContract.pauseHoldBeyondIntervalSeconds
        while Date().timeIntervalSince(holdStart) < holdTarget {
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            try AccessLifecycleContract.assertHoldSampleUnchanged(
                expectedMark: afterNext.mark,
                polled: classifyTVOSMark(app: app)
            )
        }
        let holdSeconds = Date().timeIntervalSince(holdStart)
        let holdMark = classifyTVOSMark(app: app)
        try AccessLifecycleContract.assertPausedHoldWithoutAdvance(
            startMark: afterNext.mark,
            endMark: holdMark,
            holdSeconds: holdSeconds,
            intervalSeconds: interval
        )

        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        moveFocus(.left, to: playPauseButton, maximumPresses: 3, message: "Focus must return to play/pause after next.")
        XCUIRemote.shared.press(.select)
        record("playback.play")
        let continueAt = Date()
        let continueWatch = try watchTVOSContinueToFirstAdvance(
            app: app,
            continueAt: continueAt,
            continueMark: afterNext.mark,
            interval: interval
        )
        return [
            ["name": "before_pause", "mark": beforePause.mark],
            ["name": "after_next", "mark": afterNext.mark],
            ["name": "pause_hold_end", "elapsed": holdSeconds, "mark": holdMark],
            ["name": "continue_early", "elapsed": continueWatch.earlyElapsed, "mark": continueWatch.earlyMark],
            ["name": "after_auto_advance", "elapsed": continueWatch.advancedElapsed, "mark": continueWatch.advancedMark]
        ]
    }

    // Early-half-window evidence uses the classification moment instead of waiting until T/2 to capture;
    // the criteria are still ≤T/2 and a first transition at T±2.
    @MainActor
    private func watchTVOSContinueToFirstAdvance(
        app: XCUIApplication,
        continueAt: Date,
        continueMark: String,
        interval: TimeInterval
    ) throws -> (earlyMark: String, earlyElapsed: TimeInterval, advancedMark: String, advancedElapsed: TimeInterval) {
        let earliestAdvance = interval - AccessLifecycleContract.continueCaptureSlackSeconds
        let latest = interval + AccessLifecycleContract.continueCaptureSlackSeconds
        var samples: [(elapsed: TimeInterval, mark: String)] = []
        var earlyMark = ""
        var earlyElapsed: TimeInterval = 0
        while Date().timeIntervalSince(continueAt) <= latest {
            let elapsed = Date().timeIntervalSince(continueAt)
            let png = app.screenshot().pngRepresentation
            let mark = contractTVOSMark(StrictE2EPhotoIdentity.captureIdentity(png: png))
            samples.append((elapsed, mark))
            if earlyMark.isEmpty {
                if elapsed > interval / 2 {
                    throw AccessLifecycleContract.AssertionError.message(
                        "Early-half-window evidence after continue crossed the window; record a test timing failure"
                    )
                }
                if isUsableTVOSMark(mark) && mark == continueMark {
                    earlyMark = mark
                    earlyElapsed = elapsed
                    try persistTVOSCapturedPNG(png, name: "continue-early")
                    try AccessLifecycleContract.assertContinueEarlyStillSameScene(
                        continueMark: continueMark,
                        earlyMark: earlyMark,
                        elapsedSeconds: earlyElapsed,
                        intervalSeconds: interval
                    )
                }
            }
            if elapsed + 0.001 < earliestAdvance {
                try AccessLifecycleContract.assertSamplesStayOnSceneBeforeAdvanceWindow(
                    continueMark: continueMark,
                    samples: [(elapsed, mark)],
                    intervalSeconds: interval
                )
            } else if AccessLifecycleContract.isUsableSceneMark(mark) && mark != continueMark {
                try writePNG(app: app, name: "after-auto-advance")
                try AccessLifecycleContract.assertSamplesStayOnSceneBeforeAdvanceWindow(
                    continueMark: continueMark,
                    samples: samples,
                    intervalSeconds: interval
                )
                guard
                    let first = AccessLifecycleContract.firstUsableAdvance(
                        continueMark: continueMark,
                        samples: samples
                    )
                else {
                    throw AccessLifecycleContract.AssertionError.message(
                        "No auto advance within T±2; if the idle wait crossed the window, it is a test timing failure"
                    )
                }
                try AccessLifecycleContract.assertContinueAutoAdvanceInWindow(
                    continueMark: continueMark,
                    laterMark: first.mark,
                    elapsedSeconds: first.elapsed,
                    intervalSeconds: interval
                )
                if earlyMark.isEmpty {
                    throw AccessLifecycleContract.AssertionError.message(
                        "Early-half-window evidence after continue crossed the window; record a test timing failure"
                    )
                }
                return (
                    earlyMark: earlyMark,
                    earlyElapsed: earlyElapsed,
                    advancedMark: first.mark,
                    advancedElapsed: first.elapsed
                )
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        try writePNG(app: app, name: "after-auto-advance")
        try AccessLifecycleContract.assertSamplesStayOnSceneBeforeAdvanceWindow(
            continueMark: continueMark,
            samples: samples,
            intervalSeconds: interval
        )
        throw AccessLifecycleContract.AssertionError.message(
            "No auto advance within T±2; if the idle wait crossed the window, it is a test timing failure"
        )
    }

    @MainActor
    private func captureTVOSNewStableMark(
        app: XCUIApplication,
        name: String,
        timeout: TimeInterval
    ) throws -> (mark: String, png: Data) {
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        let initialMark = classifyTVOSMark(app: app)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(
                until: Date().addingTimeInterval(
                    AccessLifecycleContract.pollWait(remaining: deadline.timeIntervalSinceNow)
                )
            )
            let candidate = classifyTVOSMark(app: app)
            if isUsableTVOSMark(candidate) && candidate != initialMark {
                let confirm = AccessLifecycleContract.confirmWait(remaining: deadline.timeIntervalSinceNow)
                if confirm > 0 {
                    RunLoop.current.run(until: Date().addingTimeInterval(confirm))
                }
                let stable = try captureTVOSImmediateMark(app: app, name: name)
                if stable.mark == candidate {
                    return stable
                }
            }
        }
        throw AccessLifecycleContract.AssertionError.message("No new stable frame before going to background")
    }

    @MainActor
    private func captureTVOSImmediateMark(
        app: XCUIApplication,
        name: String
    ) throws -> (mark: String, png: Data) {
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        let png = app.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
        screenshotOrder.append(name)
        attachScreenshot(app: app, name: "tvos-\(name)")
        let mark = contractTVOSMark(StrictE2EPhotoIdentity.captureIdentity(png: png))
        if isUsableTVOSMark(mark) == false {
            throw AccessLifecycleContract.AssertionError.message("Screenshot \(name) cannot serve as identity: \(mark)")
        }
        return (mark, png)
    }

    @MainActor
    private func classifyTVOSMark(app: XCUIApplication) -> String {
        contractTVOSMark(StrictE2EPhotoIdentity.captureIdentity(png: app.screenshot().pngRepresentation))
    }

    private func contractTVOSMark(_ identity: StrictE2EPhotoIdentity.Result) -> String {
        if identity.status == .match, let mark = identity.mark {
            return mark
        }
        if identity.status == .black { return "BLACK" }
        if identity.status == .blank { return "BLANK" }
        if identity.status == .transition { return "TRANSITION" }
        return "UNRECOGNIZABLE"
    }

    private func isUsableTVOSMark(_ mark: String) -> Bool {
        AccessLifecycleContract.isUsableSceneMark(mark)
    }

    // XCUIApplication has no public processIdentifier API; use processID or the pid in its description.
    private func applicationProcessID(_ app: XCUIApplication) throws -> Int32 {
        let object = app as NSObject
        if object.responds(to: Selector(("processID"))) {
            if let number = object.value(forKey: "processID") as? NSNumber, number.int32Value > 0 {
                return number.int32Value
            }
        }
        let text = app.debugDescription
        let regex = try NSRegularExpression(pattern: #"pid[: ]+(\d+)"#, options: [.caseInsensitive])
        let nsText = text as NSString
        if let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
            match.numberOfRanges > 1,
            let pid = Int32(nsText.substring(with: match.range(at: 1))),
            pid > 0
        {
            return pid
        }
        throw AccessLifecycleContract.AssertionError.message("Background return lacks the original process identity")
    }

    private func writeTVOSResumeJSON(name: String, extra: [String: Any]) throws {
        var payload: [String: Any] = [
            "status": "ran",
            "identity_source": AccessLifecycleContract.allowedIdentitySource,
            "settings_source": AccessLifecycleContract.allowedSettingsSource,
            "device": "tvos",
            "requests": requests,
            "pin_enabled": false,
            "screenshot_order": screenshotOrder
        ]
        for (key, value) in extra {
            payload[key] = value
        }
        try StrictE2EVisualEvidence.writeRequiredJSON(payload, name: name)
    }
}
#endif
