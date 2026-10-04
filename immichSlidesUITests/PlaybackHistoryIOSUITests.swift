import XCTest

enum PlaybackHistoryIOSUITestsCalibration {
    static let pauseSampleCount: Int = 4
    static let pauseSampleIntervalSeconds: TimeInterval = 0.75
    static let observableMotionProgress: Double = 0.001
    static let zeroProgressTolerance: Double = 0.000_1
}

#if os(iOS)
final class PlaybackHistoryIOSUITests: XCTestCase {
    var manualLifecycleRuntimeEvidenceRows: [[String: Any]] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        manualLifecycleRuntimeEvidenceRows = []
    }

    @MainActor
    func testPreviousNextRetainedHistoryFromRandomPlayback() throws {
        let app = try launchConfiguredAppAtModeSelection()
        defer { app.terminate() }
        startRandomPlaybackFromModeSelection(app: app)

        let initialAssetID = try waitForCurrentAssetID(app: app, timeout: 20)
        attachScreenshot(app: app, name: "history-01-initial-\(currentDeviceTag())")

        tapElement(app.buttons["slideshow.control.next.button"])
        let secondAssetID = try waitForCurrentAssetIDChange(app: app, from: initialAssetID, timeout: 20)
        attachScreenshot(app: app, name: "history-02-after-next-\(currentDeviceTag())")

        tapElement(app.buttons["slideshow.control.next.button"])
        let thirdAssetID = try waitForCurrentAssetIDChange(app: app, from: secondAssetID, timeout: 20)
        XCTAssertNotEqual(thirdAssetID, initialAssetID, "Two nexts in a row should reach a new playback scene")
        attachScreenshot(app: app, name: "history-03-after-second-next-\(currentDeviceTag())")

        tapElement(app.buttons["slideshow.control.previous.button"])
        XCTAssertTrue(
            waitUntil(timeout: 20) { self.currentAssetID(app: app) == secondAssetID },
            "The first previous should return to the previous photo, not pick a new random one"
        )
        attachScreenshot(app: app, name: "history-04-after-previous-to-second-\(currentDeviceTag())")

        tapElement(app.buttons["slideshow.control.previous.button"])
        XCTAssertTrue(
            waitUntil(timeout: 20) { self.currentAssetID(app: app) == initialAssetID },
            "The second previous should keep following the retained history back to the first photo"
        )
        attachScreenshot(app: app, name: "history-05-after-previous-to-initial-\(currentDeviceTag())")
    }

    @MainActor
    func testSmartFillPreviousNextRoundTripUsesCompleteVisibleSceneIdentity() throws {
        let app = try launchConfiguredSmartFillAppAtModeSelection()
        defer { app.terminate() }
        startFilteredPlaybackFromModeSelection(app: app)

        let initial = try waitForCompleteVisibleSmartFillScene(app: app, timeout: 45)
        attachScreenshot(app: app, name: "smartfill-history-01-initial")

        tapElement(app.buttons["slideshow.control.next.button"])
        let second = try waitForCompleteVisibleSmartFillSceneChange(
            app: app,
            from: initial.sceneIdentity,
            timeout: 20
        )
        XCTAssertGreaterThan(second.historyCursor, initial.historyCursor)
        attachScreenshot(app: app, name: "smartfill-history-02-after-next")

        tapElement(app.buttons["slideshow.control.next.button"])
        let third = try waitForCompleteVisibleSmartFillSceneChange(
            app: app,
            from: second.sceneIdentity,
            timeout: 20
        )
        XCTAssertNotEqual(third.sceneIdentity, initial.sceneIdentity)
        XCTAssertGreaterThan(third.historyCursor, second.historyCursor)
        attachScreenshot(app: app, name: "smartfill-history-03-after-second-next")

        tapElement(app.buttons["slideshow.control.previous.button"])
        XCTAssertTrue(
            waitUntil(timeout: 20) {
                self.currentCompleteVisibleSmartFillScene(app: app)?.sceneIdentity == second.sceneIdentity
            },
            "SmartFill previous must return to the previous fully visible scene, not just move the internal cursor"
        )
        let returnedSecond = try waitForCompleteVisibleSmartFillScene(app: app, timeout: 2)
        XCTAssertEqual(returnedSecond.historyCursor, second.historyCursor)
        attachScreenshot(app: app, name: "smartfill-history-04-after-previous-to-second")

        tapElement(app.buttons["slideshow.control.previous.button"])
        XCTAssertTrue(
            waitUntil(timeout: 20) {
                self.currentCompleteVisibleSmartFillScene(app: app)?.sceneIdentity == initial.sceneIdentity
            },
            "The second SmartFill previous must follow the retained history back to the first fully visible scene"
        )
        let returnedInitial = try waitForCompleteVisibleSmartFillScene(app: app, timeout: 2)
        XCTAssertEqual(returnedInitial.historyCursor, initial.historyCursor)
        attachScreenshot(app: app, name: "smartfill-history-05-after-previous-to-initial")
    }

    @MainActor
    func testManualLifecycleSmartFillPauseNavigatePreviousAndResumeCurrentScene() throws {
        try runManualLifecycleContract(mode: .smartFill)
    }

    @MainActor
    func testManualLifecycleSinglePhotoPauseNavigatePreviousAndResumeCurrentScene() throws {
        try runManualLifecycleContract(mode: .singlePhoto)
    }

    @MainActor
    func testManualLifecycleSettingsAndControlsStayBidirectionallySynchronized() throws {
        let app = try launchConfiguredManualLifecycleAppAtModeSelection(mode: .singlePhoto)
        defer { app.terminate() }
        startFilteredPlaybackFromModeSelection(app: app)
        _ = try waitForStablePresentationProbe(app: app, timeout: 45)

        let playPause = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 8), "The slideshow must show the Play/Pause control")
        XCTAssertTrue(waitUntil(timeout: 4) { self.playPauseState(playPause) == "pause" })

        // Pausing from the control bar must write the same autoPlayEnabled that the settings page uses.
        tapElement(playPause)
        XCTAssertTrue(waitUntil(timeout: 3) { self.playPauseState(playPause) == "play" })
        openPlaybackSettingsFromSlideshow(app: app)
        let autoPlayToggle = try requireAutoPlayToggle(app: app)
        XCTAssertTrue(
            waitUntil(timeout: 3) { !self.isToggleOn(autoPlayToggle) },
            "After pausing from the control bar, the settings Autoplay toggle must turn off immediately")
        attachScreenshot(app: app, name: "manual-lifecycle-settings-after-control-pause")

        // Turning Autoplay back on in settings must sync to the control bar at once, not wait for the next photo.
        tapElement(autoPlayToggle)
        XCTAssertTrue(
            waitUntil(timeout: 3) { self.isToggleOn(autoPlayToggle) },
            "The settings Autoplay toggle must be able to turn back on")
        attachScreenshot(app: app, name: "manual-lifecycle-settings-after-slider-play")
        returnToSlideshowFromPlaybackSettings(app: app)
        XCTAssertTrue(
            waitUntil(timeout: 4) { self.playPauseState(playPause) == "pause" },
            "After Autoplay is turned on in settings, the control bar must show Pause immediately")
        attachScreenshot(app: app, name: "manual-lifecycle-control-after-slider-play")
    }

    @MainActor
    func testManualLifecycleSinglePhotoNormalAutoplayFiveSeconds() throws {
        try runNormalAutoplayFiveSecondContract(mode: .singlePhoto)
    }

    @MainActor
    func testManualLifecycleSmartFillNormalAutoplayFiveSeconds() throws {
        try runNormalAutoplayFiveSecondContract(mode: .smartFill)
    }

    @MainActor
    func testDiagnosticSmartFillPauseOnlyThreeSecondsFreezesRenderedFrames() throws {
        let app = try launchConfiguredManualLifecycleAppAtModeSelection(mode: .smartFill)
        defer {
            attachManualLifecycleRuntimeEvidence(mode: .smartFill)
            app.terminate()
        }
        startFilteredPlaybackFromModeSelection(app: app)
        _ = try waitForFrameSynchronizedPresentationProbe(app: app, timeout: 45)

        let playPause = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(waitUntil(timeout: 4) { self.playPauseState(playPause) == "pause" })
        tapElement(playPause)
        XCTAssertTrue(waitUntil(timeout: 3) { self.playPauseState(playPause) == "play" })

        try assertSmartFillPauseOnlyFrameFreeze(app: app, evidenceEventPrefix: "ipad-pause-only")
    }

    @MainActor
    func testDiagnosticSmartFillSettingsPauseOnlyThreeSecondsFreezesRenderedFrames() throws {
        let app = try launchConfiguredManualLifecycleAppAtModeSelection(mode: .smartFill)
        defer {
            attachManualLifecycleRuntimeEvidence(mode: .smartFill)
            app.terminate()
        }
        startFilteredPlaybackFromModeSelection(app: app)
        _ = try waitForFrameSynchronizedPresentationProbe(app: app, timeout: 45)

        openPlaybackSettingsFromSlideshow(app: app)
        let autoPlayToggle = try requireAutoPlayToggle(app: app)
        XCTAssertTrue(isToggleOn(autoPlayToggle), "Autoplay should be on when the settings page opens")
        tapElement(autoPlayToggle)
        XCTAssertTrue(
            waitUntil(timeout: 3) { !self.isToggleOn(autoPlayToggle) },
            "Turning off Autoplay in settings must take effect immediately")
        returnToSlideshowFromPlaybackSettings(app: app)

        let playPause = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            waitUntil(timeout: 3) { self.playPauseState(playPause) == "play" },
            "Pausing in settings must sync to the control bar immediately")
        try assertSmartFillPauseOnlyFrameFreeze(app: app, evidenceEventPrefix: "ipad-settings-pause-only")
    }

    @MainActor
    func testDiagnosticSmartFillInitiallyPausedThreeSecondsFreezesRenderedFrames() throws {
        let app = try launchConfiguredManualLifecycleAppAtModeSelection(
            mode: .smartFill,
            shouldForceAutoplayOff: true
        )
        defer {
            attachManualLifecycleRuntimeEvidence(mode: .smartFill)
            app.terminate()
        }
        startFilteredPlaybackFromModeSelection(app: app)

        let playPause = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            waitUntil(timeout: 8) { self.playPauseState(playPause) == "play" },
            "With Autoplay turned off at launch, the first SmartFill scene must stay paused"
        )
        try assertSmartFillPauseOnlyFrameFreeze(app: app, evidenceEventPrefix: "ipad-initially-paused")
    }
}

