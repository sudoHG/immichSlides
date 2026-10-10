import XCTest

enum AccessLifecycleTVOSUITestsCalibration {
    static let pinDigitCount: Int = 6
}

enum AccessLifecycleTVOSUITestsWaitTiming {
    static let briefElementTimeoutSeconds: TimeInterval = TestWait.seconds(.product(1))
    static let controlAppearanceTimeoutSeconds: TimeInterval = TestWait.seconds(.product(8))
    static let elementAppearanceTimeoutSeconds: TimeInterval = TestWait.seconds(.product(5))
    static let navigationFocusSettleSeconds: TimeInterval = TestWait.seconds(.product(0.22))
    static let navigationTimeoutSeconds: TimeInterval = TestWait.seconds(.product(10))
    static let pinDigitSettleSeconds: TimeInterval = TestWait.seconds(.product(0.07))
    static let playbackControlTimeoutSeconds: TimeInterval = TestWait.seconds(.product(20))
    static let playbackStartupTimeoutSeconds: TimeInterval = TestWait.seconds(.product(30))
    static let pollIntervalSeconds: TimeInterval = TestWait.seconds(.product(0.1))
    static let readbackPollSeconds: TimeInterval = TestWait.seconds(.product(0.2))
    static let readbackTimeoutSeconds: TimeInterval = TestWait.seconds(.product(2))
    static let settingsChangeTimeoutSeconds: TimeInterval = TestWait.seconds(.product(6))
    static let stateChangeTimeoutSeconds: TimeInterval = TestWait.seconds(.product(4))
    static let transitionPollSeconds: TimeInterval = TestWait.seconds(.product(0.4))
}

#if os(tvOS)
final class AccessLifecycleTVOSUITests: XCTestCase {
    enum Timing {
        static let focusSettle: TimeInterval = TestWait.seconds(.product(0.16))
        static let focusPoll: TimeInterval = TestWait.seconds(.product(0.08))
        static let sceneSettle: TimeInterval = TestWait.seconds(.product(2.5))
        static let controlBarHide: TimeInterval = TestWait.seconds(.product(9))
        static let systemPauseHold: TimeInterval = TestWait.seconds(.product(9))
        // Transition-complete can return before the visible frame is stable enough for identity PNG.
        static let sceneStableExtra: TimeInterval = TestWait.seconds(.product(1))
        // In an earlier device run, Up was pressed about 0.56s after Menu, still inside the return transition.
        static let transitionHold: TimeInterval = TestWait.seconds(.product(1.2))
    }

    var requests: [String] = []
    var screenshotOrder: [String] = []
    var settingsReturnWakeSerial = 0
    var didHomeLeaveAppRunning = false
    var didRebuildProcess = false
    var systemPauseActivation = ""

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
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.playbackStartupTimeoutSeconds),
            "Control bar must show after random playback.")
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)

        try changePlaybackSettingsThroughRealUI(app: app)
        try enablePinThroughRealUI(app: app)
        try exercisePinWrongRetryAndCancel(app: app)
        try relaunchAndVerifyPinAndSettings(app: app)
        // The comparison must run before autoplay burns through the random pool. After relaunch autoplay is still
        // off; next lands on a portrait/square scene with blank space, and unshown companions remain after it.
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

    // Only verifies the normal password-protection UI; no system pause, wake or display mode.
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
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.playbackStartupTimeoutSeconds),
            "Control bar must show after random playback.")
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
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.playbackStartupTimeoutSeconds),
            "Control bar must show after random playback.")
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
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.playbackStartupTimeoutSeconds)
                || app.descendants(matching: .any)[AccessLifecycleContract.hiddenControlBarPlaybackIdentifier]
                    .waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After terminate and relaunch, must return to playback, not first boot."
        )
        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.readbackTimeoutSeconds),
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
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.playbackStartupTimeoutSeconds),
            "Control bar must show after random playback.")
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
                "desktop_closeout_required": interval.shouldRequireIntervalReview,
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
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.playbackStartupTimeoutSeconds),
            "Control bar must show after random playback.")
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
            timeout: TestWait.seconds(.product(TimeInterval(interval.actual) + 4))
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
        _ = app.wait(for: .runningForeground, timeout: TestWait.seconds(.infrastructure(10)))
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
            didRebuildProcess: didRebuildProcess,
            didHomeLeaveAppRunning: didHomeLeaveAppRunning
        )
        XCTAssertTrue(
            waitUntilOnSlideShowLayer(app: app, timeout: TestWait.seconds(.product(3))),
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
                "desktop_closeout_required": interval.shouldRequireIntervalReview,
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
}
#endif
