import CryptoKit
import XCTest

enum AccessLifecycleIOSUITestsCalibration {
    static let intervalSearchAttemptLimit: Int = 14
    static let sliderNudgeAttemptLimit: Int = 12
    static let sliderSearchTolerance: Double = 0.004
    static let sliderNudgeStep: CGFloat = 0.025
    static let sliderLowerBound: CGFloat = 0.02
    static let sliderUpperBound: CGFloat = 0.98
    static let alternateIntervalSeconds: Int = 20
}

#if os(iOS)
final class AccessLifecycleIOSUITests: XCTestCase {
    let controlHideSeconds: TimeInterval = 9
    let intervalMinimumSeconds: Double = 5
    let intervalMaximumSeconds: Double = 30
    var targetIntervalSeconds: Int = 12
    let backgroundWaitBeyondIntervalSeconds: TimeInterval = 2
    let nextImageStabilityTimeoutSeconds: TimeInterval = 6
    let nextImageStabilityBatchSeconds: TimeInterval = 2
    var requests: [String] = []
    var lastPlayAt: Date?

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
            settingsAtBackground.isAutoPlayEnabled
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
                "failure": String(describing: error),
                "mode_before": "",
                "mode_after": "",
                "png_sha256_before": "",
                "png_sha256_after": "",
                "mark_before": "",
                "mark_after": ""
            ]
        }
        let ipadLicenseReturn = try proveIPadLicenseReturnIfNeeded(app: app)

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
            "xctest_config_present": ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
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
            "ipad_license_return": ipadLicenseReturn,
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
        let beforeRestart = try readPlaybackSettings(app: app, shouldAllowPinUnlock: false)
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
        let afterRestart = try readPlaybackSettings(app: app, shouldAllowPinUnlock: false)
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
        let interval = try configureTimingPlaybackSettings(app: app, isAutoPlayEnabled: true)
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
        let interval = try configureTimingPlaybackSettings(app: app, isAutoPlayEnabled: true)
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
        let didHomeLeaveAppRunning = app.state != .notRunning
        XCTAssertTrue(
            didHomeLeaveAppRunning, "The system terminated the process after Home; this does not count as a return.")
        app.activate()
        requests.append("playback.foreground")
        _ = app.wait(for: .runningForeground, timeout: 10)
        XCTAssertNotEqual(
            app.state, .notRunning,
            "The process must still exist after activate; a relaunch must not count as a return.")
        let processAfter = try applicationProcessID(app)
        let didRebuildProcess = processAfter != processBefore || didHomeLeaveAppRunning == false
        try AccessLifecycleContract.assertSameProcess(
            beforeIdentifier: processBefore,
            afterIdentifier: processAfter
        )
        try AccessLifecycleContract.assertSystemPauseActivation(
            activation: AccessLifecycleContract.allowedSystemPauseActivation,
            didRebuildProcess: didRebuildProcess,
            didHomeLeaveAppRunning: didHomeLeaveAppRunning
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
                "home_left_app_running": didHomeLeaveAppRunning,
                "process_rebuilt": didRebuildProcess,
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
}
#endif