extension PlaybackHistoryIOSUITests {
    enum ManualLifecycleMode {
        case smartFill
        case singlePhoto
    }

    struct ScenePresentationProbe {
        let phase: String
        let rawProgress: [Double]
        let opacities: [Double]
    }
    struct CompleteVisibleSmartFillScene {
        let sceneIdentity: String
        let historyCursor: Int
    }

    func launchConfiguredAppAtModeSelection() throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launchEnvironment["IMMICHSLIDES_DEBUG_PLAYBACK_SEQUENCE"] = "1"
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        app.launch()

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForExistence(timeout: 10),
            "After the test server is injected, the app should go straight to mode selection"
        )
        return app
    }

    func launchConfiguredSmartFillAppAtModeSelection() throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        // The filter summary picks the first album and person on the server; a replay list replaces that pool.
        try requireServerAlbumAndPerson()
        app.launchEnvironment["UI_TEST_PREPARE_FILTER_SUMMARY_VISUAL_SELECTIONS"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_PLAYBACK_DISPLAY_MODE"] = "smartFill"
        app.launchEnvironment["UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE"] = "1"
        app.launchEnvironment["IMMICHSLIDES_PLAYBACK_CPU_DIAGNOSTICS"] = "1"
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        for key in [
            "IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS_PATH",
            "IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS"
        ] {
            if let value = ProcessInfo.processInfo.environment[key]
                ?? ProcessInfo.processInfo.environment["TEST_RUNNER_\(key)"]
            {
                app.launchEnvironment[key] = value
            }
        }
        app.launch()

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForExistence(timeout: 10),
            "After the fixed SmartFill harness injects the test server, the app should go straight to mode selection"
        )
        return app
    }

    func launchConfiguredManualLifecycleAppAtModeSelection(
        mode: ManualLifecycleMode,
        shouldForceAutoplayOff: Bool = false
    ) throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        if shouldForceAutoplayOff {
            app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        }
        // The filter summary picks the first album and person on the server; a replay list replaces that pool.
        try requireServerAlbumAndPerson()
        app.launchEnvironment["UI_TEST_PREPARE_FILTER_SUMMARY_VISUAL_SELECTIONS"] = "1"
        app.launchEnvironment["UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE"] = "1"
        // SmartFill history reads the existing root-level probe.
        // Only the runtime gate is enabled; product history is not changed.

        app.launchEnvironment["IMMICHSLIDES_PLAYBACK_CPU_DIAGNOSTICS"] = "1"
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        for key in [
            "IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS_PATH",
            "IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS"
        ] {
            if let value = ProcessInfo.processInfo.environment[key]
                ?? ProcessInfo.processInfo.environment["TEST_RUNNER_\(key)"]
            {
                app.launchEnvironment[key] = value
            }
        }
        if mode == .smartFill {
            app.launchEnvironment["UI_TEST_FORCE_PLAYBACK_DISPLAY_MODE"] = "smartFill"
        } else {
            app.launchEnvironment["UI_TEST_FORCE_PLAYBACK_DISPLAY_MODE"] = "singlePhoto"
        }
        app.launch()
        XCTAssertTrue(app.buttons["mode.continue.button"].waitForExistence(timeout: 12))
        return app
    }

    func runManualLifecycleContract(mode: ManualLifecycleMode) throws {
        let app = try launchConfiguredManualLifecycleAppAtModeSelection(mode: mode)
        defer {
            attachManualLifecycleRuntimeEvidence(mode: mode)
            app.terminate()
        }
        startFilteredPlaybackFromModeSelection(app: app)

        let initial = try waitForStablePresentationProbe(app: app, timeout: 45)
        appendManualLifecycleRuntimeEvidence(app: app, mode: mode, event: "initial-stable", probe: initial)
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                self.presentationProbe(app: app)?.rawProgress.contains(where: {
                    $0 > PlaybackHistoryIOSUITestsCalibration.observableMotionProgress
                }) == true
            }, "The current autoplay scene must already show observable motion before the pause")
        let movingInitial = try waitForPresentationProbe(app: app, timeout: 3)
        appendManualLifecycleRuntimeEvidence(
            app: app, mode: mode, event: "automatic-motion-observed", probe: movingInitial)

        announceManualLifecycleCaptureWindowIfRequested(mode: mode, kind: "pause-next-previous-resume")

        let playPause = app.buttons["slideshow.control.playPause.button"]
        tapElement(playPause)
        XCTAssertTrue(waitUntil(timeout: 3) { playPause.value as? String == "play" })
        let paused = try waitForPresentationProbe(app: app, timeout: 3)
        appendManualLifecycleRuntimeEvidence(app: app, mode: mode, event: "paused", probe: paused)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let frozen = try waitForPresentationProbe(app: app, timeout: 3)
        XCTAssertEqual(paused.rawProgress, frozen.rawProgress, "Pausing must freeze the current transform progress")
        appendManualLifecycleRuntimeEvidence(app: app, mode: mode, event: "freeze-confirmed", probe: frozen)

        let initialIdentity = try sceneIdentity(app: app, mode: mode)
        tapElement(app.buttons["slideshow.control.next.button"])
        let afterNextIdentity = try waitForSceneIdentityChange(app: app, mode: mode, from: initialIdentity)
        let staticAfterNext = try waitForStablePresentationProbe(app: app, timeout: 4)
        XCTAssertTrue(
            staticAfterNext.rawProgress.allSatisfy {
                abs($0) < PlaybackHistoryIOSUITestsCalibration.zeroProgressTolerance
            },
            "The new scene from a manual next while paused must stay still at p=0")
        appendManualLifecycleRuntimeEvidence(
            app: app,
            mode: mode,
            event: "manual-next-static-origin",
            probe: staticAfterNext,
            identity: afterNextIdentity
        )

        tapElement(app.buttons["slideshow.control.previous.button"])
        let afterPreviousIdentity = try waitForSceneIdentityChange(app: app, mode: mode, from: afterNextIdentity)
        let staticAfterPrevious = try waitForStablePresentationProbe(app: app, timeout: 4)
        XCTAssertTrue(
            staticAfterPrevious.rawProgress.allSatisfy {
                abs($0) < PlaybackHistoryIOSUITestsCalibration.zeroProgressTolerance
            },
            "The scene from a manual previous while paused must stay still at p=0")
        appendManualLifecycleRuntimeEvidence(
            app: app,
            mode: mode,
            event: "manual-previous-static-origin",
            probe: staticAfterPrevious,
            identity: afterPreviousIdentity
        )

        tapElement(playPause)
        XCTAssertTrue(waitUntil(timeout: 3) { playPause.value as? String == "pause" })
        XCTAssertTrue(
            waitUntil(timeout: 4) {
                self.presentationProbe(app: app)?.rawProgress.contains(where: {
                    $0 > PlaybackHistoryIOSUITestsCalibration.observableMotionProgress
                }) == true
            }, "Play must make the current still scene start moving from p=0 immediately")
        let resumed = try waitForPresentationProbe(app: app, timeout: 3)
        appendManualLifecycleRuntimeEvidence(
            app: app, mode: mode, event: "resumed-current-scene-motion", probe: resumed)
        attachScreenshot(app: app, name: "manual-lifecycle-\(mode == .smartFill ? "smartfill" : "single")-resumed")
    }

    func runNormalAutoplayFiveSecondContract(mode: ManualLifecycleMode) throws {
        let app = try launchConfiguredManualLifecycleAppAtModeSelection(mode: mode)
        defer {
            attachManualLifecycleRuntimeEvidence(mode: mode)
            app.terminate()
        }
        startFilteredPlaybackFromModeSelection(app: app)

        let initial = try waitForFrameSynchronizedPresentationProbe(app: app, timeout: 45)
        appendManualLifecycleRuntimeEvidence(app: app, mode: mode, event: "normal-autoplay-start", probe: initial)
        announceManualLifecycleCaptureWindowIfRequested(mode: mode, kind: "normal-autoplay-five-seconds")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let afterShortWindow = try waitForFrameSynchronizedPresentationProbe(app: app, timeout: 3)
        XCTAssertNotEqual(
            initial.rawProgress,
            afterShortWindow.rawProgress,
            "Autoplay: the stable scene's frame-synced probe must reflect motion progress change in a short window"
        )
        appendManualLifecycleRuntimeEvidence(
            app: app, mode: mode, event: "normal-autoplay-motion-0.8-seconds", probe: afterShortWindow)
        RunLoop.current.run(until: Date().addingTimeInterval(4.2))
        let afterFiveSeconds = try waitForFrameSynchronizedPresentationProbe(app: app, timeout: 5)
        XCTAssertTrue(
            afterFiveSeconds.rawProgress.contains(where: {
                $0 > PlaybackHistoryIOSUITestsCalibration.observableMotionProgress
            }),
            "Normal 5-second autoplay must keep visible motion within the scene"
        )
        appendManualLifecycleRuntimeEvidence(
            app: app, mode: mode, event: "normal-autoplay-five-seconds", probe: afterFiveSeconds)
        attachScreenshot(
            app: app,
            name: "manual-lifecycle-normal-autoplay-\(mode == .smartFill ? "smartfill" : "single")-five-seconds")
    }

    func appendManualLifecycleRuntimeEvidence(
        app: XCUIApplication,
        mode: ManualLifecycleMode,
        event: String,
        probe: ScenePresentationProbe,
        identity: String? = nil
    ) {
        let identity = identity ?? currentSceneIdentity(app: app, mode: mode)
        let record: [String: Any] = [
            "event": event,
            "mode": mode == .smartFill ? "smartFill" : "singlePhoto",
            "phase": probe.phase,
            "motionRawProgress": probe.rawProgress,
            "sceneIdentity": identity ?? "unavailable",
            "playPauseControlState": app.buttons["slideshow.control.playPause.button"].exists
                ? playPauseState(app.buttons["slideshow.control.playPause.button"]) : "notVisible",
            "capturedAt": ISO8601DateFormatter().string(from: Date())
        ]
        manualLifecycleRuntimeEvidenceRows.append(record)
    }
}
#endif
