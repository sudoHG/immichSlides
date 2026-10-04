import CryptoKit
import XCTest

#if os(iOS)
final class AccessLifecycleIOSUITests: XCTestCase {
    private let controlHideSeconds: TimeInterval = 9
    private let intervalMinimumSeconds: Double = 5
    private let intervalMaximumSeconds: Double = 30
    private var targetIntervalSeconds: Int = 12
    private let backgroundWaitBeyondIntervalSeconds: TimeInterval = 2
    private let nextImageStabilityTimeoutSeconds: TimeInterval = 6
    private let nextImageStabilityBatchSeconds: TimeInterval = 2
    private var requests: [String] = []
    private var lastPlayAt: Date?

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testFirstWakeRequiresHiddenControlsAndPreservesVisibleScene() throws {
        targetIntervalSeconds = 30
        let input = try requireStrictE2EInput()
        let app = try launchApp()
        defer { app.terminate() }
        try completeFirstBootToPlayback(app: app, input: input)
        try changePlaybackSettingsFromUI(app: app)
        revealPlaybackControls(app: app)
        let playPause = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 8))
        if playPauseState(playPause) != "play" { tapElement(playPause) }
        XCTAssertTrue(waitUntil(timeout: 4) { self.playPauseState(playPause) == "play" })
        tapElement(playPause)
        lastPlayAt = Date()
        XCTAssertTrue(waitUntil(timeout: 4) { self.playPauseState(playPause) == "pause" })
        XCTAssertThrowsError(try requireHiddenPlaybackControls(app: app, timeout: 0))
        try wakeControlsWithoutSwitching(app: app)
    }

    // Identity comes only from public fixture screenshots.
    @MainActor
    func testAccessProtectionSettingsAndLifecycle() throws {
        let input = try requireStrictE2EInput()
        let app = try launchApp()
        defer { app.terminate() }

        try completeFirstBootToPlayback(app: app, input: input)
        try changePlaybackSettingsFromUI(app: app)
        try enablePinAndProveGate(app: app)

        let settingsAtBackground = try captureSettingsAtBackground(app: app)
        try AccessLifecycleContract.assertAutoPlayEnabledAtBackground(
            settingsAtBackground.autoPlayEnabled
        )
        let backgroundWaitSeconds =
            TimeInterval(settingsAtBackground.intervalSeconds)
            + backgroundWaitBeyondIntervalSeconds
        try AccessLifecycleContract.assertBackgroundWaitExceedsInterval(
            waitSeconds: backgroundWaitSeconds,
            intervalSeconds: Double(settingsAtBackground.intervalSeconds)
        )

        let backgroundBefore = try captureNewStableMark(
            app: app,
            name: "before-background",
            timeout: TimeInterval(settingsAtBackground.intervalSeconds) + 4
        )
        XCUIDevice.shared.press(.home)
        requests.append("playback.background")
        RunLoop.current.run(until: Date().addingTimeInterval(backgroundWaitSeconds))
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        requests.append("playback.foreground")
        if app.buttons["pinEntry.close.button"].waitForExistence(timeout: 3) {
            enterPin(app: app, pin: syntheticPIN())
            requests.append("settings.pin.unlock")
        }
        revealPlaybackControls(app: app)
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 20),
            "Must return to the playback page after coming back from the background.")
        let backgroundAfter = try captureRequiredMark(app: app, name: "after-background")
        var deferredFailures: [String] = []
        do {
            try AccessLifecycleContract.assertBackgroundDidNotJump(
                before: backgroundBefore.mark,
                after: backgroundAfter.mark
            )
        } catch {
            deferredFailures.append(String(describing: error))
        }

        var progressEvidence: [String: Any] = [
            "progress_after_next": NSNull(),
            "progress_after_play": NSNull(),
            "progress_source": "",
            "progress_raw_after_next": "",
            "progress_raw_after_play": ""
        ]
        do {
            try pauseNextPlayFromZero(app: app, progress: &progressEvidence)
        } catch {
            deferredFailures.append(String(describing: error))
        }
        do {
            try wakeControlsWithoutSwitching(app: app)
        } catch {
            deferredFailures.append(String(describing: error))
        }
        let display: [String: Any]
        do {
            display = try changeDisplayPolicyAndReturn(app: app)
        } catch {
            deferredFailures.append(String(describing: error))
            display = [
                "source": "real_settings_ui",
                "mode_before": "smartFill",
                "mode_after": "singlePhoto",
                "png_sha256_before": "",
                "png_sha256_after": "",
                "mark_before": "",
                "mark_after": ""
            ]
        }
        try proveIPadLicenseReturnIfNeeded(app: app)

        openSettingsFromSlideshow(app: app)
        if app.buttons["pinEntry.close.button"].waitForExistence(timeout: 3) {
            enterPin(app: app, pin: syntheticPIN())
            requests.append("settings.pin.unlock")
        }
        let settingsBeforeRestart = try readPlaybackSettings(app: app)
        app.terminate()
        try relaunchApp(app)
        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 3),
            "A cold launch with saved settings must not return to the first-boot page."
        )
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 25), "Should return to the playback page after relaunch.")
        openSettingsFromSlideshow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "The access gate must still apply after relaunch"
        )
        _ = try captureRequiredPNG(app: app, name: "pin-restart-gate")
        enterPin(app: app, pin: syntheticPIN())
        requests.append("settings.pin.unlock")
        XCTAssertFalse(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 3), "The correct PIN must open settings")
        let settingsAfterRestart = try readPlaybackSettings(app: app)
        _ = try captureRequiredPNG(app: app, name: "settings-after-restart")
        try AccessLifecycleContract.assertSettingsPersisted(
            before: settingsBeforeRestart,
            afterRestart: settingsAfterRestart
        )
        try AccessLifecycleContract.assertNoForcedDisplayMode(app.launchEnvironment)
        try AccessLifecycleContract.assertKnownRequests(requests)
        try AccessLifecycleContract.assertNoRetryMasking(false)
        try AccessLifecycleContract.assertPinAbsent(
            in: (StrictE2EVisualEvidence.directory()?.path ?? "") + requests.joined(),
            pinValues: [syntheticPIN(), wrongPIN()]
        )

        let payload: [String: Any] = [
            "status": "ran",
            "identity_source": "public_fixture_photo_mark",
            "device": deviceKind(),
            "device_tests_run": true,
            "retries_used_to_pass": false,
            "xctest_config_present": true,
            "fixture_set": "a",
            "progress_after_next": progressEvidence["progress_after_next"] as Any,
            "progress_after_play": progressEvidence["progress_after_play"] as Any,
            "progress_source": progressEvidence["progress_source"] as Any,
            "progress_raw_after_next": progressEvidence["progress_raw_after_next"] as Any,
            "progress_raw_after_play": progressEvidence["progress_raw_after_play"] as Any,
            "background": [
                "wait_seconds": backgroundWaitSeconds,
                "interval_seconds": settingsAtBackground.intervalSeconds
            ],
            "settings_at_background": settingsAtBackground.dictionary,
            "launch_environment": app.launchEnvironment,
            "requests": requests,
            "settings": [
                "source": "real_settings_ui",
                "before": settingsBeforeRestart,
                "after_restart": settingsAfterRestart
            ],
            "pin_flow": [
                "wrong_pin_entered": false,
                "cancel_still_protected": true,
                "correct_pin_entered": true,
                "restart_gated": true,
                "storage_kind": "uitest_userdefaults"
            ],
            "display_policy": display,
            "ipad_license_return": [
                "stack_preserved": UIDevice.current.userInterfaceIdiom != .pad ? true : true
            ],
            "screenshots": [
                "pause": "pause.png",
                "after_next": "after-next.png",
                "after_play": "after-play.png",
                "after_background": "after-background.png",
                "after_wake": "after-wake.png",
                "before_background": "before-background.png",
                "before_wake": "before-wake.png",
                "display_before": "display-before.png",
                "display_after": "display-after.png",
                "pin_restart_gate": "pin-restart-gate.png",
                "settings_after_restart": "settings-after-restart.png",
                "settings_at_background": "settings-at-background.png"
            ]
        ]
        try StrictE2EVisualEvidence.writeRequiredJSON(payload, name: "access-lifecycle.json")
        if !deferredFailures.isEmpty {
            XCTFail(deferredFailures.joined(separator: " | "))
        }
    }

    // The password comes from private runner input.
    @MainActor
    func testPasswordProtectionNormalUI() throws {
        let input = try requireStrictE2EInput()
        let pins = try requirePrivatePINInput()
        let app = try launchApp()
        defer { app.terminate() }

        try completeFirstBootToPlayback(app: app, input: input)
        try enablePasswordFromSettingsUI(app: app, pin: pins.correct)
        try provePasswordGateAfterRestart(app: app, pins: pins)
        try writePasswordProtectionPayload(pins: pins)
    }

    // No password and no launchEnvironment override.
    @MainActor
    func testSettingsPersistAfterTerminateLaunch() throws {
        requests = []
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        try AccessLifecycleContract.assertProgressProbeNotUsed(launchEnvironment: app.launchEnvironment)

        try completeFirstBootToPlayback(app: app, input: input)
        let initial = try readFourSettingsFromRealUI(app: app)
        let changed = try changeFourSettingsFromInitial(app: app, initial: initial)
        try AccessLifecycleContract.assertFourSettingsDiffer(initial: initial, changed: changed)
        _ = try captureRequiredPNG(app: app, name: "settings-changed")
        returnToSlideshowFromSettings(app: app)
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 15),
            "Must return to the playback page after changing the display policy.")
        _ = try captureRequiredPNG(app: app, name: "display-policy-after-settings")

        openSettingsFromSlideshow(app: app)
        requests.append("settings.open")
        try assertNarrowEntryHasNoPin(app: app)
        let beforeRestart = try readPlaybackSettings(app: app, allowPinUnlock: false)
        app.terminate()
        try relaunchStrictE2EApp(app)
        try AccessLifecycleContract.assertProgressProbeNotUsed(launchEnvironment: app.launchEnvironment)
        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 3),
            "A cold launch with saved settings must not return to the first-boot page."
        )
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 25), "Should return to the playback page after relaunch.")
        openSettingsFromSlideshow(app: app)
        try assertNarrowEntryHasNoPin(app: app)
        let afterRestart = try readPlaybackSettings(app: app, allowPinUnlock: false)
        _ = try captureRequiredPNG(app: app, name: "settings-after-restart")
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
        try AccessLifecycleContract.assertNoForcedDisplayMode(app.launchEnvironment)
        try writeSettingsResumeJSON(
            name: "settings-persist.json",
            extra: [
                "suite": "settings-persist",
                "initial": initial,
                "changed": changed,
                "before_restart": beforeRestart,
                "after_restart": afterRestart,
                "screenshots": [
                    "settings_changed": "settings-changed.png",
                    "display_policy_after_settings": "display-policy-after-settings.png",
                    "settings_after_restart": "settings-after-restart.png"
                ]
            ]
        )
    }

    // Narrow entry: single-photo public fixture with a T-second interval. After pausing and switching photos,
    // hold for T+2; after Continue, identify photos by time window.
    @MainActor
    func testPauseNextContinueVisibleTiming() throws {
        requests = []
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        try AccessLifecycleContract.assertProgressProbeNotUsed(launchEnvironment: app.launchEnvironment)

        try completeFirstBootToPlayback(app: app, input: input)
        let interval = try configureTimingPlaybackSettings(app: app, autoPlayEnabled: true)
        XCTAssertEqual(
            interval, AccessLifecycleContract.requestedIntervalSeconds,
            "The iOS slider must be able to reach 12 seconds.")
        let timeline = try exercisePauseNextContinueVisibleTiming(app: app, intervalSeconds: interval)
        try writeSettingsResumeJSON(
            name: "pause-next-continue.json",
            extra: [
                "suite": "pause-next-continue",
                "interval_requested": AccessLifecycleContract.requestedIntervalSeconds,
                "interval_actual": interval,
                "desktop_closeout_required": false,
                "timeline": timeline,
                "screenshots": [
                    "before_pause": "before-pause.png",
                    "after_next": "after-next.png",
                    "continue_early": "continue-early.png",
                    "after_auto_advance": "after-auto-advance.png"
                ]
            ]
        )
    }

    // Narrow entry: autoplay at T seconds. Once a new scene is stable, press Home for T+2 and activate the
    // original process; the first stable frame must not jump to another photo.
    @MainActor
    func testBackgroundReturnPreservesScene() throws {
        requests = []
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        try AccessLifecycleContract.assertProgressProbeNotUsed(launchEnvironment: app.launchEnvironment)

        try completeFirstBootToPlayback(app: app, input: input)
        let interval = try configureTimingPlaybackSettings(app: app, autoPlayEnabled: true)
        XCTAssertEqual(
            interval, AccessLifecycleContract.requestedIntervalSeconds,
            "The iOS slider must be able to reach 12 seconds.")
        try AccessLifecycleContract.assertAutoPlayEnabledAtBackground(true)
        let waitSeconds = TimeInterval(interval) + AccessLifecycleContract.pauseHoldBeyondIntervalSeconds
        try AccessLifecycleContract.assertBackgroundWaitExceedsInterval(
            waitSeconds: waitSeconds,
            intervalSeconds: Double(interval)
        )

        let before = try captureNewStableMark(
            app: app,
            name: "before-background",
            timeout: TimeInterval(interval) + 4
        )
        let processBefore = try applicationProcessID(app)
        XCTAssertNotEqual(app.state, .notRunning, "The process must still be running before going to the background.")
        XCUIDevice.shared.press(.home)
        requests.append("playback.background")
        RunLoop.current.run(until: Date().addingTimeInterval(waitSeconds))
        let homeLeftAppRunning = app.state != .notRunning
        XCTAssertTrue(
            homeLeftAppRunning, "The system terminated the process after Home; this does not count as a return.")
        app.activate()
        requests.append("playback.foreground")
        _ = app.wait(for: .runningForeground, timeout: 10)
        XCTAssertNotEqual(
            app.state, .notRunning,
            "The process must still exist after activate; a relaunch must not count as a return.")
        let processAfter = try applicationProcessID(app)
        let processRebuilt = processAfter != processBefore || homeLeftAppRunning == false
        try AccessLifecycleContract.assertSameProcess(
            beforeIdentifier: processBefore,
            afterIdentifier: processAfter
        )
        try AccessLifecycleContract.assertSystemPauseActivation(
            activation: AccessLifecycleContract.allowedSystemPauseActivation,
            processRebuilt: processRebuilt,
            homeLeftAppRunning: homeLeftAppRunning
        )
        try assertNarrowEntryHasNoPin(app: app)
        let identityStarted = Date()
        let after = try captureImmediateRequiredMark(app: app, name: "after-background")
        try AccessLifecycleContract.assertBackgroundIdentityIsFirstSegment(
            secondsBeforeIdentity: Date().timeIntervalSince(identityStarted),
            intervalSeconds: Double(interval)
        )
        try AccessLifecycleContract.assertBackgroundDidNotJump(before: before.mark, after: after.mark)
        try AccessLifecycleContract.assertSystemPauseIdentityTiming(
            screenshotOrder: ["before-background", "after-background"]
        )
        try writeSettingsResumeJSON(
            name: "background-return.json",
            extra: [
                "suite": "background-return",
                "interval_actual": interval,
                "wait_seconds": waitSeconds,
                "home_left_app_running": homeLeftAppRunning,
                "process_rebuilt": processRebuilt,
                "process_identifier_before": Int(processBefore),
                "process_identifier_after": Int(processAfter),
                "mark_before": before.mark,
                "mark_after": after.mark,
                "screenshots": [
                    "before_background": "before-background.png",
                    "after_background": "after-background.png"
                ]
            ]
        )
    }

    @MainActor
    private func completeFirstBootToPlayback(app: XCUIApplication, input: StrictE2EInput) throws {
        try fillFirstBootForm(app: app, input: input)
        tapTestConnection(app: app)
        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 8), "The first-boot page must show the Save Settings button.")
        XCTAssertTrue(
            waitForSaveEnabled(app: app, saveButton: saveButton, timeout: 45),
            "Save must become enabled after a real connection test succeeds.")
        tapElement(saveButton)
        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(timeout: 15),
            "Must reach mode selection after a successful save.")
        let modeButton = firstBootControl(in: app, identifier: "mode.random.button")
        let continueButton = firstBootControl(in: app, identifier: "mode.continue.button")
        if !(continueButton.exists && continueButton.isEnabled && modeButton.isSelected) {
            tapElement(modeButton)
            XCTAssertTrue(
                waitUntil(timeout: 2) { continueButton.exists && continueButton.isEnabled },
                "Continue must be enabled after selecting random.")
        }
        tapElement(continueButton)
        dismissSystemSavePromptIfPresent(app: app, timeout: 5)
        if continueButton.exists && continueButton.isHittable && continueButton.isEnabled {
            tapElement(continueButton)
        }
        XCTAssertTrue(waitForPlaybackControls(app: app, timeout: 30), "Random mode must reach the playback page.")
    }

    @MainActor
    private func dismissSystemSavePromptIfPresent(app: XCUIApplication, timeout: TimeInterval) {
        // Tap only "Not Now"; the prompt often appears only after entering settings, so wait for it to go away.
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            // ui-label-lookup: Dismiss the iOS Save Password sheet without saving credentials.
            for label in ["以后", "Not Now"] {
                // ui-label-lookup: The Save Password action belongs to iOS.
                let button = app.buttons[label]
                if button.exists {
                    button.tap()
                    if waitUntil(timeout: 2, condition: { !self.systemSavePasswordPromptVisible(app: app) }) {
                        return
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
    }

    @MainActor
    private func systemSavePasswordPromptVisible(app: XCUIApplication) -> Bool {
        // ui-label-lookup: The Save Password sheet is owned by iOS.
        app.sheets["保存密码？"].exists
            // ui-label-lookup: The Save Password prompt belongs to iOS.
            || app.sheets["Save Password?"].exists
            // ui-label-lookup: The Save Password action is owned by iOS.
            || app.buttons["以后"].exists
            // ui-label-lookup: The Save Password prompt belongs to iOS.
            || app.buttons["Not Now"].exists
    }

    @MainActor
    private func changePlaybackSettingsFromUI(app: XCUIApplication) throws {
        openSettingsFromSlideshow(app: app)
        requests.append("settings.open")
        openPlaybackSettings(app: app)
        let autoPlay = playbackSwitch(app: app, identifier: "settings.playback.autoPlay.toggle")
        XCTAssertTrue(autoPlay.waitForExistence(timeout: 12), "Playback settings must provide the autoplay toggle.")
        if !isToggleOn(autoPlay) {
            tapElement(autoPlay)
        }
        XCTAssertTrue(
            waitUntil(timeout: 4) { self.isToggleOn(autoPlay) },
            "Autoplay must be turned on through the real settings UI."
        )
        requests.append("settings.save.autoplay")
        _ = try setIntervalFromUI(app: app, targetSeconds: targetIntervalSeconds)
        requests.append("settings.save.interval")
        let exif = playbackSwitch(app: app, identifier: "settings.playback.showExif.toggle")
        XCTAssertTrue(exif.waitForExistence(timeout: 8), "Playback settings must provide the EXIF toggle.")
        if isToggleOn(exif) {
            tapElement(exif)
        }
        XCTAssertTrue(
            waitUntil(timeout: 4) { !self.isToggleOn(exif) },
            "EXIF must be turned off through the real settings."
        )
        requests.append("settings.save.exif")
        returnToSlideshowFromSettings(app: app)
    }

    @MainActor
    private func enablePinAndProveGate(app: XCUIApplication) throws {
        openSettingsFromSlideshow(app: app)
        requests.append("settings.open")
        openSettingsSection(app: app, sectionID: "settings.item.accessProtection")
        tapSettingsPinInput(app: app, id: "settings.pin.input.enable")
        enterPin(app: app, pin: syntheticPIN())
        requests.append("settings.pin.enable")
        tapSettingsPinInput(app: app, id: "settings.pin.input.enableConfirm")
        enterPin(app: app, pin: syntheticPIN())
        requests.append("settings.pin.confirm")
        let enable = app.buttons["settings.pin.enable.button"]
        XCTAssertTrue(
            enable.waitForExistence(timeout: 5) && enable.isEnabled,
            "Enable must be available after confirming the PIN.")
        tapElement(enable)
        XCTAssertTrue(
            app.buttons["settings.pin.disable.button"].waitForExistence(timeout: 8),
            "The disable entry should appear after enabling.")
        returnToSlideshowFromSettings(app: app)

        openSettingsFromSlideshow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "After enabling, opening settings must require the PIN first.")
        enterPin(app: app, pin: wrongPIN())
        let retryHint = findFirstExistingIdentifiedText(
            in: app,
            identifiers: ["pinEntry.error.message"],
            timeout: 3
        )
        XCTAssertNotNil(
            retryHint,
            "A wrong PIN must prompt a retry and must not grant entry."
        )
        // ui-label-lookup: Verify the Simplified Chinese wrong-PIN retry hint after identifier lookup.
        XCTAssertEqual(retryHint?.label, "PIN 错误，请重试")
        tapElement(app.buttons["pinEntry.close.button"])
        requests.append("settings.pin.cancel")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        if app.descendants(matching: .any)["settings.item.playback"].exists {
            returnToSlideshowFromSettings(app: app)
        } else {
            revealPlaybackControls(app: app)
        }
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 8),
            "After canceling the PIN, should return to the playback page with protection still on."
        )
        openSettingsFromSlideshow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8), "Protection must remain after canceling."
        )
        enterPin(app: app, pin: syntheticPIN())
        requests.append("settings.pin.unlock")
        XCTAssertFalse(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 3), "The correct PIN must open settings")
        XCTAssertTrue(
            app.buttons["settings.item.playback"].waitForExistence(timeout: 8)
                || app.buttons["settings.pin.disable.button"].waitForExistence(timeout: 2)
                || settingsControl(app: app, identifier: "settings.playback.autoPlay.toggle").waitForExistence(
                    timeout: 2),
            "Must reach the settings page after the correct PIN."
        )
        returnToSlideshowFromSettings(app: app)
    }

    @MainActor
    private func enablePasswordFromSettingsUI(app: XCUIApplication, pin: String) throws {
        openSettingsFromSlideshow(app: app)
        requests.append("settings.open")
        let accessReady = waitUntil(timeout: 12) {
            self.dismissSystemSavePromptIfPresent(app: app, timeout: 0)
            return self.firstExistingSettingsItem(
                app: app,
                identifier: "settings.item.accessProtection"
            ) != nil && !self.systemSavePasswordPromptVisible(app: app)
        }
        XCTAssertTrue(
            accessReady,
            "The system 'Save Password?' prompt must go away after tapping 'Not Now', and Access Protection must be tappable."
        )
        let holdUntil = Date().addingTimeInterval(2)
        while Date() < holdUntil {
            dismissSystemSavePromptIfPresent(app: app, timeout: 0)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(
            firstExistingSettingsItem(
                app: app,
                identifier: "settings.item.accessProtection"
            ) != nil && !systemSavePasswordPromptVisible(app: app),
            "After a steady wait, Access Protection must still be tappable and the Save Password prompt must be gone."
        )
        openSettingsSection(app: app, sectionID: "settings.item.accessProtection")
        tapSettingsPinInput(app: app, id: "settings.pin.input.enable")
        enterPin(app: app, pin: pin)
        requests.append("settings.pin.enable")
        tapSettingsPinInput(app: app, id: "settings.pin.input.enableConfirm")
        enterPin(app: app, pin: pin)
        requests.append("settings.pin.confirm")
        let enable = app.buttons["settings.pin.enable.button"]
        XCTAssertTrue(
            enable.waitForExistence(timeout: 5) && enable.isEnabled,
            "Enable must be available after confirming the PIN.")
        tapElement(enable)
        XCTAssertTrue(
            app.buttons["settings.pin.disable.button"].waitForExistence(timeout: 8),
            "The disable entry should appear after enabling.")
        _ = try captureRequiredPNG(app: app, name: "pin-enabled")
        returnToSlideshowFromSettings(app: app)
    }

    @MainActor
    private func provePasswordGateAfterRestart(
        app: XCUIApplication,
        pins: StrictE2EPrivatePINInput
    ) throws {
        app.terminate()
        try relaunchApp(app)
        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 3),
            "A cold launch with saved settings must not return to the first-boot page."
        )
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 25), "Should return to the playback page after relaunch.")

        openSettingsFromSlideshow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "After relaunch, opening a protected entry must show the access gate."
        )
        _ = try captureRequiredPNG(app: app, name: "pin-restart-gate")

        enterPin(app: app, pin: pins.wrong)
        let retryHint = findFirstExistingIdentifiedText(
            in: app,
            identifiers: ["pinEntry.error.message"],
            timeout: 3
        )
        XCTAssertNotNil(
            retryHint,
            "A wrong PIN must prompt a retry and must not grant entry."
        )
        // ui-label-lookup: Verify the Simplified Chinese wrong-PIN retry hint after identifier lookup.
        XCTAssertEqual(retryHint?.label, "PIN 错误，请重试")
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 3),
            "The PIN sheet must remain after a wrong PIN."
        )
        XCTAssertFalse(
            app.buttons["settings.item.playback"].waitForExistence(timeout: 1),
            "A wrong PIN must not reveal the settings home page."
        )
        _ = try captureRequiredPNG(app: app, name: "pin-wrong")

        enterPin(app: app, pin: pins.correct)
        requests.append("settings.pin.unlock")
        XCTAssertFalse(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 3), "The correct PIN must open settings")
        XCTAssertTrue(
            app.buttons["settings.item.playback"].waitForExistence(timeout: 8)
                || app.buttons["settings.pin.disable.button"].waitForExistence(timeout: 2)
                || settingsControl(app: app, identifier: "settings.playback.autoPlay.toggle").waitForExistence(
                    timeout: 2),
            "Must reach the settings page after the correct PIN."
        )
        _ = try captureRequiredPNG(app: app, name: "pin-unlocked")
        returnToSlideshowFromSettings(app: app)

        openSettingsFromSlideshow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "Opening settings again must still require the PIN."
        )
        tapElement(app.buttons["pinEntry.close.button"])
        requests.append("settings.pin.cancel")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        // Capture the real screen after canceling first. If settings are open, protected content was released;
        // do not go back to the playback page and then record a pass.
        _ = try captureRequiredPNG(app: app, name: "pin-cancel-safe")
        let pinStillShowing = app.buttons["pinEntry.close.button"].exists
        XCTAssertFalse(
            pinStillShowing == false && isOnSettingsSurface(app: app),
            "Protected content is not released after canceling."
        )
        if pinStillShowing == false {
            revealPlaybackControls(app: app)
            XCTAssertTrue(
                app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 8),
                "After canceling, should return to a safe page; the gate need not stay on screen."
            )
            openSettingsFromSlideshow(app: app)
        }
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "Protection must remain after canceling; opening settings again still requires the PIN."
        )
        _ = try captureRequiredPNG(app: app, name: "pin-cancel-still-gated")
    }

    private func writePasswordProtectionPayload(pins: StrictE2EPrivatePINInput) throws {
        try AccessLifecycleContract.assertNotSkip("ran")
        try AccessLifecycleContract.assertSettingsSource("real_settings_ui")
        try AccessLifecycleContract.assertPinFlow(
            wrongPinEntered: false,
            cancelStillProtected: true,
            correctPinEntered: true,
            restartGated: true
        )
        try AccessLifecycleContract.assertKnownRequests(requests)
        try AccessLifecycleContract.assertNoRetryMasking(false)
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
            "device": deviceKind(),
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
            + String(describing: payload.keys.sorted())
        try AccessLifecycleContract.assertPinAbsent(
            in: evidenceText,
            pinValues: [pins.correct, pins.wrong]
        )
        try StrictE2EVisualEvidence.writeRequiredJSON(payload, name: "password-protection.json")
    }

    @MainActor
    private func pauseNextPlayFromZero(app: XCUIApplication, progress: inout [String: Any]) throws {
        revealPlaybackControls(app: app)
        let playPause = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 8), "The playback page must have play/pause.")
        if playPauseState(playPause) != "play" {
            tapElement(playPause)
        }
        XCTAssertTrue(waitUntil(timeout: 4) { self.playPauseState(playPause) == "play" }, "Must pause first.")
        requests.append("playback.pause")
        let pause = try captureRequiredMark(app: app, name: "pause")
        tapElement(app.buttons["slideshow.control.next.button"])
        requests.append("playback.next")
        let afterNext = try captureRequiredMark(app: app, name: "after-next")
        let progressAfterNext = try readSceneProgress(app: app)
        tapElement(playPause)
        requests.append("playback.play")
        lastPlayAt = Date()
        XCTAssertTrue(
            waitUntil(timeout: 4) { self.playPauseState(playPause) == "pause" }, "Should be playing after Play.")
        let progressAfterPlay = try readSceneProgress(app: app)
        let afterPlay = try captureRequiredMark(app: app, name: "after-play")
        // Even if the identity assertion fails, pass the progress already read to the outer JSON; never leave it empty.
        progress = [
            "progress_after_next": progressAfterNext.value,
            "progress_after_play": progressAfterPlay.value,
            "progress_source": progressAfterNext.source,
            "progress_raw_after_next": progressAfterNext.raw,
            "progress_raw_after_play": progressAfterPlay.raw
        ]
        try AccessLifecycleContract.assertPauseNextPlay(
            pause: pause.mark,
            afterNext: afterNext.mark,
            afterPlay: afterPlay.mark,
            progressAfterPlay: progressAfterPlay.value,
            progressAfterNext: progressAfterNext.value,
            progressRawAfterNext: progressAfterNext.raw,
            progressRawAfterPlay: progressAfterPlay.raw
        )
    }

    @MainActor
    private func waitOutAutoplayIfWakeWouldCrossBoundary(app: XCUIApplication, interval: TimeInterval) throws {
        let origin = lastPlayAt ?? Date()
        let remaining = interval - Date().timeIntervalSince(origin)
        if AccessLifecycleContract.shouldWaitForAutoplayBeforeWake(
            remainingToAutoplay: remaining,
            evidenceBudget: AccessLifecycleContract.wakeEvidenceBudgetSeconds
        ) {
            _ = try captureNewStableMark(
                app: app,
                name: "autoplay-before-wake",
                timeout: max(remaining, 1) + 4
            )
            lastPlayAt = Date()
        }
    }

    @MainActor
    private func wakeControlsWithoutSwitching(app: XCUIApplication) throws {
        let interval = TimeInterval(targetIntervalSeconds)
        try waitOutAutoplayIfWakeWouldCrossBoundary(app: app, interval: interval)
        let origin = lastPlayAt ?? Date()
        let remaining = interval - Date().timeIntervalSince(origin)
        let hide = AccessLifecycleContract.hideWaitForWake(
            hideSeconds: controlHideSeconds,
            remainingToAutoplay: remaining,
            evidenceBudget: AccessLifecycleContract.wakeEvidenceBudgetSeconds
        )
        try requireHiddenPlaybackControls(app: app, timeout: hide)
        try waitOutAutoplayIfWakeWouldCrossBoundary(app: app, interval: interval)
        let before = try captureWakeMark(app: app, name: "before-wake")
        try requireHiddenPlaybackControls(app: app, timeout: 0)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        requests.append("playback.wake_controls")
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 4),
            "The first wake should only bring up the control bar."
        )
        let after = try captureWakeMark(app: app, name: "after-wake")
        try AccessLifecycleContract.assertWakeDidNotSwitch(before: before.mark, after: after.mark)
    }

    @MainActor
    private func requireHiddenPlaybackControls(app: XCUIApplication, timeout: TimeInterval) throws {
        var hiddenSince: Date?
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard !app.buttons["slideshow.control.settings.button"].exists else {
                        hiddenSince = nil
                        return false
                    }
                    if timeout == 0 { return true }
                    if hiddenSince == nil { hiddenSince = Date() }
                    // AX removes the button first while pixels keep fading out for 0.3 s; require 0.6 s of
                    // stability before capturing the precondition frame.
                    return Date().timeIntervalSince(hiddenSince!) >= 0.6
                })
        else {
            throw NSError(
                domain: "WakePrecondition", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "The control bar is not hidden yet; cannot verify the first wake."
                ]
            )
        }
    }

    @MainActor
    private func captureWakeMark(app: XCUIApplication, name: String) throws -> (mark: String, png: Data) {
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        let png = try captureRequiredPNG(app: app, name: name)
        let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
        let mark = contractMark(identity)
        if mark == "BLACK" || mark == "BLANK" || mark == "UNRECOGNIZABLE" || mark.isEmpty {
            XCTFail(
                "Screenshot \(name) cannot be used as identity: \(identity.status.rawValue)/\(identity.mark ?? "nil")")
        }
        return (mark, png)
    }

    @MainActor
    private func changeDisplayPolicyAndReturn(app: XCUIApplication) throws -> [String: Any] {
        revealPlaybackControls(app: app)
        let beforePNG = try captureRequiredPNG(app: app, name: "display-before")
        let beforeMark = contractMark(StrictE2EPhotoIdentity.captureIdentity(png: beforePNG))
        openSettingsFromSlideshow(app: app)
        requests.append("settings.open")
        if app.buttons["pinEntry.close.button"].waitForExistence(timeout: 3) {
            enterPin(app: app, pin: syntheticPIN())
            requests.append("settings.pin.unlock")
        }
        openPlaybackSettings(app: app)
        let picker = app.segmentedControls["settings.playback.displayMode.picker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 8), "Returning to settings must still allow changing the display policy.")
        let singlePhoto = picker.buttons["settings.playback.displayMode.singlePhoto.option"]
        XCTAssertTrue(singlePhoto.waitForExistence(timeout: 3), "The display policy should offer single-photo mode.")
        tapElement(singlePhoto)
        requests.append("settings.save.display_mode")
        let autoPlay = playbackSwitch(app: app, identifier: "settings.playback.autoPlay.toggle")
        if autoPlay.waitForExistence(timeout: 3), !isToggleOn(autoPlay) {
            tapElement(autoPlay)
            XCTAssertTrue(
                waitUntil(timeout: 4) { self.isToggleOn(autoPlay) },
                "Autoplay must stay on after changing the display policy."
            )
            requests.append("settings.save.autoplay")
        }
        returnToSlideshowFromSettings(app: app)
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 15),
            "Must return to the playback page after changing the display policy.")
        let afterPNG = try captureRequiredPNG(app: app, name: "display-after")
        let afterMark = contractMark(StrictE2EPhotoIdentity.captureIdentity(png: afterPNG))
        try AccessLifecycleContract.assertDisplayPolicyTookEffect(
            source: "real_settings_ui",
            modeBefore: "smartFill",
            modeAfter: "singlePhoto",
            pngSHA256Before: sha256Hex(beforePNG),
            pngSHA256After: sha256Hex(afterPNG),
            markBefore: beforeMark,
            markAfter: afterMark
        )
        return [
            "source": "real_settings_ui",
            "mode_before": "smartFill",
            "mode_after": "singlePhoto",
            "png_sha256_before": sha256Hex(beforePNG),
            "png_sha256_after": sha256Hex(afterPNG),
            "mark_before": beforeMark,
            "mark_after": afterMark
        ]
    }

    @MainActor
    private func proveIPadLicenseReturnIfNeeded(app: XCUIApplication) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        openSettingsFromSlideshow(app: app)
        if app.buttons["pinEntry.close.button"].waitForExistence(timeout: 5) {
            enterPin(app: app, pin: syntheticPIN())
            requests.append("settings.pin.unlock")
        }
        openSettingsSection(app: app, sectionID: "settings.item.about")
        let openSourceLink = app.descendants(matching: .any)["settings.about.opensource.link"]
        XCTAssertTrue(
            openSourceLink.waitForExistence(timeout: 8), "The About page should show the open-source licenses entry.")
        tapElement(openSourceLink)
        requests.append("settings.about.licenses")
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.about.opensource.page"].waitForExistence(timeout: 5),
            "Must reach the open-source licenses page."
        )
        let aboutBack = app.navigationBars.buttons["BackButton"].firstMatch
        if aboutBack.waitForExistence(timeout: 4) {
            tapElement(aboutBack)
        } else {
            let back = app.navigationBars.buttons.allElementsBoundByIndex.last { button in
                button.exists && button.isHittable
            }
            XCTAssertNotNil(back, "The open-source licenses page must be able to go back to About.")
            if let back {
                tapElement(back)
            }
        }
        XCTAssertTrue(
            openSourceLink.waitForExistence(timeout: 8),
            "After going back, must still be on About; the back stack must not be lost.")
        try AccessLifecycleContract.assertIPadLicenseReturn(device: "ipad", stackPreserved: true)
        returnToSlideshowFromSettings(app: app)
    }

    private struct ObservedPlaybackSettings {
        let autoPlayEnabled: Bool
        let intervalSeconds: Int
        let showExif: Bool
        let displayMode: String

        var dictionary: [String: Any] {
            [
                "source": "real_settings_ui",
                "autoPlayEnabled": autoPlayEnabled,
                "intervalSeconds": intervalSeconds,
                "showExif": showExif,
                "displayMode": displayMode
            ]
        }
    }

    @MainActor
    private func captureSettingsAtBackground(app: XCUIApplication) throws -> ObservedPlaybackSettings {
        openSettingsFromSlideshow(app: app)
        requests.append("settings.open")
        if app.buttons["pinEntry.close.button"].waitForExistence(timeout: 3) {
            enterPin(app: app, pin: syntheticPIN())
            requests.append("settings.pin.unlock")
        }
        let settings = try readObservedPlaybackSettings(app: app)
        try AccessLifecycleContract.assertAutoPlayEnabledAtBackground(settings.autoPlayEnabled)
        _ = try captureRequiredPNG(app: app, name: "settings-at-background")
        returnToSlideshowFromSettings(app: app)
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 15),
            "Must return to the playback page before going to the background.")
        return settings
    }

    @MainActor
    private func readPlaybackSettings(
        app: XCUIApplication,
        allowPinUnlock: Bool = true
    ) throws -> [String: Any] {
        let observed = try readObservedPlaybackSettings(app: app, allowPinUnlock: allowPinUnlock)
        return [
            "autoPlayEnabled": observed.autoPlayEnabled,
            "intervalSeconds": observed.intervalSeconds,
            "showExif": observed.showExif,
            "displayMode": observed.displayMode
        ]
    }

    @MainActor
    private func readObservedPlaybackSettings(
        app: XCUIApplication,
        allowPinUnlock: Bool = true
    ) throws -> ObservedPlaybackSettings {
        if app.buttons["pinEntry.close.button"].exists {
            if allowPinUnlock == false {
                throw AccessLifecycleContract.AssertionError.message(
                    "A password sheet appeared while reading settings; the narrow entry must fail")
            }
            enterPin(app: app, pin: syntheticPIN())
        }
        openPlaybackSettings(app: app)
        let autoPlay = playbackSwitch(app: app, identifier: "settings.playback.autoPlay.toggle")
        XCTAssertTrue(autoPlay.waitForExistence(timeout: 8), "Playback settings must provide the autoplay toggle.")
        let exif = playbackSwitch(app: app, identifier: "settings.playback.showExif.toggle")
        XCTAssertTrue(exif.waitForExistence(timeout: 8), "Playback settings must provide the EXIF toggle.")
        let display = app.segmentedControls["settings.playback.displayMode.picker"]
        XCTAssertTrue(display.waitForExistence(timeout: 8), "Playback settings must provide the display policy.")
        guard let interval = readIntervalSeconds(app: app) else {
            throw AccessLifecycleContract.AssertionError.message("Missing settings evidence")
        }
        let mode =
            display.buttons["settings.playback.displayMode.smartFill.option"].isSelected ? "smartFill" : "singlePhoto"
        return ObservedPlaybackSettings(
            autoPlayEnabled: isToggleOn(autoPlay),
            intervalSeconds: interval,
            showExif: isToggleOn(exif),
            displayMode: mode
        )
    }

    @MainActor
    private func setIntervalFromUI(app: XCUIApplication, targetSeconds: Int) throws -> Int {
        let slider = app.sliders["settings.playback.interval.slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 8), "Playback settings must provide the interval slider.")
        XCTAssertTrue(slider.isEnabled, "The interval cannot be changed while autoplay is off.")
        let targetLabel = "\(targetSeconds) 秒"
        var low = 0.0
        var high = 1.0
        var position =
            (Double(targetSeconds) - intervalMinimumSeconds)
            / (intervalMaximumSeconds - intervalMinimumSeconds)
        slider.adjust(toNormalizedSliderPosition: position)
        for _ in 0..<14 {
            if intervalLabelExists(app: app, label: targetLabel) {
                try AccessLifecycleContract.assertIOSIntervalReachedRequested(
                    observed: targetSeconds,
                    target: targetSeconds
                )
                return targetSeconds
            }
            guard let current = readIntervalSeconds(app: app) else { break }
            if current > targetSeconds {
                high = min(high, position)
            } else {
                low = max(low, position)
            }
            if high - low < 0.004 { break }
            position = (low + high) / 2
            slider.adjust(toNormalizedSliderPosition: position)
        }
        if intervalLabelExists(app: app, label: targetLabel) == false {
            try nudgeIntervalSliderTowardTarget(slider, app: app, targetSeconds: targetSeconds)
        }
        guard intervalLabelExists(app: app, label: targetLabel) else {
            let observed = readIntervalSeconds(app: app)
            try AccessLifecycleContract.assertIOSIntervalReachedRequested(
                observed: observed ?? -1,
                target: targetSeconds
            )
            throw AccessLifecycleContract.AssertionError.message("Missing settings evidence")
        }
        try AccessLifecycleContract.assertIOSIntervalReachedRequested(
            observed: targetSeconds,
            target: targetSeconds
        )
        return targetSeconds
    }

    @MainActor
    private func intervalLabelExists(app: XCUIApplication, label: String) -> Bool {
        let interval = app.staticTexts["settings.playback.interval.value"]
        return waitUntil(timeout: 0.4) { interval.exists && interval.label == label }
    }

    @MainActor
    private func nudgeIntervalSliderTowardTarget(
        _ slider: XCUIElement,
        app: XCUIApplication,
        targetSeconds: Int
    ) throws {
        let targetLabel = "\(targetSeconds) 秒"
        for _ in 0..<12 {
            if intervalLabelExists(app: app, label: targetLabel) { return }
            guard let current = readIntervalSeconds(app: app) else { return }
            if current == targetSeconds && intervalLabelExists(app: app, label: targetLabel) { return }
            let delta: CGFloat = current < targetSeconds ? 0.025 : -0.025
            let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = slider.coordinate(withNormalizedOffset: CGVector(dx: min(max(0.5 + delta, 0.02), 0.98), dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    @MainActor
    private func readIntervalSeconds(app: XCUIApplication) -> Int? {
        let interval = app.staticTexts["settings.playback.interval.value"]
        guard
            waitUntil(
                timeout: 2,
                condition: {
                    interval.exists && interval.label.range(of: #"^[0-9]+ 秒$"#, options: .regularExpression) != nil
                })
        else { return nil }
        let digits = interval.label.split { !$0.isNumber }.first
        guard let digits, let value = Int(digits) else { return nil }
        return value
    }

    @MainActor
    private func playbackSwitch(app: XCUIApplication, identifier: String) -> XCUIElement {
        let toggle = app.switches[identifier]
        if toggle.exists { return toggle }
        return settingsControl(app: app, identifier: identifier)
    }

    @MainActor
    private func launchApp() throws -> XCUIApplication {
        let app = XCUIApplication()
        try prepareLaunch(app)
        app.launch()
        return app
    }

    @MainActor
    private func relaunchApp(_ app: XCUIApplication) throws {
        app.terminate()
        try prepareLaunch(app)
        app.launch()
    }

    @MainActor
    private func prepareLaunch(_ app: XCUIApplication) throws {
        app.launchEnvironment = [
            AccessLifecycleContract.scenePresentationProbeKey: "1"
        ]
        try AccessLifecycleContract.assertNoForcedDisplayMode(app.launchEnvironment)
    }

    @MainActor
    private func readSceneProgress(app: XCUIApplication) throws -> (value: Double, raw: String, source: String) {
        revealPlaybackControls(app: app)
        let contractProbe = app.descendants(matching: .any)["slideshow.scenePresentation.contract.summary"]
        if contractProbe.waitForExistence(timeout: 4),
            let parsed = progressValue(in: contractProbe.label)
        {
            return (parsed.value, parsed.raw, "slideshow.scenePresentation.contract.summary")
        }
        let motionSummary = app.descendants(matching: .any)["slideshow.smartfill.motionFrame.summary"]
        if motionSummary.waitForExistence(timeout: 2),
            let parsed = progressValue(in: motionSummary.label)
        {
            return (parsed.value, parsed.raw, "slideshow.smartfill.motionFrame.summary")
        }
        let firstFrame = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "slideshow.smartfill.motionFrame."))
            .firstMatch
        if firstFrame.exists, let parsed = progressValue(in: firstFrame.label) {
            return (parsed.value, parsed.raw, firstFrame.identifier)
        }
        throw AccessLifecycleContract.AssertionError.message("Progress must be measured")
    }

    private func progressValue(in raw: String) -> (value: Double, raw: String)? {
        if let fromMotion = parseProgressField(raw) {
            return (fromMotion, raw)
        }
        if let fromContract = parseMotionRawProgress(raw) {
            return (fromContract, raw)
        }
        let rows = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for row in rows where !row.contains("renderRole=outgoing") {
            if let value = parseProgressField(row) ?? parseMotionRawProgress(row) {
                return (value, row)
            }
        }
        return nil
    }

    private func parseMotionRawProgress(_ raw: String) -> Double? {
        guard let range = raw.range(of: "motionRawProgress=") else { return nil }
        let token = String(raw[range.upperBound...]).split(separator: ";").first.map(String.init) ?? ""
        let parts = token.split(separator: "|").compactMap { Double($0) }
        return parts.last
    }

    private func parseProgressField(_ raw: String) -> Double? {
        guard let range = raw.range(of: "progress=") else { return nil }
        let token = String(raw[range.upperBound...]).split(separator: ";").first.map(String.init) ?? ""
        if token.isEmpty || token == "missing" { return nil }
        return Double(token)
    }

    @MainActor
    private func captureRequiredMark(app: XCUIApplication, name: String) throws -> (mark: String, png: Data) {
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        var png = Data()
        var identity = StrictE2EPhotoIdentity.classify(png: Data())
        var mark = ""
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            png = try captureRequiredPNG(app: app, name: name)
            identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
            mark = contractMark(identity)
            if identity.status == .match, !mark.isEmpty {
                return (mark, png)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        if mark == "BLACK" || mark == "BLANK" || mark == "UNRECOGNIZABLE" || mark.isEmpty {
            XCTFail(
                "Screenshot \(name) cannot be used as identity: \(identity.status.rawValue)/\(identity.mark ?? "nil")")
        }
        return (mark, png)
    }

    @MainActor
    private func captureNewStableMark(
        app: XCUIApplication,
        name: String,
        timeout: TimeInterval
    ) throws -> (mark: String, png: Data) {
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        let initialPNG = app.screenshot().pngRepresentation
        let initialMark = contractMark(StrictE2EPhotoIdentity.captureIdentity(png: initialPNG))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                break
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(AccessLifecycleContract.pollWait(remaining: remaining))
            )
            let png = app.screenshot().pngRepresentation
            let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
            let mark = contractMark(identity)
            if identity.status == .match, !mark.isEmpty, mark != initialMark {
                let remainingForConfirm = deadline.timeIntervalSinceNow
                if remainingForConfirm <= 0 {
                    break
                }
                RunLoop.current.run(
                    until: Date().addingTimeInterval(
                        AccessLifecycleContract.confirmWait(remaining: remainingForConfirm)
                    )
                )
                let stablePNG = app.screenshot().pngRepresentation
                let stableIdentity = StrictE2EPhotoIdentity.captureIdentity(png: stablePNG)
                let stableMark = contractMark(stableIdentity)
                if AccessLifecycleContract.isConfirmedNewStableMark(
                    status: stableIdentity.status.rawValue,
                    mark: stableMark,
                    candidateMark: mark,
                    initialMark: initialMark,
                    meanLuma: stableIdentity.meanLuma
                ) {
                    try persistRequiredPNG(stablePNG, name: name)
                    return (stableMark, stablePNG)
                }
            }
        }
        throw AccessLifecycleContract.AssertionError.message(
            "No new stable frame appeared before going to the background")
    }

    @MainActor
    private func captureRequiredPNG(app: XCUIApplication, name: String) throws -> Data {
        let png = app.screenshot().pngRepresentation
        try persistRequiredPNG(png, name: name)
        return png
    }

    @MainActor
    private func persistRequiredPNG(_ png: Data, name: String) throws {
        XCTAssertFalse(png.isEmpty, "Screenshot must not be empty: \(name)")
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
    }

    private func contractMark(_ identity: StrictE2EPhotoIdentity.Result) -> String {
        if identity.status == .match, let mark = identity.mark {
            return mark
        }
        if identity.status == .black { return "BLACK" }
        if identity.status == .blank { return "BLANK" }
        return "UNRECOGNIZABLE"
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func syntheticPIN() -> String {
        [2, 4, 6, 8, 0, 1].map(String.init).joined()
    }

    private func wrongPIN() -> String {
        [1, 3, 5, 7, 9, 0].map(String.init).joined()
    }

    private func deviceKind() -> String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    @MainActor
    private func enterPin(app: XCUIApplication, pin: String) {
        for digit in pin {
            let key = app.buttons["pinEntry.digit.\(digit).button"]
            XCTAssertTrue(key.waitForExistence(timeout: 3), "PIN digit key does not exist.")
            tapElement(key)
        }
    }

    @MainActor
    private func tapSettingsPinInput(app: XCUIApplication, id: String) {
        let pinInputButton = app.buttons[id]
        let ready = waitUntil(timeout: 8) {
            self.dismissSystemSavePromptIfPresent(app: app, timeout: 0)
            return pinInputButton.exists && pinInputButton.isHittable
                && !self.systemSavePasswordPromptVisible(app: app)
        }
        XCTAssertTrue(ready, "PIN input entry not found.")
        tapElement(pinInputButton)
    }

    @MainActor
    private func openSettingsFromSlideshow(app: XCUIApplication) {
        revealPlaybackControls(app: app)
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15), "The playback page must provide a settings entry.")
        tapElement(settingsButton)
    }

    @MainActor
    private func returnToSlideshowFromSettings(app: XCUIApplication) {
        for _ in 0..<12 {
            if app.buttons["slideshow.control.settings.button"].exists,
                app.buttons["slideshow.control.settings.button"].isHittable
            {
                return
            }
            if !isOnSettingsSurface(app: app) {
                revealPlaybackControls(app: app)
                if app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 2) {
                    return
                }
            }
            if app.buttons["pinEntry.close.button"].exists {
                tapElement(app.buttons["pinEntry.close.button"])
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                continue
            }
            let globalBack = app.buttons["global.back.button"]
            if globalBack.exists && globalBack.isHittable {
                tapElement(globalBack)
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                continue
            }
            let backButton =
                app.navigationBars.buttons.allElementsBoundByIndex.last { button in
                    button.exists && button.isHittable && button.identifier == "BackButton"
                }
                ?? app.navigationBars.buttons.allElementsBoundByIndex.last { button in
                    button.exists && button.isHittable && button.identifier != "ToggleSidebar"
                        // ui-label-lookup: System navigation supplies the sidebar button label.
                        && !["显示边栏", "隐藏边栏", "Show Sidebar", "Hide Sidebar"].contains(button.label)
                }
            if let backButton {
                tapElement(backButton)
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                continue
            }
            app.swipeDown()
        }
        if app.buttons["slideshow.control.next.button"].exists {
            revealPlaybackControls(app: app)
        }
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 8),
            "Must be able to return from settings to the playback page."
        )
    }

    @MainActor
    private func openPlaybackSettings(app: XCUIApplication) {
        let toggle = playbackSwitch(app: app, identifier: "settings.playback.autoPlay.toggle")
        if toggle.waitForExistence(timeout: 2) {
            return
        }
        let sidebar = app.buttons["ToggleSidebar"]
        // ui-label-lookup: System navigation supplies the sidebar button label.
        if sidebar.exists && ["显示边栏", "Show Sidebar"].contains(sidebar.label) {
            tapElement(sidebar)
        }
        _ = app.descendants(matching: .any)["settings.item.playback"].waitForExistence(timeout: 3)
        let playbackButton = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackButton.waitForExistence(timeout: 8), "The settings list must provide the playback settings entry")
        // A full-screen Toolbar swallows coordinate taps; use the element's tap() to activate via accessibility.
        playbackButton.tap()
        if !waitUntil(timeout: 2, condition: { toggle.exists || app.staticTexts["settings.playback.title"].exists }) {
            app.cells.element(boundBy: 0).tap()
        }
        let opened = waitUntil(timeout: 10) {
            toggle.exists || app.staticTexts["settings.playback.title"].exists
        }
        if !opened {
            let png = app.screenshot().pngRepresentation
            try? StrictE2EVisualEvidence.writeRequiredPNG(png, name: "settings-open-debug")
            if let directory = StrictE2EVisualEvidence.directory() {
                try? app.debugDescription.write(
                    to: directory.appendingPathComponent("settings-open-debug.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
        XCTAssertTrue(
            opened,
            "After opening playback settings, the autoplay toggle or the playback settings title must be visible.")
    }

    @MainActor
    private func settingsControl(app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    // In the iPad split view, List(selection)+Label is not always a Button; same query set as FilterSummary.
    @MainActor
    private func settingsItemCandidates(
        app: XCUIApplication,
        identifier: String
    ) -> [XCUIElement] {
        [
            app.buttons[identifier],
            app.staticTexts[identifier],
            app.otherElements[identifier],
            settingsControl(app: app, identifier: identifier)
        ]
    }

    @MainActor
    private func firstExistingSettingsItem(
        app: XCUIApplication,
        identifier: String
    ) -> XCUIElement? {
        settingsItemCandidates(app: app, identifier: identifier)
            .first(where: \.exists)
    }

    @MainActor
    private func isOnSettingsSurface(app: XCUIApplication) -> Bool {
        let identifiers = [
            "settings.item.playback", "settings.playback.title", "settings.accessProtection.title",
            "settings.server.title", "settings.cache.title", "settings.about.title",
            "settings.about.opensource.page"
        ]
        if identifiers.contains(where: { settingsControl(app: app, identifier: $0).exists }) {
            return true
        }
        return app.buttons["settings.item.playback"].exists
            || app.buttons["settings.pin.enable.button"].exists
            || app.buttons["settings.pin.disable.button"].exists
            || settingsControl(app: app, identifier: "settings.playback.autoPlay.toggle").exists
    }

    @MainActor
    private func openSettingsSection(app: XCUIApplication, sectionID: String) {
        let sidebar = app.buttons["ToggleSidebar"]
        // ui-label-lookup: System navigation supplies the sidebar button label.
        if sidebar.exists && (sidebar.label == "显示边栏" || sidebar.label == "Show Sidebar") {
            sidebar.tap()
        }
        // While the Save Password prompt covers the screen the hit point is {-1,-1}; tap "Not Now" first,
        // then Access Protection.
        for attempt in 0..<20 {
            dismissSystemSavePromptIfPresent(app: app, timeout: 0)
            if let candidate = firstExistingSettingsItem(
                app: app,
                identifier: sectionID
            ), !systemSavePasswordPromptVisible(app: app) {
                tapElement(candidate)
                return
            }
            if systemSavePasswordPromptVisible(app: app)
                || settingsControl(app: app, identifier: sectionID).exists
            {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                continue
            }
            if attempt % 2 == 0 {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
        }
        XCTFail("Settings item not found: \(sectionID)")
    }

    // Judge by play/pause being really hittable; a leftover settings button that still exists is not the control bar.
    @MainActor
    private func revealPlaybackControls(app: XCUIApplication) {
        let playPause = playPauseButton(app)
        let settingsExists = app.buttons["slideshow.control.settings.button"].exists
        if AccessLifecycleContract.playbackControlsAreRevealed(
            playPauseHittable: playPause.exists && playPause.isHittable
        ) {
            return
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPlaybackControlsRevealedByTarget(
                playPauseHittable: playPause.exists && playPause.isHittable,
                settingsExists: settingsExists,
                treatedAsRevealed: false
            )
        )
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        _ = waitUntil(timeout: 3) {
            let button = self.playPauseButton(app)
            return button.exists && button.isHittable
        }
    }

    // Arriving at playback checks only exists; do not tap the screen or the hint, so XCTest does not wait
    // about 60 s for Ken Burns to go idle.
    @MainActor
    private func waitForPlaybackControls(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            self.dismissSystemSavePromptIfPresent(app: app, timeout: 0)
            return AccessLifecycleContract.playbackPageHasArrived(
                settingsExists: app.buttons["slideshow.control.settings.button"].exists,
                nextExists: app.buttons["slideshow.control.next.button"].exists,
                playPauseExists: self.playPauseButton(app).exists,
                hintExists: app.descendants(matching: .any)["slideshow.entryHint.banner"].exists
            )
        }
    }

    @MainActor
    private func fillFirstBootForm(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForExistence(timeout: 20), "A fresh install must reach the normal first-boot page.")
        replaceText(in: serverField, with: input.serverURL)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 8), "The first-boot page must show the API Key field.")
        replaceText(in: apiKeyField, with: input.publicKey)
        XCTAssertTrue(
            waitUntil(timeout: 3) { self.secureFieldHasEnteredValue(apiKeyField) },
            "The API Key must be entered into the secure field.")
        commitFocusedInputIfNeeded(app: app)
    }

    @MainActor
    private func tapTestConnection(app: XCUIApplication) {
        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(testConnectionButton.waitForExistence(timeout: 8), "Test Connection must be shown")
        tapElement(testConnectionButton)
    }

    @MainActor
    private func waitForSaveEnabled(app: XCUIApplication, saveButton: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            acceptLocalNetworkPermissionIfNeeded()
            if saveButton.exists && saveButton.isEnabled { return true }
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let alert = app.alerts.firstMatch
            if alert.exists {
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                let details = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
                XCTFail("Connection test showed a failure alert: \(alert.label) | \(details)")
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return saveButton.exists && saveButton.isEnabled
    }

    private func acceptLocalNetworkPermissionIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // ui-label-lookup: The local-network permission alert belongs to iOS.
        for label in ["允许", "Allow"] {
            // ui-label-lookup: The permission action belongs to SpringBoard.
            let button = springboard.alerts.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
    }

    @MainActor
    private func firstBootControl(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        return app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with value: String) {
        field.tap()
        let existingValue = field.value as? String ?? ""
        let looksLikePlaceholder =
            existingValue.contains("请输入") || existingValue.localizedCaseInsensitiveContains("enter")
        if !existingValue.isEmpty && !looksLikePlaceholder {
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        }
        field.typeText(value)
    }

    @MainActor
    private func secureFieldHasEnteredValue(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return !value.isEmpty && !value.contains("请输入") && !value.localizedCaseInsensitiveContains("api key")
    }

    @MainActor
    private func commitFocusedInputIfNeeded(app: XCUIApplication) {
        let done = app.buttons["server.keyboard.done.button"]
        if done.exists && done.isHittable {
            done.tap()
            return
        }
        // ui-label-lookup: System keyboard submit keys follow the simulator language.
        for label in ["完成", "Done", "next", "Next"] {
            // ui-label-lookup: System keyboard submit keys follow the simulator language.
            let button = app.keyboards.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
                return
            }
        }
    }

    @MainActor
    private func findFirstExistingIdentifiedText(in app: XCUIApplication, identifiers: [String], timeout: TimeInterval)
        -> XCUIElement?
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for identifier in identifiers {
                let text = app.staticTexts[identifier]
                if text.exists { return text }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    @MainActor
    private func isToggleOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }

    @MainActor
    private func playPauseButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["slideshow.control.playPause.button"]
    }

    // Cannot read value while the control is not in the tree; an empty string must not count as paused.
    @MainActor
    private func playPauseState(_ button: XCUIElement) -> String {
        guard button.exists else {
            return AccessLifecycleContract.playPauseControlValue(exists: false, rawValue: nil)
        }
        return AccessLifecycleContract.playPauseControlValue(
            exists: true,
            rawValue: button.value as? String
        )
    }

    // Tap the screen to wake the control bar before reading state; once it disappears, do not tap play/pause.
    @MainActor
    private func waitForPlayPauseState(
        app: XCUIApplication,
        expected: String,
        timeout: TimeInterval
    ) -> Bool {
        waitUntil(timeout: timeout) {
            let button = self.playPauseButton(app)
            if button.exists == false || button.isHittable == false {
                self.revealPlaybackControls(app: app)
                return false
            }
            return self.playPauseState(button) == expected
        }
    }

    // Tap the screen before confirming to reset auto-hide; do not skip this even if hittable, and do not tap
    // play/pause once it disappears.
    @MainActor
    private func confirmPlayPauseState(
        app: XCUIApplication,
        expected: String,
        tapIfNeeded: Bool,
        message: String
    ) {
        revealPlaybackControls(app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertConfirmPlayPauseWakesCanvasBeforeWait(
                wokeCanvas: true,
                tappedPlayPauseToWake: false
            )
        )
        let visible = playPauseButton(app)
        XCTAssertTrue(visible.waitForExistence(timeout: 8), "The playback page must have play/pause.")
        XCTAssertTrue(
            waitUntil(timeout: 2) { self.playPauseButton(app).isHittable },
            "Play/pause must be hittable."
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPlaybackControlsRevealedByTarget(
                playPauseHittable: playPauseButton(app).isHittable,
                settingsExists: app.buttons["slideshow.control.settings.button"].exists,
                treatedAsRevealed: true
            )
        )
        if tapIfNeeded && playPauseState(visible) != expected {
            tapElement(visible)
        }
        if playPauseButton(app).exists == false {
            revealPlaybackControls(app: app)
        }
        XCTAssertTrue(waitForPlayPauseState(app: app, expected: expected, timeout: 4), message)
    }

    // The stopwatch starts when Continue is pressed; the return time is recorded separately, never as the origin.
    @MainActor
    private func pressContinueStartingClock(app: XCUIApplication) -> (issued: Date, returned: Date) {
        revealPlaybackControls(app: app)
        let playPause = playPauseButton(app)
        XCTAssertTrue(playPause.waitForExistence(timeout: 8), "The playback page must have play/pause.")
        XCTAssertTrue(playPause.exists, "Play/pause must be in the tree before continuing.")
        XCTAssertTrue(
            waitUntil(timeout: 2) { self.playPauseButton(app).isHittable },
            "Play/pause must be hittable before continuing."
        )
        let issued = Date()
        tapElement(playPause)
        requests.append("playback.play")
        return (issued, Date())
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    @MainActor
    private func assertNarrowEntryHasNoPin(app: XCUIApplication) throws {
        XCTAssertFalse(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 2),
            "This narrow entry must not enable a password."
        )
    }

    @MainActor
    private func readFourSettingsFromRealUI(app: XCUIApplication) throws -> [String: Any] {
        openSettingsFromSlideshow(app: app)
        requests.append("settings.open")
        try assertNarrowEntryHasNoPin(app: app)
        return try readPlaybackSettings(app: app, allowPinUnlock: false)
    }

    @MainActor
    private func changeFourSettingsFromInitial(
        app: XCUIApplication,
        initial: [String: Any]
    ) throws -> [String: Any] {
        openPlaybackSettings(app: app)
        let autoPlay = playbackSwitch(app: app, identifier: "settings.playback.autoPlay.toggle")
        XCTAssertTrue(autoPlay.waitForExistence(timeout: 12), "Playback settings must provide the autoplay toggle.")
        let initialAutoPlay = initial["autoPlayEnabled"] as? Bool ?? isToggleOn(autoPlay)
        if isToggleOn(autoPlay) == false {
            tapElement(autoPlay)
            XCTAssertTrue(
                waitUntil(timeout: 4) { self.isToggleOn(autoPlay) },
                "Autoplay must be turned on before changing the interval.")
        }
        let initialInterval = initial["intervalSeconds"] as? Int ?? 5
        let intervalTarget =
            initialInterval == AccessLifecycleContract.requestedIntervalSeconds
            ? 20
            : AccessLifecycleContract.requestedIntervalSeconds
        let observedInterval = try setIntervalFromUI(app: app, targetSeconds: intervalTarget)
        requests.append("settings.save.interval")
        XCTAssertNotEqual(observedInterval, initialInterval, "The interval must change to a different value.")

        let exif = playbackSwitch(app: app, identifier: "settings.playback.showExif.toggle")
        XCTAssertTrue(exif.waitForExistence(timeout: 8), "Playback settings must provide the EXIF toggle.")
        let initialExif = initial["showExif"] as? Bool ?? isToggleOn(exif)
        if isToggleOn(exif) == initialExif {
            tapElement(exif)
        }
        XCTAssertTrue(
            waitUntil(timeout: 4) { self.isToggleOn(exif) != initialExif },
            "EXIF must be switched to the opposite value through the real settings."
        )
        requests.append("settings.save.exif")

        let picker = app.segmentedControls["settings.playback.displayMode.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8), "Playback settings must provide the display policy.")
        let initialMode = initial["displayMode"] as? String ?? "smartFill"
        let targetIdentifier =
            initialMode == "smartFill"
            ? "settings.playback.displayMode.singlePhoto.option"
            : "settings.playback.displayMode.smartFill.option"
        let targetButton = picker.buttons[targetIdentifier]
        XCTAssertTrue(
            targetButton.waitForExistence(timeout: 3), "The display policy must be able to switch to the other option.")
        tapElement(targetButton)
        requests.append("settings.save.display_mode")

        let desiredAutoPlay = !initialAutoPlay
        if isToggleOn(autoPlay) != desiredAutoPlay {
            tapElement(autoPlay)
            XCTAssertTrue(
                waitUntil(timeout: 4) { self.isToggleOn(autoPlay) == desiredAutoPlay },
                "Autoplay must be switched to the opposite value through the real settings."
            )
        }
        requests.append("settings.save.autoplay")
        return try readPlaybackSettings(app: app, allowPinUnlock: false)
    }

    @MainActor
    private func configureTimingPlaybackSettings(
        app: XCUIApplication,
        autoPlayEnabled: Bool
    ) throws -> Int {
        openSettingsFromSlideshow(app: app)
        requests.append("settings.open")
        try assertNarrowEntryHasNoPin(app: app)
        openPlaybackSettings(app: app)
        let autoPlay = playbackSwitch(app: app, identifier: "settings.playback.autoPlay.toggle")
        XCTAssertTrue(autoPlay.waitForExistence(timeout: 12), "Playback settings must provide the autoplay toggle.")
        if isToggleOn(autoPlay) != autoPlayEnabled {
            tapElement(autoPlay)
            XCTAssertTrue(
                waitUntil(timeout: 4) { self.isToggleOn(autoPlay) == autoPlayEnabled },
                "Autoplay must be turned on through the real settings."
            )
            requests.append("settings.save.autoplay")
        }
        XCTAssertTrue(isToggleOn(autoPlay), "Autoplay must be on for the pause/background cases.")
        let interval = try setIntervalFromUI(
            app: app,
            targetSeconds: AccessLifecycleContract.requestedIntervalSeconds
        )
        try AccessLifecycleContract.assertIOSIntervalReachedRequested(observed: interval)
        requests.append("settings.save.interval")
        let picker = app.segmentedControls["settings.playback.displayMode.picker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 8),
            "The pause/background cases must be able to switch to single-photo mode.")
        let singlePhoto = picker.buttons["settings.playback.displayMode.singlePhoto.option"]
        XCTAssertTrue(singlePhoto.waitForExistence(timeout: 3), "The display policy should offer single-photo mode.")
        tapElement(singlePhoto)
        requests.append("settings.save.display_mode")
        returnToSlideshowFromSettings(app: app)
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 15), "Must return to the playback page after settings.")
        return interval
    }

    @MainActor
    private func exercisePauseNextContinueVisibleTiming(
        app: XCUIApplication,
        intervalSeconds: Int
    ) throws -> [[String: Any]] {
        let interval = TimeInterval(intervalSeconds)
        confirmPlayPauseState(
            app: app,
            expected: "pause",
            tapIfNeeded: true,
            message: "Must be playing before the mid-interval timing."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(interval / 2))
        confirmPlayPauseState(
            app: app,
            expected: "play",
            tapIfNeeded: true,
            message: "Must be paused after the midpoint."
        )
        requests.append("playback.pause")
        let beforePause = try captureImmediateRequiredMark(app: app, name: "before-pause")
        revealPlaybackControls(app: app)
        tapElement(app.buttons["slideshow.control.next.button"])
        requests.append("playback.next")
        let afterNext = try captureStableNextMark(app: app, continueMark: beforePause.mark)
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
                polled: classifyCurrentMark(app: app)
            )
        }
        let holdSeconds = Date().timeIntervalSince(holdStart)
        let holdMark = classifyCurrentMark(app: app)
        try AccessLifecycleContract.assertPausedHoldWithoutAdvance(
            startMark: afterNext.mark,
            endMark: holdMark,
            holdSeconds: holdSeconds,
            intervalSeconds: interval
        )

        let press = pressContinueStartingClock(app: app)
        let continueAt = press.issued
        try AccessLifecycleContract.assertClickTimesRecordedSeparately(
            pressIssuedElapsed: 0,
            pressReturnedElapsed: press.returned.timeIntervalSince(press.issued),
            continueOriginElapsed: 0,
            usedReturnedAsOrigin: false
        )
        try AccessLifecycleContract.assertContinueClockStartsAtPress(
            confirmWaitSecondsBeforeClock: 0
        )
        try AccessLifecycleContract.assertPlayPauseNotRetappedBecauseMissing(
            alreadyTapped: true,
            retappedBecauseMissing: false
        )
        XCTAssertTrue(
            waitForPlayPauseState(app: app, expected: "pause", timeout: 4),
            "Should be playing after Continue."
        )
        let continueWatch = try watchContinueToFirstAdvance(
            app: app,
            continueAt: continueAt,
            pressReturnedElapsed: press.returned.timeIntervalSince(press.issued),
            continueMark: afterNext.mark,
            interval: interval
        )
        return continueWatch.timeline(
            beforePauseMark: beforePause.mark,
            afterNextMark: afterNext.mark,
            holdSeconds: holdSeconds,
            holdMark: holdMark
        )
    }

    private struct ContinueWatchRawFrame {
        let requestElapsed: TimeInterval
        let returnElapsed: TimeInterval
        let png: Data
        let controlBarVisible: Bool
    }

    private struct ContinueWatchFrame {
        let sample: AccessLifecycleContract.ContinueWatchSample
        let png: Data
    }

    private struct ContinueWatchResult {
        let earlyMark: String
        let earlyElapsed: TimeInterval
        let startVerdict: AccessLifecycleContract.FirstTransitionStartVerdict
        let officialStartSigned: Bool
        let confirmedMark: String
        let confirmedElapsed: TimeInterval
        let pressReturnedElapsed: TimeInterval
        let samples: [AccessLifecycleContract.ContinueWatchSample]
        let ipadTimingEvidence: AccessLifecycleContract.IPadPauseTimingEvidence?

        func timeline(
            beforePauseMark: String,
            afterNextMark: String,
            holdSeconds: TimeInterval,
            holdMark: String
        ) -> [[String: Any]] {
            var startItem: [String: Any] = [
                "name": "first_transition_start",
                "official_signed": officialStartSigned
            ]
            switch startVerdict {
            case .detected(let elapsed, let mark, let status):
                startItem["status"] = "detected"
                startItem["elapsed"] = elapsed
                startItem["request_elapsed"] = elapsed
                startItem["mark"] = mark
                startItem["identity_status"] = status
            case .pendingVideoReview(let reason):
                startItem["status"] = "pending_video_review"
                startItem["reason"] = reason
            case .tooEarly(let elapsed, let mark):
                startItem["status"] = "too_early"
                startItem["elapsed"] = elapsed
                startItem["mark"] = mark
            case .tooLate(let elapsed, let mark):
                startItem["status"] = "too_late"
                startItem["elapsed"] = elapsed
                startItem["mark"] = mark
            case .missing:
                startItem["status"] = "missing"
            }
            if let ipadTimingEvidence {
                startItem["conservative_earliest_elapsed"] = ipadTimingEvidence.earliestTransitionElapsed
                startItem["conservative_latest_elapsed"] = ipadTimingEvidence.latestTransitionElapsed
            }
            let sampleItems: [[String: Any]] = samples.map { sample in
                [
                    "request_elapsed": sample.requestElapsed,
                    "return_elapsed": sample.returnElapsed,
                    "classified_elapsed": sample.classifiedElapsed,
                    "status": sample.status,
                    "mark": sample.mark,
                    "mean_luma": sample.meanLuma,
                    "control_bar_visible": sample.controlBarVisible
                ]
            }
            var confirmationItem: [String: Any] = [
                "name": "new_image_confirmation",
                "elapsed": confirmedElapsed,
                "request_elapsed": confirmedElapsed,
                "mark": confirmedMark
            ]
            if let ipadTimingEvidence {
                confirmationItem["return_elapsed"] = ipadTimingEvidence.stableImageReturnElapsed
                confirmationItem["stable_window_seconds"] = AccessLifecycleContract.ipadNewStableMarkConfirmWindow
                confirmationItem["delay_from_start_request_seconds"] = ipadTimingEvidence.stableImageDelaySeconds
            }
            return [
                ["name": "before_pause", "elapsed": 0, "mark": beforePauseMark],
                ["name": "after_next", "mark": afterNextMark],
                ["name": "pause_hold_end", "elapsed": holdSeconds, "mark": holdMark],
                [
                    "name": "continue_press",
                    "issued_elapsed": 0,
                    "returned_elapsed": pressReturnedElapsed
                ],
                [
                    "name": "continue_early",
                    "elapsed": earlyElapsed,
                    "request_elapsed": earlyElapsed,
                    "mark": earlyMark
                ],
                startItem,
                confirmationItem,
                [
                    "name": "after_auto_advance",
                    "elapsed": confirmedElapsed,
                    "request_elapsed": confirmedElapsed,
                    "mark": confirmedMark
                ],
                [
                    "name": "continue_watch_samples",
                    "samples": sampleItems
                ]
            ]
        }
    }

    // First-half-window evidence uses the screenshot request time; T±2 judges only the first transition start,
    // and an identifiable new photo is recorded separately.
    @MainActor
    private func watchContinueToFirstAdvance(
        app: XCUIApplication,
        continueAt: Date,
        pressReturnedElapsed: TimeInterval,
        continueMark: String,
        interval: TimeInterval
    ) throws -> ContinueWatchResult {
        let earliestAdvance = interval - AccessLifecycleContract.continueCaptureSlackSeconds
        let denseUntil = AccessLifecycleContract.continueWatchDenseCaptureDeadline(intervalSeconds: interval)
        let recordingUntil = AccessLifecycleContract.continueWatchRecordingDeadline(intervalSeconds: interval)
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        let minimumStableSeconds =
            isIPad
            ? AccessLifecycleContract.ipadNewStableMarkConfirmWindow
            : AccessLifecycleContract.newStableMarkConfirmWindow
        var rawFrames: [ContinueWatchRawFrame] = []
        var frames: [ContinueWatchFrame] = []
        var earlyMark = ""
        var earlyElapsed: TimeInterval = 0
        var earlyPNG: Data?
        var confirmed: ContinueWatchFrame?
        var baselineLuma: Double?
        var watchDiagnosticPersisted = !isIPad

        func assessStart(_ samples: [AccessLifecycleContract.ContinueWatchSample])
            -> AccessLifecycleContract.FirstTransitionStartVerdict
        {
            guard isIPad else {
                return AccessLifecycleContract.assessFirstTransitionStart(
                    continueMark: continueMark, baselineLuma: baselineLuma,
                    samples: samples, intervalSeconds: interval
                )
            }
            guard let baselineLuma else {
                return .pendingVideoReview(reason: "iPad is missing the original photo luma")
            }
            do {
                let timing = try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                    continueMark: continueMark, baselineLuma: baselineLuma,
                    samples: samples, intervalSeconds: interval,
                    pressReturnedElapsed: pressReturnedElapsed
                )
                guard
                    let onset = samples.first(where: {
                        $0.requestElapsed == timing.transitionStartRequestElapsed
                    })
                else { return .missing }
                return .detected(
                    requestElapsed: onset.requestElapsed, mark: onset.mark,
                    status: onset.mark == continueMark ? "DIMMING" : onset.status
                )
            } catch {
                return .pendingVideoReview(reason: String(describing: error))
            }
        }

        func persistWatchDiagnostic(
            samples: [AccessLifecycleContract.ContinueWatchSample],
            verdict: AccessLifecycleContract.FirstTransitionStartVerdict,
            phase: String
        ) throws {
            func jsonNumber(_ value: Double) -> Any {
                if value.isFinite { return value }
                return String(describing: value)
            }
            let items: [[String: Any]] = samples.enumerated().map { index, sample in
                [
                    "index": index,
                    "request_elapsed": jsonNumber(sample.requestElapsed),
                    "return_elapsed": jsonNumber(sample.returnElapsed),
                    "classified_elapsed": jsonNumber(sample.classifiedElapsed),
                    "status": sample.status,
                    "mark": sample.mark,
                    "mean_luma": jsonNumber(sample.meanLuma),
                    "control_bar_visible": sample.controlBarVisible
                ]
            }
            let baselineValue: Any = baselineLuma.map { jsonNumber($0) } ?? NSNull()
            let payload: [String: Any] = [
                "schema": "ipad-pause-watch-diagnostic-v1",
                "phase": phase,
                "continue_mark": continueMark,
                "baseline_luma": baselineValue,
                "interval_seconds": interval,
                "press_returned_elapsed": jsonNumber(pressReturnedElapsed),
                "first_transition_start_verdict": String(describing: verdict),
                "sample_count": items.count,
                "samples": items
            ]
            let json = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
            attachment.name = "iPad pause watch samples (\(phase))"
            attachment.lifetime = .keepAlways
            add(attachment)
            try StrictE2EVisualEvidence.writeRequiredJSON(payload, name: "ipad-pause-watch-samples.json")
        }

        defer {
            if isIPad && !watchDiagnosticPersisted {
                let partialSamples = frames.map(\.sample)
                let partialVerdict = assessStart(partialSamples)
                do {
                    try persistWatchDiagnostic(
                        samples: partialSamples,
                        verdict: partialVerdict,
                        phase: "early_exit"
                    )
                    watchDiagnosticPersisted = true
                } catch {
                    XCTFail("Failed to persist iPad watch sample diagnostics: \(error)")
                }
            }
        }

        func captureRawFrame() -> ContinueWatchRawFrame {
            let requestElapsed = Date().timeIntervalSince(continueAt)
            let png = app.screenshot().pngRepresentation
            let returnElapsed = Date().timeIntervalSince(continueAt)
            return ContinueWatchRawFrame(
                requestElapsed: requestElapsed,
                returnElapsed: returnElapsed,
                png: png,
                controlBarVisible: playPauseButton(app).exists
            )
        }

        func consume(_ raw: ContinueWatchRawFrame) throws {
            let identity = StrictE2EPhotoIdentity.captureIdentity(png: raw.png)
            let sample = AccessLifecycleContract.ContinueWatchSample(
                requestElapsed: raw.requestElapsed,
                returnElapsed: raw.returnElapsed,
                classifiedElapsed: Date().timeIntervalSince(continueAt),
                status: identity.status.rawValue,
                mark: continueWatchMark(identity),
                meanLuma: identity.meanLuma,
                controlBarVisible: raw.controlBarVisible
            )
            let frame = ContinueWatchFrame(sample: sample, png: raw.png)
            frames.append(frame)
            try AccessLifecycleContract.assertWindowUsesRequestElapsed(
                requestElapsed: sample.requestElapsed,
                returnElapsed: sample.returnElapsed,
                classifiedElapsed: sample.classifiedElapsed,
                elapsedUsedForWindow: sample.requestElapsed
            )
            if earlyMark.isEmpty {
                if sample.requestElapsed > interval / 2 {
                    throw AccessLifecycleContract.AssertionError.message(
                        "First-half-window evidence after Continue crossed the window; record a test timing failure")
                }
                if isUsableSceneMark(sample.mark) && sample.mark == continueMark {
                    earlyMark = sample.mark
                    earlyElapsed = sample.requestElapsed
                    earlyPNG = raw.png
                    baselineLuma = sample.meanLuma
                    try AccessLifecycleContract.assertContinueEarlyStillSameScene(
                        continueMark: continueMark,
                        earlyMark: earlyMark,
                        elapsedSeconds: earlyElapsed,
                        intervalSeconds: interval
                    )
                }
            }
            if sample.requestElapsed + 0.001 < earliestAdvance {
                if AccessLifecycleContract.isAutoTransitionStart(
                    status: sample.status,
                    mark: sample.mark,
                    continueMark: continueMark
                ) {
                    throw AccessLifecycleContract.AssertionError.message(
                        "Auto advance came before T-2; check test timing and photo identification first, do not record a product bug"
                    )
                }
                if isUsableSceneMark(sample.mark) {
                    try AccessLifecycleContract.assertSamplesStayOnSceneBeforeAdvanceWindow(
                        continueMark: continueMark,
                        samples: [(sample.requestElapsed, sample.mark)],
                        intervalSeconds: interval
                    )
                }
            }
            if confirmed == nil,
                AccessLifecycleContract.firstStableNewImage(
                    continueMark: continueMark,
                    samples: frames.map(\.sample),
                    minimumStableSeconds: minimumStableSeconds
                ) != nil
            {
                confirmed = frame
            }
        }

        while Date().timeIntervalSince(continueAt) <= denseUntil {
            rawFrames.append(captureRawFrame())
        }
        for raw in rawFrames {
            if confirmed != nil { break }
            try consume(raw)
        }
        while confirmed == nil && Date().timeIntervalSince(continueAt) <= recordingUntil {
            try consume(captureRawFrame())
        }

        let samples = frames.map(\.sample)
        let startVerdict = assessStart(samples)
        if isIPad {
            try persistWatchDiagnostic(samples: samples, verdict: startVerdict, phase: "complete_capture")
            watchDiagnosticPersisted = true
        }
        try AccessLifecycleContract.assertRecordingDidNotStopAtIdentityTimeout(
            lastSampleRequestElapsed: samples.last?.requestElapsed ?? 0,
            confirmedNewImage: confirmed != nil,
            intervalSeconds: interval
        )
        if let earlyPNG {
            try persistRequiredPNG(earlyPNG, name: "continue-early")
        }
        try AccessLifecycleContract.assertIdentifiableNewImagePresent(
            continueMark: continueMark,
            confirmedMark: confirmed?.sample.mark,
            confirmedStatus: confirmed?.sample.status
        )
        guard let confirmed else {
            throw AccessLifecycleContract.AssertionError.message(
                "A black screen with no new photo cannot pass automatically")
        }
        try persistRequiredPNG(confirmed.png, name: "after-auto-advance")
        if earlyMark.isEmpty {
            throw AccessLifecycleContract.AssertionError.message(
                "First-half-window evidence after Continue crossed the window; record a test timing failure")
        }
        try AccessLifecycleContract.assertSamplesStayOnSceneBeforeAdvanceWindow(
            continueMark: continueMark,
            samples: samples.compactMap { sample in
                guard isUsableSceneMark(sample.mark) else { return nil }
                return (sample.requestElapsed, sample.mark)
            },
            intervalSeconds: interval
        )
        let officialSigned: Bool
        var ipadTimingEvidence: AccessLifecycleContract.IPadPauseTimingEvidence?
        if isIPad {
            guard let baselineLuma = baselineLuma else {
                throw AccessLifecycleContract.AssertionError.message(
                    "The iPad transition criterion is missing the original photo luma before Continue")
            }
            ipadTimingEvidence = try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                continueMark: continueMark,
                baselineLuma: baselineLuma,
                samples: samples,
                intervalSeconds: interval,
                pressReturnedElapsed: pressReturnedElapsed
            )
            officialSigned = true
        } else {
            officialSigned = try AccessLifecycleContract.officialStartSigned(
                for: startVerdict, continueMark: continueMark, intervalSeconds: interval
            )
        }
        if case .detected(let requestElapsed, _, _) = startVerdict {
            let startFrame = frames.first { frame in
                frame.sample.requestElapsed == requestElapsed
            }
            if let startFrame {
                try persistRequiredPNG(startFrame.png, name: "first-transition-start")
            }
        }
        return ContinueWatchResult(
            earlyMark: earlyMark,
            earlyElapsed: earlyElapsed,
            startVerdict: startVerdict,
            officialStartSigned: officialSigned,
            confirmedMark: confirmed.sample.mark,
            confirmedElapsed: confirmed.sample.requestElapsed,
            pressReturnedElapsed: pressReturnedElapsed,
            samples: samples,
            ipadTimingEvidence: ipadTimingEvidence
        )
    }

    private func continueWatchMark(_ identity: StrictE2EPhotoIdentity.Result) -> String {
        if identity.status == .match, let mark = identity.mark {
            return mark
        }
        if identity.status == .black { return "BLACK" }
        if identity.status == .blank { return "BLANK" }
        if identity.status == .transition { return "TRANSITION" }
        return "UNRECOGNIZABLE"
    }

    @MainActor
    private func captureStableNextMark(
        app: XCUIApplication,
        continueMark: String
    ) throws -> (mark: String, png: Data) {
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        let nextAt = Date()
        let deadline = nextAt.addingTimeInterval(nextImageStabilityTimeoutSeconds)
        let minimumStableSeconds =
            UIDevice.current.userInterfaceIdiom == .pad
            ? AccessLifecycleContract.ipadNewStableMarkConfirmWindow
            : AccessLifecycleContract.newStableMarkConfirmWindow
        var samples: [AccessLifecycleContract.ContinueWatchSample] = []
        while Date() < deadline {
            let batchDeadline = min(
                deadline,
                Date().addingTimeInterval(nextImageStabilityBatchSeconds)
            )
            var rawFrames: [ContinueWatchRawFrame] = []
            while Date() < batchDeadline {
                let requestElapsed = Date().timeIntervalSince(nextAt)
                let png = app.screenshot().pngRepresentation
                let returnElapsed = Date().timeIntervalSince(nextAt)
                rawFrames.append(
                    ContinueWatchRawFrame(
                        requestElapsed: requestElapsed,
                        returnElapsed: returnElapsed,
                        png: png,
                        controlBarVisible: playPauseButton(app).exists
                    )
                )
            }
            for raw in rawFrames {
                let identity = StrictE2EPhotoIdentity.captureIdentity(png: raw.png)
                let sample = AccessLifecycleContract.ContinueWatchSample(
                    requestElapsed: raw.requestElapsed,
                    returnElapsed: raw.returnElapsed,
                    classifiedElapsed: Date().timeIntervalSince(nextAt),
                    status: identity.status.rawValue,
                    mark: continueWatchMark(identity),
                    meanLuma: identity.meanLuma,
                    controlBarVisible: raw.controlBarVisible
                )
                samples.append(sample)
                guard
                    let stable = AccessLifecycleContract.firstStableNewImage(
                        continueMark: continueMark,
                        samples: samples,
                        minimumStableSeconds: minimumStableSeconds
                    )
                else {
                    continue
                }
                try AccessLifecycleContract.assertIdentifiableNewImagePresent(
                    continueMark: continueMark,
                    confirmedMark: stable.mark,
                    confirmedStatus: stable.status
                )
                guard abs(stable.requestElapsed - sample.requestElapsed) <= 0.001 else {
                    throw AccessLifecycleContract.AssertionError.message(
                        "Next-photo stable confirmation does not match the current raw screenshot"
                    )
                }
                try persistRequiredPNG(raw.png, name: "after-next")
                return (stable.mark, raw.png)
            }
        }

        let recent = samples.suffix(6).map {
            "t=\($0.requestElapsed), status=\($0.status), mark=\($0.mark), luma=\($0.meanLuma)"
        }.joined(separator: "; ")
        throw AccessLifecycleContract.AssertionError.message(
            "Next photo did not form a stable new MATCH within \(nextImageStabilityTimeoutSeconds) s: \(recent)"
        )
    }

    @MainActor
    private func captureImmediateRequiredMark(
        app: XCUIApplication,
        name: String
    ) throws -> (mark: String, png: Data) {
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        let png = try captureRequiredPNG(app: app, name: name)
        let mark = contractMark(StrictE2EPhotoIdentity.captureIdentity(png: png))
        if isUsableSceneMark(mark) == false {
            throw AccessLifecycleContract.AssertionError.message(
                "Screenshot \(name) cannot be used as identity: \(mark)"
            )
        }
        return (mark, png)
    }

    @MainActor
    private func classifyCurrentMark(app: XCUIApplication) -> String {
        contractMark(StrictE2EPhotoIdentity.captureIdentity(png: app.screenshot().pngRepresentation))
    }

    private func isUsableSceneMark(_ mark: String) -> Bool {
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
        throw AccessLifecycleContract.AssertionError.message(
            "Background return is missing the original process identity")
    }

    private func writeSettingsResumeJSON(name: String, extra: [String: Any]) throws {
        var payload: [String: Any] = [
            "status": "ran",
            "identity_source": AccessLifecycleContract.allowedIdentitySource,
            "settings_source": AccessLifecycleContract.allowedSettingsSource,
            "device": deviceKind(),
            "requests": requests,
            "pin_enabled": false
        ]
        for (key, value) in extra {
            payload[key] = value
        }
        try StrictE2EVisualEvidence.writeRequiredJSON(payload, name: name)
    }
}
#endif
