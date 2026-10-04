import XCTest

#if os(iOS)
final class PlaybackHistoryIOSUITests: XCTestCase {
    private var manualLifecycleRuntimeEvidenceRows: [[String: Any]] = []

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
        defer { app.terminate() }
        startFilteredPlaybackFromModeSelection(app: app)
        _ = try waitForFrameSynchronizedPresentationProbe(app: app, timeout: 45)

        let playPause = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(waitUntil(timeout: 4) { self.playPauseState(playPause) == "pause" })
        tapElement(playPause)
        XCTAssertTrue(waitUntil(timeout: 3) { self.playPauseState(playPause) == "play" })

        let initialProbe = try waitForPausedFrameSynchronizedPresentationProbe(app: app, timeout: 3)
        let initialSlots = frozenStateOfSmartFillSlots(app: app)
        XCTAssertFalse(
            initialSlots.isEmpty,
            "The pause diagnostic must read the rendered frame/transform probe of every SmartFill slot")
        let initialPixels = app.windows.firstMatch.screenshot().pngRepresentation
        appendManualLifecycleRuntimeEvidence(
            app: app, mode: .smartFill, event: "ipad-pause-only-start", probe: initialProbe)
        let initialPixelsAttachment = XCTAttachment(data: initialPixels, uniformTypeIdentifier: "public.png")
        initialPixelsAttachment.name = "ipad-smartfill-pause-only-start"
        initialPixelsAttachment.lifetime = .keepAlways
        add(initialPixelsAttachment)

        for sample in 1...4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.75))
            let probe = try waitForPausedFrameSynchronizedPresentationProbe(app: app, timeout: 2)
            let slots = frozenStateOfSmartFillSlots(app: app)
            let pixels = app.windows.firstMatch.screenshot().pngRepresentation
            let failureFrame = XCTAttachment(data: pixels, uniformTypeIdentifier: "public.png")
            failureFrame.name = "Desktop-pause-before-assert-\(sample)"
            failureFrame.lifetime = .keepAlways
            add(failureFrame)
            XCTAssertEqual(probe.phase, initialProbe.phase, "The scene phase must not change while paused")
            XCTAssertEqual(probe.opacities, initialProbe.opacities, "Layer opacities must not change while paused")
            XCTAssertEqual(
                probe.rawProgress, initialProbe.rawProgress,
                "After pausing, the frame-synchronized motionRawProgress must stay frozen")
            XCTAssertEqual(
                slots, initialSlots,
                "After pausing, the rendered transform/frame of every SmartFill slot must stay frozen")
            XCTAssertEqual(pixels, initialPixels, "After pausing, consecutive rendered pixels must stay frozen")
            appendManualLifecycleRuntimeEvidence(
                app: app, mode: .smartFill, event: "ipad-pause-only-sample-\(sample)", probe: probe)
            let pixelsAttachment = XCTAttachment(data: pixels, uniformTypeIdentifier: "public.png")
            pixelsAttachment.name = "ipad-smartfill-pause-only-sample-\(sample)"
            pixelsAttachment.lifetime = .keepAlways
            add(pixelsAttachment)
        }
    }

    @MainActor
    func testDiagnosticSmartFillSettingsPauseOnlyThreeSecondsFreezesRenderedFrames() throws {
        let app = try launchConfiguredManualLifecycleAppAtModeSelection(mode: .smartFill)
        defer { app.terminate() }
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
            forceAutoplayOff: true
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

private extension PlaybackHistoryIOSUITests {
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
        forceAutoplayOff: Bool = false
    ) throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        if forceAutoplayOff {
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
                self.presentationProbe(app: app)?.rawProgress.contains(where: { $0 > 0.001 }) == true
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
            staticAfterNext.rawProgress.allSatisfy { abs($0) < 0.000_1 },
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
            staticAfterPrevious.rawProgress.allSatisfy { abs($0) < 0.000_1 },
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
                self.presentationProbe(app: app)?.rawProgress.contains(where: { $0 > 0.001 }) == true
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
            afterFiveSeconds.rawProgress.contains(where: { $0 > 0.001 }),
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

    func attachManualLifecycleRuntimeEvidence(mode: ManualLifecycleMode) {
        guard !manualLifecycleRuntimeEvidenceRows.isEmpty,
            JSONSerialization.isValidJSONObject(manualLifecycleRuntimeEvidenceRows),
            let data = try? JSONSerialization.data(
                withJSONObject: manualLifecycleRuntimeEvidenceRows,
                options: [.prettyPrinted, .sortedKeys]
            )
        else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "manual-lifecycle-\(mode == .smartFill ? "smartfill" : "single-photo")-runtime-sequence"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func currentSceneIdentity(app: XCUIApplication, mode: ManualLifecycleMode) -> String? {
        if mode == .smartFill {
            return currentCompleteVisibleSmartFillScene(app: app)?.sceneIdentity
        }
        return currentAssetID(app: app)
    }

    func announceManualLifecycleCaptureWindowIfRequested(mode: ManualLifecycleMode, kind: String) {
        guard let path = ProcessInfo.processInfo.environment["TEST_RUNNER_MANUAL_LIFECYCLE_CAPTURE_READY_FILE"],
            !path.isEmpty
        else {
            emitManualLifecycleCaptureStatus(mode: mode, kind: kind, markerStatus: "not-configured")
            return
        }
        let payload: [String: Any] = [
            "mode": mode == .smartFill ? "smartFill" : "singlePhoto",
            "kind": kind,
            "readyAt": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            emitManualLifecycleCaptureStatus(mode: mode, kind: kind, markerStatus: "encode-failed")
            return
        }
        let markerStatus: String
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            markerStatus = "written"
        } catch {
            markerStatus = "write-failed"
        }
        emitManualLifecycleCaptureStatus(mode: mode, kind: kind, markerStatus: markerStatus)
        // External recording must wait for a visible stable scene; only the test capture path keeps this sync window.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    func emitManualLifecycleCaptureStatus(mode: ManualLifecycleMode, kind: String, markerStatus: String) {
        let modeName = mode == .smartFill ? "smartFill" : "singlePhoto"
        let line = "MANUAL_LIFECYCLE_CAPTURE_READY mode=\(modeName) kind=\(kind) marker=\(markerStatus)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    func openPlaybackSettingsFromSlideshow(app: XCUIApplication) {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(waitUntil(timeout: 8) { settingsButton.exists && settingsButton.isHittable })
        tapElement(settingsButton)

        let playbackEntry: XCUIElement
        if UIDevice.current.userInterfaceIdiom == .pad {
            if app.switches["settings.playback.autoPlay.toggle"].waitForExistence(timeout: 2) { return }
            let sidebar = app.buttons["ToggleSidebar"]
            if sidebar.exists && ["显示边栏", "Show Sidebar"].contains(sidebar.label) {
                tapElement(sidebar)
            }
            playbackEntry = app.descendants(matching: .any)["settings.item.playback"].firstMatch
        } else {
            playbackEntry = app.buttons["settings.item.playback"]
        }
        XCTAssertTrue(
            playbackEntry.waitForExistence(timeout: 8), "The settings list must provide the Playback Settings entry")
        tapElement(playbackEntry)
    }

    func requireAutoPlayToggle(app: XCUIApplication) throws -> XCUIElement {
        let toggle = app.switches["settings.playback.autoPlay.toggle"]
        guard toggle.waitForExistence(timeout: 8) else {
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "missing settings.playback.autoPlay.toggle"]
            )
        }
        return toggle
    }

    func returnToSlideshowFromPlaybackSettings(app: XCUIApplication) {
        for _ in 0..<6 {
            let settingsButton = app.buttons["slideshow.control.settings.button"]
            if settingsButton.exists && settingsButton.isHittable { return }

            let globalBack = app.buttons["global.back.button"]
            if globalBack.exists && globalBack.isHittable {
                tapElement(globalBack)
                continue
            }
            let backButton =
                app.navigationBars.buttons.allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable && $0.identifier == "BackButton" }
                .last
                ?? app.navigationBars.buttons.allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable && $0.identifier != "ToggleSidebar" }
                .first
            if let backButton {
                backButton.tap()
            } else {
                app.tap()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(
            waitUntil(timeout: 6) {
                let settingsButton = app.buttons["slideshow.control.settings.button"]
                return settingsButton.exists && settingsButton.isHittable
            },
            "Could not return from the playback settings page to the slideshow"
        )
    }

    func playPauseState(_ button: XCUIElement) -> String {
        ((button.value as? String) ?? "").lowercased()
    }

    func isToggleOn(_ toggle: XCUIElement) -> Bool {
        let value = ((toggle.value as? String) ?? "").lowercased()
        return value == "1" || value == "true"
    }

    func waitForPresentationProbe(app: XCUIApplication, timeout: TimeInterval) throws -> ScenePresentationProbe {
        guard waitUntil(timeout: timeout, condition: { self.presentationProbe(app: app) != nil }),
            let probe = presentationProbe(app: app)
        else {
            let hierarchy = app.debugDescription
            print("MANUAL_LIFECYCLE_PROBE_HIERARCHY_BEGIN\n\(hierarchy)\nMANUAL_LIFECYCLE_PROBE_HIERARCHY_END")
            let attachment = XCTAttachment(data: Data(hierarchy.utf8), uniformTypeIdentifier: "public.plain-text")
            attachment.name = "manual-lifecycle-missing-contract-probe-hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            throw NSError(
                domain: "PlaybackHistoryIOSUITests", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "missing presentation contract probe"])
        }
        return probe
    }

    func waitForStablePresentationProbe(app: XCUIApplication, timeout: TimeInterval) throws -> ScenePresentationProbe {
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard let probe = self.presentationProbe(app: app) else { return false }
                    return probe.phase == "stablePhoto" && !probe.rawProgress.isEmpty
                }), let probe = presentationProbe(app: app)
        else {
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "scene presentation did not reach stablePhoto"]
            )
        }
        return probe
    }

    func waitForFrameSynchronizedPresentationProbe(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> ScenePresentationProbe {
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard let probe = self.frameSynchronizedPresentationProbe(app: app) else { return false }
                    return probe.phase == "stablePhoto" && !probe.rawProgress.isEmpty
                }), let probe = frameSynchronizedPresentationProbe(app: app)
        else {
            let frameProbe = app.descendants(matching: .any)["slideshow.scenePresentation.frameSynchronized.summary"]
            let contractProbe = app.descendants(matching: .any)["slideshow.scenePresentation.contract.summary"]
            let diagnostic = [
                "frameProbe.exists=\(frameProbe.exists)",
                "frameProbe.label=\(frameProbe.label)",
                "contractProbe.exists=\(contractProbe.exists)",
                "contractProbe.label=\(contractProbe.label)",
                "MANUAL_LIFECYCLE_FRAME_SYNCHRONIZED_HIERARCHY_BEGIN",
                app.debugDescription,
                "MANUAL_LIFECYCLE_FRAME_SYNCHRONIZED_HIERARCHY_END"
            ].joined(separator: "\n")
            print(diagnostic)
            let attachment = XCTAttachment(data: Data(diagnostic.utf8), uniformTypeIdentifier: "public.plain-text")
            attachment.name = "manual-lifecycle-frame-synchronized-probe-diagnostic"
            attachment.lifetime = .keepAlways
            add(attachment)
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "missing frame-synchronized scene presentation probe"]
            )
        }
        return probe
    }

    // A pause can land mid-transition, and the reducer then freezes each layer's fade (ScenePresentationReducerTests),
    // so the freeze checks accept a paused transition as well as a stable scene. At least one photo layer must show.
    func waitForPausedFrameSynchronizedPresentationProbe(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> ScenePresentationProbe {
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard let probe = self.frameSynchronizedPresentationProbe(app: app) else { return false }
                    return ["stablePhoto", "transition"].contains(probe.phase) && !probe.rawProgress.isEmpty
                        && probe.opacities.contains { $0 > 0 }
                }), let probe = frameSynchronizedPresentationProbe(app: app)
        else {
            let label = app.descendants(matching: .any)["slideshow.scenePresentation.frameSynchronized.summary"]
            let observed = label.exists ? label.label : "missing"
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "paused scene is not a visible photo scene: \(observed)"]
            )
        }
        return probe
    }

    func presentationProbe(app: XCUIApplication) -> ScenePresentationProbe? {
        scenePresentationProbe(identifier: "slideshow.scenePresentation.contract.summary", app: app)
    }

    func frameSynchronizedPresentationProbe(app: XCUIApplication) -> ScenePresentationProbe? {
        scenePresentationProbe(identifier: "slideshow.scenePresentation.frameSynchronized.summary", app: app)
    }

    func scenePresentationProbe(identifier: String, app: XCUIApplication) -> ScenePresentationProbe? {
        let element = app.descendants(matching: .any)[identifier]
        guard element.exists else { return nil }
        let fields = SharedSceneEvidenceManifest.parseKeyValueFields(element.label)
        func numbers(_ key: String) -> [Double] {
            (fields[key] ?? "").split(separator: "|").compactMap { Double($0) }
        }
        // phase=empty is real evidence of empty input; do not disguise it as a missing probe.

        guard let phase = fields["phase"] else { return nil }
        return ScenePresentationProbe(
            phase: phase,
            rawProgress: numbers("motionRawProgress"),
            opacities: numbers("layerOpacities")
        )
    }

    // These fields are the render's clock (`systemUptime` when SwiftUI evaluated the view) and times derived
    // from it, so any re-render of a paused scene moves them. The paused motion clock stays under test through
    // `progress`, `stableVisibleDuration` and `transitionCompletionDelay`.
    static let renderTimeAnchoredSlotProbeFields: Set<String> = [
        "presentationSampleTime", "timelineStartTime", "stableVisibleStartTime",
        "handoffStartDeadlineTime", "removalDeadlineTime"
    ]

    func frozenStateOfSmartFillSlots(app: XCUIApplication) -> [String] {
        smartFillRenderedSlotProbeLabels(app: app).map { probe in
            probe.split(separator: ";", omittingEmptySubsequences: false)
                .filter { field in
                    let key = field.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                    return !Self.renderTimeAnchoredSlotProbeFields.contains(key)
                }
                .joined(separator: ";")
        }
    }

    func smartFillRenderedSlotProbeLabels(app: XCUIApplication) -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "slideshow.smartfill.motionFrame."))
            .allElementsBoundByIndex
            .map { $0.identifier + "=" + $0.label }
            .sorted()
    }

    func assertSmartFillPauseOnlyFrameFreeze(
        app: XCUIApplication,
        evidenceEventPrefix: String
    ) throws {
        let initialProbe = try waitForPausedFrameSynchronizedPresentationProbe(app: app, timeout: 3)
        let initialSlots = frozenStateOfSmartFillSlots(app: app)
        XCTAssertFalse(
            initialSlots.isEmpty,
            "The pause diagnostic must read the rendered frame/transform probe of every SmartFill slot")
        let initialPixels = app.windows.firstMatch.screenshot().pngRepresentation
        appendManualLifecycleRuntimeEvidence(
            app: app, mode: .smartFill, event: "\(evidenceEventPrefix)-start", probe: initialProbe)
        let initialPixelsAttachment = XCTAttachment(data: initialPixels, uniformTypeIdentifier: "public.png")
        initialPixelsAttachment.name = "\(evidenceEventPrefix)-start"
        initialPixelsAttachment.lifetime = .keepAlways
        add(initialPixelsAttachment)

        for sample in 1...4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.75))
            let probe = try waitForPausedFrameSynchronizedPresentationProbe(app: app, timeout: 2)
            let slots = frozenStateOfSmartFillSlots(app: app)
            let pixels = app.windows.firstMatch.screenshot().pngRepresentation
            let frame = XCTAttachment(data: pixels, uniformTypeIdentifier: "public.png")
            frame.name = "Desktop-settings-pause-before-assert-\(sample)"
            frame.lifetime = .keepAlways
            add(frame)
            XCTAssertEqual(probe.phase, initialProbe.phase, "The scene phase must not change while paused")
            XCTAssertEqual(probe.opacities, initialProbe.opacities, "Layer opacities must not change while paused")
            XCTAssertEqual(
                probe.rawProgress, initialProbe.rawProgress,
                "After pausing, the frame-synchronized motionRawProgress must stay frozen")
            XCTAssertEqual(
                slots, initialSlots,
                "After pausing, the rendered transform/frame of every SmartFill slot must stay frozen")
            XCTAssertEqual(pixels, initialPixels, "After pausing, consecutive rendered pixels must stay frozen")
            appendManualLifecycleRuntimeEvidence(
                app: app, mode: .smartFill, event: "\(evidenceEventPrefix)-sample-\(sample)", probe: probe)
            let pixelsAttachment = XCTAttachment(data: pixels, uniformTypeIdentifier: "public.png")
            pixelsAttachment.name = "\(evidenceEventPrefix)-sample-\(sample)"
            pixelsAttachment.lifetime = .keepAlways
            add(pixelsAttachment)
        }
    }

    func sceneIdentity(app: XCUIApplication, mode: ManualLifecycleMode) throws -> String {
        if mode == .smartFill {
            return try waitForCompleteVisibleSmartFillScene(app: app, timeout: 8).sceneIdentity
        }
        return try waitForCurrentAssetID(app: app, timeout: 8)
    }

    func waitForSceneIdentityChange(app: XCUIApplication, mode: ManualLifecycleMode, from oldValue: String) throws
        -> String
    {
        guard
            waitUntil(
                timeout: 20,
                condition: {
                    (try? self.sceneIdentity(app: app, mode: mode)).map { $0 != oldValue } ?? false
                })
        else {
            throw NSError(
                domain: "PlaybackHistoryIOSUITests", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "scene identity did not change"])
        }
        return try sceneIdentity(app: app, mode: mode)
    }

    func startRandomPlaybackFromModeSelection(app: XCUIApplication) {
        let randomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(
            randomButton.waitForExistence(timeout: 5), "The mode selection page should show the Random Playback entry")
        tapElement(randomButton)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 5), "The mode selection page should show the Continue button")
        XCTAssertTrue(
            continueButton.isEnabled, "After choosing Random Playback, the Continue button should be tappable")
        tapElement(continueButton)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 25),
            "After entering random playback, the playback control bar should be shown"
        )
    }

    func startFilteredPlaybackFromModeSelection(app: XCUIApplication) {
        let filteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(
            filteredButton.waitForExistence(timeout: 5),
            "The filtered-playback harness should show the Filtered Playback entry")
        tapElement(filteredButton)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5), "Filtered playback should show the Continue button")
        XCTAssertTrue(
            continueButton.isEnabled, "The Continue button in the filtered-playback harness should be tappable")
        tapElement(continueButton)

        let startButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startButton.waitForExistence(timeout: 12),
            "The filtered playback summary should show the Start Playback button")
        // Starting before the page swaps in the real album and person would play an empty pool.
        let selectionReady = app.staticTexts["filterSummary.visual.ready"]
        XCTAssertTrue(
            waitUntil(timeout: 30) { selectionReady.exists && selectionReady.label == "ready" },
            "The filter summary must select a real album and person before playback starts"
        )
        XCTAssertTrue(waitUntil(timeout: 12) { startButton.isEnabled })
        tapElement(startButton)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 45),
            "The filtered-playback harness should reach the real playback control bar"
        )
    }

    func waitForCurrentAssetID(app: XCUIApplication, timeout: TimeInterval) throws -> String {
        guard waitUntil(timeout: timeout, condition: { self.currentAssetID(app: app) != nil }) else {
            let hierarchy = app.debugDescription
            let candidate = app.descendants(matching: .any)["slideshow.currentAssetId.flag"]
            let diagnostic = [
                "currentAssetProbe.exists=\(candidate.exists)",
                "currentAssetProbe.identifier=\(candidate.identifier)",
                "currentAssetProbe.label=\(candidate.label)",
                "MANUAL_LIFECYCLE_CURRENT_ASSET_HIERARCHY_BEGIN",
                hierarchy,
                "MANUAL_LIFECYCLE_CURRENT_ASSET_HIERARCHY_END"
            ].joined(separator: "\n")
            print(diagnostic)
            let attachment = XCTAttachment(data: Data(diagnostic.utf8), uniformTypeIdentifier: "public.plain-text")
            attachment.name = "manual-lifecycle-current-asset-probe-hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail(
                "The slideshow must reliably expose slideshow.currentAssetId.flag in UI tests, EXIF panel or not."
            )
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "missing slideshow.currentAssetId.flag"
                ]
            )
        }

        guard let assetID = currentAssetID(app: app) else {
            XCTFail("The slideshow asset ID probe disappeared; cannot read the current photo.")
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "missing slideshow.currentAssetId.flag after initial detection"
                ]
            )
        }
        return assetID
    }

    func waitForCurrentAssetIDChange(app: XCUIApplication, from oldValue: String, timeout: TimeInterval) throws
        -> String
    {
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard let value = self.currentAssetID(app: app) else { return false }
                    return value != oldValue
                })
        else {
            XCTFail("After tapping next, the current photo ID did not change within \(Int(timeout)) seconds")
            return oldValue
        }

        return try waitForCurrentAssetID(app: app, timeout: 2)
    }

    func currentAssetID(app: XCUIApplication) -> String? {
        let probe = app.descendants(matching: .any)["slideshow.currentAssetId.flag"]
        guard probe.exists else { return nil }
        let label = probe.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty || label == "no-asset" ? nil : label
    }

    func waitForCompleteVisibleSmartFillScene(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> CompleteVisibleSmartFillScene {
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    self.currentCompleteVisibleSmartFillScene(app: app) != nil
                }), let scene = currentCompleteVisibleSmartFillScene(app: app)
        else {
            attachSmartFillProbeLabels(app: app, name: "smartfill-history-missing-complete-visible-probe")
            XCTFail(
                "SmartFill must expose the complete manifest, stable visible render state and history cursor together")
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "missing complete visible SmartFill scene"]
            )
        }
        return scene
    }

    func waitForCompleteVisibleSmartFillSceneChange(
        app: XCUIApplication,
        from previousIdentity: String,
        timeout: TimeInterval
    ) throws -> CompleteVisibleSmartFillScene {
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard let scene = self.currentCompleteVisibleSmartFillScene(app: app) else { return false }
                    return scene.sceneIdentity != previousIdentity
                })
        else {
            attachSmartFillProbeLabels(app: app, name: "smartfill-history-next-identity-unchanged-probe")
            XCTFail(
                "After tapping next, the fully visible SmartFill scene identity did not change in \(Int(timeout)) s")
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "complete visible SmartFill scene did not change"]
            )
        }
        return try waitForCompleteVisibleSmartFillScene(app: app, timeout: 2)
    }

    func currentCompleteVisibleSmartFillScene(app: XCUIApplication) -> CompleteVisibleSmartFillScene? {
        let manifestProbe = app.descendants(matching: .any)["slideshow.smartfill.currentManifest.flag"]
        let contractProbe = app.descendants(matching: .any)["slideshow.scenePresentation.contract.summary"]
        let historyProbe = app.descendants(matching: .any)["slideshow.historyLedger.summary.flag"]
        guard manifestProbe.exists,
            contractProbe.exists,
            historyProbe.exists
        else {
            return nil
        }

        let manifestFields = SharedSceneEvidenceManifest.parseKeyValueFields(manifestProbe.label)
        let contractFields = SharedSceneEvidenceManifest.parseKeyValueFields(contractProbe.label)
        guard
            SharedSceneEvidenceManifest.manifestObservation(from: manifestProbe.label)?.isCompleteVisibleScene == true,
            contractFields["phase"] == "stablePhoto",
            contractFields["layerRoles"] == "stable",
            contractFields["loadingVisible"] == "false",
            let sceneIdentity = manifestFields["ledgerSceneAssets"],
            sceneIdentity != "none",
            !sceneIdentity.isEmpty,
            let historyData = historyProbe.label.data(using: .utf8),
            let history = try? JSONSerialization.jsonObject(with: historyData) as? [String: Any],
            let cursor = history["cursor"] as? Int
        else {
            return nil
        }
        return CompleteVisibleSmartFillScene(sceneIdentity: sceneIdentity, historyCursor: cursor)
    }

    func attachSmartFillProbeLabels(app: XCUIApplication, name: String) {
        let identifiers = [
            "slideshow.smartfill.currentManifest.flag",
            "slideshow.scenePresentation.contract.summary",
            "slideshow.historyLedger.summary.flag"
        ]
        let labels = identifiers.map { identifier in
            let probe = app.descendants(matching: .any)[identifier]
            return "[\(identifier)] exists=\(probe.exists)\\n\(probe.label)"
        }.joined(separator: "\\n\\n")
        let attachment = XCTAttachment(data: Data(labels.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name)-screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
            return
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    func currentDeviceTag() -> String {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return "iphone"
        case .pad:
            return "ipad"
        default:
            return UIDevice.current.model.replacingOccurrences(of: " ", with: "_").lowercased()
        }
    }
}
#endif
