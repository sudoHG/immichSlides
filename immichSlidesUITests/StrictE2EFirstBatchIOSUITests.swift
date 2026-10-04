import XCTest

#if os(iOS)
final class StrictE2EFirstBatchIOSUITests: XCTestCase {
    private let autoplayObservationSeconds: TimeInterval = 6.5
    private let pauseHoldObservationSeconds: TimeInterval = 10.5

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    // Seam: manual entry on a clean install, the mode page, and the playback page after a cold relaunch of the
    // same container. Identity relies only on the in-repository visual identity contract.
    @MainActor
    func testFirstBootSetupSurvivesColdRelaunch() throws {
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "journey-a")
        attachOrientationEvidence(app: app, name: "journey-a-mode-selection")

        try relaunchStrictE2EApp(app)
        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 3),
            "A cold launch with saved settings must not return to the first-boot page."
        )
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 30),
            "A configured cold launch must go straight to the playback page."
        )
        dismissPlaybackEntryHintIfNeeded(app: app)
        attachOrientationEvidence(app: app, name: "journey-a-cold-start-playback")
        recordControlTimeline(app: app, event: "journey-a-cold-start")
    }

    // Seam: where the real mode page leads after first boot, plus random playback control state and
    // step-by-step screenshots.
    @MainActor
    func testRandomModeReachesPlaybackWithCorrectControlState() throws {
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "journey-b")

        chooseOnboardingModeAndContinue(app: app, identifier: "mode.filtered.button")
        waitForFilterSummary(app: app)
        attachOrientationEvidence(app: app, name: "journey-b-filter-summary")
        returnToModeSelectionFromFilterSummary(app: app)

        chooseOnboardingModeAndContinue(app: app, identifier: "mode.random.button")
        XCTAssertTrue(waitForPlaybackControls(app: app, timeout: 30), "Random mode must reach the playback page.")
        dismissPlaybackEntryHintIfNeeded(app: app)
        attachOrientationEvidence(app: app, name: "journey-b-random-playback-start")

        let previous = app.buttons["slideshow.control.previous.button"]
        XCTAssertTrue(previous.waitForExistence(timeout: 8), "The playback page must show the Previous button.")
        XCTAssertFalse(previous.isEnabled, "Previous must be disabled at the history boundary when playback starts.")
        recordControlTimeline(app: app, event: "journey-b-initial-boundary")

        RunLoop.current.run(until: Date().addingTimeInterval(autoplayObservationSeconds))
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 8),
            "After auto-advance, the playback controls must be revealable."
        )
        attachStrictE2EScreenshot(app: app, name: "journey-b-after-autoplay-5s-\(currentDeviceTag())")
        recordControlTimeline(app: app, event: "journey-b-after-autoplay")

        let playPause = app.buttons["slideshow.control.playPause.button"]
        // Screenshots and timeline reads may outlast the control bar's auto-hide delay, so tap the screen to
        // reveal it again before acting.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(playPause.waitForExistence(timeout: 4), "The playback page must show Play/Pause.")
        if playPauseState(playPause) != "play" {
            tapElement(playPause)
        }
        XCTAssertTrue(
            waitUntil(timeout: 4) { self.playPauseState(playPause) == "play" },
            "After pausing, the control value must be play."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(pauseHoldObservationSeconds))
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 8),
            "After pausing, the playback controls must still be revealable."
        )
        attachStrictE2EScreenshot(app: app, name: "journey-b-after-pause-10s-\(currentDeviceTag())")
        XCTAssertEqual(
            playPauseState(playPause),
            "play",
            "After a pause of at least 10 seconds, autoplay must not resume on its own."
        )
        recordControlTimeline(app: app, event: "journey-b-after-pause")

        tapElement(playPause)
        XCTAssertTrue(
            waitUntil(timeout: 4) { self.playPauseState(playPause) == "pause" },
            "Resuming must continue from the current photo, with the control value back to pause."
        )
        tapElement(playPause)
        XCTAssertTrue(
            waitUntil(timeout: 4) { self.playPauseState(playPause) == "play" },
            "Pause again before history actions so the 5-second timer does not interfere."
        )

        let historyStart = captureHistoryIdentity(app: app, step: "history-start")
        tapElement(app.buttons["slideshow.control.next.button"])
        let firstNext = captureHistoryIdentity(app: app, step: "history-first-next")
        tapElement(app.buttons["slideshow.control.next.button"])
        let secondNext = captureHistoryIdentity(app: app, step: "history-second-next")
        XCTAssertTrue(previous.isEnabled, "After two Next taps, Previous must be enabled.")
        tapElement(previous)
        let firstPrevious = captureHistoryIdentity(app: app, step: "history-first-previous")
        tapElement(previous)
        let secondPrevious = captureHistoryIdentity(app: app, step: "history-second-previous")
        recordControlTimeline(app: app, event: "journey-b-history-complete")
        do {
            try StrictE2EPhotoIdentity.assertRoundTrip(
                [historyStart, firstNext, secondNext, firstPrevious, secondPrevious]
            )
        } catch {
            XCTFail(error.localizedDescription)
        }
        let visualIdentity: [String: Any] = [
            "suite": "journey-b",
            "device": currentDeviceTag(),
            "marks": jsonSafeMarks([
                historyStart.mark,
                firstNext.mark,
                secondNext.mark,
                firstPrevious.mark,
                secondPrevious.mark
            ]),
            "steps": [
                StrictE2EPhotoIdentity.payload(historyStart),
                StrictE2EPhotoIdentity.payload(firstNext),
                StrictE2EPhotoIdentity.payload(secondNext),
                StrictE2EPhotoIdentity.payload(firstPrevious),
                StrictE2EPhotoIdentity.payload(secondPrevious)
            ]
        ]
        XCTAssertTrue(
            JSONSerialization.isValidJSONObject(visualIdentity),
            "A nil mark must encode into JSON, without relying on luck with a heterogeneous array."
        )
        StrictE2EVisualEvidence.writeJSON(
            visualIdentity,
            name: "visual-identity.json"
        )
    }

    // Seam: wait for the controls only once after entering random playback. While capturing, reveal the controls
    // only by tapping the center; the probe only records whether the original condition was covered.
    @MainActor
    func testRandomPlaybackPauseStageCapture() throws {
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "pause-stage")
        chooseOnboardingModeAndContinue(
            app: app,
            identifier: "mode.random.button"
        )
        XCTAssertTrue(waitForPlaybackControls(app: app, timeout: 30), "Random mode must reach the playback page.")
        dismissPlaybackEntryHintIfNeeded(app: app)

        RunLoop.current.run(until: Date().addingTimeInterval(autoplayObservationSeconds))

        var stages: [[String: Any]] = []
        stages.append(capturePauseStage(app: app, stage: "before-control-reveal"))

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        _ = waitUntil(timeout: 4) { app.buttons["slideshow.control.playPause.button"].exists }
        stages.append(capturePauseStage(app: app, stage: "after-control-reveal-before-pause"))

        let playPause = app.buttons["slideshow.control.playPause.button"]
        if playPause.exists, playPauseState(playPause) != "play" {
            tapElement(playPause)
        }
        _ = waitUntil(timeout: 4) { playPause.exists && self.playPauseState(playPause) == "play" }
        stages.append(capturePauseStage(app: app, stage: "after-pause-confirmed-play"))

        RunLoop.current.run(until: Date().addingTimeInterval(pauseHoldObservationSeconds))
        stages.append(capturePauseStage(app: app, stage: "after-hold-10s"))

        attachPauseStageTimeline(stages)
    }

    // Seam: hit the single-photo outgoing window with the frame-synchronized probe only. The visual verdict is
    // recorded separately and never identifies the photo by currentAssetId.
    @MainActor
    func testSinglePhotoOutgoingPauseWindowCapture() throws {
        let app = try launchOutgoingPauseWindowApp()
        defer { app.terminate() }

        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(timeout: 20),
            "After injecting the public fixture, the app must reach the mode page."
        )
        chooseOnboardingModeAndContinue(
            app: app,
            identifier: "mode.random.button"
        )
        XCTAssertTrue(waitForPlaybackControls(app: app, timeout: 30), "Random mode must reach the playback page.")
        dismissPlaybackEntryHintIfNeeded(app: app)
        pausePlaybackIfNeeded(app: app)

        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 8),
            "The control bar must be visible before opening settings."
        )
        openPlaybackSettingsFromSlideshow(app: app)
        selectSinglePhotoDisplayMode(app: app)
        confirmExifOnAndFiveSecondInterval(app: app)
        attachStrictE2EScreenshot(app: app, name: "settings-single-photo")
        returnToSlideshowFromPlaybackSettings(app: app)
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 8),
            "After returning to the playback page, the control bar must be revealed again."
        )
        dismissPlaybackEntryHintIfNeeded(app: app)
        pausePlaybackIfNeeded(app: app)

        try locateStableA2WithoutFixture3(app: app)
        revealPlaybackControlsWithoutWaitHelper(app: app)
        attachStrictE2EScreenshot(app: app, name: "a2-stable-before-play")
        _ = capturePauseStage(app: app, stage: "a2-stable-before-play")

        let playPause = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPause.exists && playPause.isHittable,
            "The control bar must still be visible before tapping Play; do not tap the screen again to reveal it."
        )
        let playUptime = ProcessInfo.processInfo.systemUptime
        tapElement(playPause)
        XCTAssertTrue(
            waitUntil(timeout: 2) { self.playPauseState(playPause) == "pause" },
            "After tapping Play, the button value must become pause."
        )

        var frameIndex = 0
        var keepAlwaysFrameCount = 0
        var attachedNamedScreenshots = Set<String>()
        if attachKeepAlwaysFrame(app: app, index: frameIndex) {
            keepAlwaysFrameCount += 1
        }
        frameIndex += 1
        var lastFrameUptime = playUptime
        var hitProbeRaw = ""
        var hitContractProbeRaw = ""
        var hitProbeUptime: TimeInterval = 0
        var lastProbeRaw = ""
        var lastContractProbeRaw = ""
        var lastProbeUptime = playUptime
        var windowDetected = false
        let probeDeadline = playUptime + 7.0
        while ProcessInfo.processInfo.systemUptime <= probeDeadline {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastFrameUptime >= 0.08 {
                if attachKeepAlwaysFrame(app: app, index: frameIndex) {
                    keepAlwaysFrameCount += 1
                }
                frameIndex += 1
                lastFrameUptime = now
            }
            lastContractProbeRaw = contractProbeRaw(app: app)
            lastProbeRaw = frameSynchronizedProbeRaw(app: app)
            lastProbeUptime = now
            if !lastProbeRaw.isEmpty,
                let state = probeState(from: lastProbeRaw, elapsedSeconds: now - playUptime),
                isOutgoingOnlyPauseWindow(state)
            {
                hitProbeRaw = lastProbeRaw
                hitContractProbeRaw = lastContractProbeRaw
                hitProbeUptime = now
                windowDetected = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.06))
        }

        if windowDetected {
            if attachKeepAlwaysFrame(app: app, index: frameIndex) {
                keepAlwaysFrameCount += 1
            }
            frameIndex += 1
            let windowPNG = captureNamedPNG(app: app, name: "window-detected")
            if !windowPNG.isEmpty {
                attachedNamedScreenshots.insert("window-detected")
            }
            tapElement(playPause)
        } else {
            attachStrictE2EScreenshot(app: app, name: "window-timeout")
            if playPause.exists, playPauseState(playPause) != "play" {
                tapElement(playPause)
            }
        }

        let pauseUptime = ProcessInfo.processInfo.systemUptime
        let postPauseProbeRaw = frameSynchronizedProbeRaw(app: app)
        let pausedState = playPauseState(playPause)
        if attachKeepAlwaysFrame(app: app, index: frameIndex) {
            keepAlwaysFrameCount += 1
        }
        frameIndex += 1
        let afterPausePNG = captureNamedPNG(app: app, name: "after-pause")
        if !afterPausePNG.isEmpty {
            attachedNamedScreenshots.insert("after-pause")
        }
        _ = capturePauseStage(app: app, stage: "after-pause")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let postPause03ProbeRaw = frameSynchronizedProbeRaw(app: app)
        if attachKeepAlwaysFrame(app: app, index: frameIndex) {
            keepAlwaysFrameCount += 1
        }
        let afterPause03PNG = captureNamedPNG(app: app, name: "after-pause-0_3s")
        if !afterPause03PNG.isEmpty {
            attachedNamedScreenshots.insert("after-pause-0_3s")
        }
        _ = capturePauseStage(app: app, stage: "after-pause-0_3s")

        let overlayText = visibleExifOverlayText(app: app)
        let visibleMark = classifyVisibleFixture(app: app)
        let seesFixture3 = overlayText.contains("Fixture 3")
        let seesCompleteA3 = visibleMark == "A3"
        let afterPauseIdentity = StrictE2EPhotoIdentity.classify(png: afterPausePNG)
        let afterPause03Identity = StrictE2EPhotoIdentity.classify(png: afterPause03PNG)
        let probeHit = windowDetected ? "HIT" : "MISS"
        let requiredFramesPresent =
            keepAlwaysFrameCount > 0
            && attachedNamedScreenshots.contains("after-pause")
            && attachedNamedScreenshots.contains("after-pause-0_3s")
            && (probeHit == "MISS" || attachedNamedScreenshots.contains("window-detected"))
        let postPausePositive =
            isPostPauseProbePositive(postPauseProbeRaw)
            && isPostPauseProbePositive(postPause03ProbeRaw)
        let postPauseBlackOrBlank =
            isPostPauseBlackOrBlank(postPauseProbeRaw)
            || isPostPauseBlackOrBlank(postPause03ProbeRaw)
        let isLate = seesFixture3 || seesCompleteA3
        let visualVerdict: String
        if !requiredFramesPresent {
            visualVerdict = "MISSING_FRAMES"
        } else if postPauseBlackOrBlank {
            visualVerdict = "BLACK_OR_BLANK"
        } else if isLate {
            visualVerdict = "LATE"
        } else if probeHit == "HIT" && postPausePositive {
            visualVerdict = "NEEDS_HUMAN_REVIEW"
        } else {
            visualVerdict = ""
        }

        attachVerdict([
            "probe_hit": probeHit,
            "visual_verdict": visualVerdict,
            "window_detected": windowDetected,
            "hit_probe_identifier": "slideshow.scenePresentation.frameSynchronized.summary",
            "probe_raw_at_hit": hitProbeRaw,
            "probe_raw_last": lastProbeRaw,
            "post_pause_probe_raw": postPauseProbeRaw,
            "post_pause_0_3s_probe_raw": postPause03ProbeRaw,
            "post_pause_probe_positive": postPausePositive,
            "contract_probe_identifier": "slideshow.scenePresentation.contract.summary",
            "contract_probe_raw_at_hit": hitContractProbeRaw,
            "contract_probe_raw_last": lastContractProbeRaw,
            "play_uptime": playUptime,
            "window_detected_uptime": hitProbeUptime,
            "pause_uptime": pauseUptime,
            "after_pause_0_3s_uptime": ProcessInfo.processInfo.systemUptime,
            "last_probe_uptime": lastProbeUptime,
            "visible_exif": overlayText,
            "visible_mark": visibleMark,
            "sees_fixture_3": seesFixture3,
            "sees_complete_a3": seesCompleteA3,
            "play_pause_after": pausedState,
            "frame_count": keepAlwaysFrameCount,
            "after_pause_identity": StrictE2EPhotoIdentity.payload(afterPauseIdentity),
            "after_pause_0_3s_identity": StrictE2EPhotoIdentity.payload(afterPause03Identity)
        ])

        XCTAssertEqual(
            pausedState,
            "play",
            "Pause may be tapped only once, in the window or after the timeout; the button value must be play."
        )
        if probeHit == "MISS" {
            XCTFail(
                "probe_hit=MISS: frame-synchronized probe never saw outgoing translucent and incoming opacity=0 in 7 s."
            )
        } else if visualVerdict == "MISSING_FRAMES" {
            XCTFail(
                "visual_verdict=MISSING_FRAMES: missing a window-detected, after-pause, after-pause-0_3s or play-to-pause keepAlways frame."
            )
        } else if visualVerdict == "BLACK_OR_BLANK" {
            XCTFail("visual_verdict=BLACK_OR_BLANK: synced probe missing after pause, or outgoing opacity already 0.")
        } else if visualVerdict == "LATE" {
            XCTFail("visual_verdict=LATE: Fixture 3 or a complete A3 visible after pause. visible_mark=\(visibleMark)")
        } else if visualVerdict != "NEEDS_HUMAN_REVIEW" {
            XCTFail("After pausing, the synced probe does not meet outgoing opacity>0 and incoming opacity=0.")
        }
        do {
            try StrictE2EPhotoIdentity.assertRequiredFrames(
                [
                    "window-detected": attachedNamedScreenshots.contains("window-detected"),
                    "after-pause": attachedNamedScreenshots.contains("after-pause"),
                    "after-pause-0_3s": attachedNamedScreenshots.contains("after-pause-0_3s")
                ],
                required: ["window-detected", "after-pause", "after-pause-0_3s"]
            )
            try StrictE2EPhotoIdentity.assertExifCorrespondence(afterPauseIdentity, overlayText: overlayText)
            try StrictE2EPhotoIdentity.assertExifCorrespondence(afterPause03Identity, overlayText: overlayText)
            try StrictE2EPhotoIdentity.assertPauseHold(afterPauseIdentity, afterPause03Identity)
        } catch {
            XCTFail(error.localizedDescription)
        }
        if let directory = StrictE2EVisualEvidence.directory() {
            try? overlayText.data(using: .utf8)?.write(
                to: directory.appendingPathComponent("after-pause.overlay.txt"),
                options: .atomic
            )
        }
        StrictE2EVisualEvidence.writeJSON(
            [
                "suite": "pause-window",
                "device": currentDeviceTag(),
                "overlay_text_after_pause": overlayText,
                "required_frames": [
                    "window-detected": attachedNamedScreenshots.contains("window-detected"),
                    "after-pause": attachedNamedScreenshots.contains("after-pause"),
                    "after-pause-0_3s": attachedNamedScreenshots.contains("after-pause-0_3s")
                ],
                "after_pause": StrictE2EPhotoIdentity.payload(afterPauseIdentity),
                "after_pause_0_3s": StrictE2EPhotoIdentity.payload(afterPause03Identity)
            ],
            name: "visual-identity.json"
        )
    }

    // Seam: 401 / HTML 200 / unreachable / timeout must each show an actionable error and must not save.
    @MainActor
    func testFirstBootFailureStaysOnFirstBoot() throws {
        let input = try requireStrictE2EInput()
        let scenario = requireBoundFailureScenario()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try fillFirstBootForm(app: app, input: input)
        tapTestConnection(app: app)

        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 8),
            "The first-boot page must show the Save Settings button."
        )
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let alert = app.alerts.firstMatch
        let failureTimeout: TimeInterval = (scenario == "unreachable" || scenario == "timeout") ? 60 : 30
        let failureAppeared = waitUntil(timeout: failureTimeout) {
            self.acceptLocalNetworkPermissionIfNeeded()
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            return alert.exists
        }
        XCTAssertTrue(
            failureAppeared,
            "Wait for the real connection-test failure; a still-disabled Save button does not mean it failed."
        )
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        assertActionableFailure(in: alert, scenario: scenario)
        attachStrictE2EScreenshot(app: app, name: "firstboot-failure-alert-\(scenario)-\(currentDeviceTag())")
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        dismissFirstAlertIfNeeded(app: app)
        XCTAssertFalse(saveButton.isEnabled, "Save must stay disabled after a failed connection test.")
        XCTAssertTrue(
            app.textFields["firstboot.serverURL.field"].exists,
            "A failed connection test must stay on the first-boot page."
        )

        try relaunchStrictE2EApp(app)
        XCTAssertTrue(
            app.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 12),
            "After a relaunch on the failure path, the app must still be on the first-boot page."
        )
        let saveAfterRelaunch = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(saveAfterRelaunch.waitForExistence(timeout: 8))
        XCTAssertFalse(
            saveAfterRelaunch.isEnabled,
            "After a relaunch on the failure path, no half-finished settings may be saveable."
        )
        attachStrictE2EScreenshot(app: app, name: "firstboot-failure-after-relaunch-\(currentDeviceTag())")
    }

    private func requireBoundFailureScenario() -> String {
        let scenario = ProcessInfo.processInfo.environment["STRICT_E2E_INPUT_SCENARIO"] ?? ""
        let allowed = ["auth-401", "html-200", "unreachable", "timeout"]
        XCTAssertFalse(scenario.isEmpty, "A failing connection test must be bound to STRICT_E2E_INPUT_SCENARIO.")
        XCTAssertTrue(
            allowed.contains(scenario),
            "A failing connection test cannot bind \(scenario); only 401 / HTML 200 / unreachable / timeout."
        )
        return scenario
    }

    @MainActor
    private func assertActionableFailure(in alert: XCUIElement, scenario: String) {
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let texts = ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label))
            .joined(separator: " | ")
        switch scenario {
        case "auth-401":
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            XCTAssertTrue(
                texts.contains("API Key 无效") || texts.contains("服务器拒绝了这个 API Key"),
                "401 must show an actionable Key error, actual: \(texts)"
            )
        case "html-200":
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            XCTAssertTrue(
                texts.contains("不是 JSON") || texts.contains("填错了 Immich"),
                "HTML 200 must say the address/entry point is wrong, actual: \(texts)"
            )
        case "unreachable":
            // With a reserved port that nothing listens on plus waitsForConnectivity, the user sees a timeout
            // failure, not a permission wait.
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            XCTAssertTrue(
                texts.contains("网络请求失败")
                    && (texts.contains("请求超时") || texts.contains("超时") || texts.contains("无法连接")
                        || texts.contains("本地网络") || texts.contains("无线数据")),
                "Unreachable must show an actionable connection error, actual: \(texts)"
            )
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            XCTAssertFalse(
                texts.contains("API Key 无效") || texts.contains("不是 JSON"),
                "Unreachable must not pose as 401 or HTML 200."
            )
        case "timeout":
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            XCTAssertTrue(
                texts.contains("网络请求失败")
                    && (texts.contains("请求超时") || texts.contains("超时")
                        || texts.localizedCaseInsensitiveContains("timed out")),
                "Timeout must show an actionable timeout error, actual: \(texts)"
            )
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            XCTAssertFalse(
                texts.contains("API Key 无效") || texts.contains("不是 JSON"),
                "Timeout must not pose as 401 or HTML 200."
            )
        default:
            XCTFail("Unbound failure scenario: \(scenario)")
        }
    }

    @MainActor
    private func completeFirstBootToModeSelection(
        app: XCUIApplication,
        input: StrictE2EInput,
        evidencePrefix: String
    ) throws {
        try fillFirstBootForm(app: app, input: input)
        tapTestConnection(app: app)

        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 8),
            "The first-boot page must show the Save Settings button."
        )
        XCTAssertTrue(
            waitForSaveEnabled(app: app, saveButton: saveButton, timeout: 45),
            "Save must become enabled after a real connection test succeeds."
        )
        attachStrictE2EScreenshot(app: app, name: "\(evidencePrefix)-connection-passed-\(currentDeviceTag())")
        tapElement(saveButton)
        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(timeout: 15),
            "After a successful save, the app must reach mode selection."
        )
        XCTAssertTrue(app.buttons["mode.filtered.button"].exists, "The mode page must also offer the filter entry.")
        attachStrictE2EScreenshot(app: app, name: "\(evidencePrefix)-mode-selection-\(currentDeviceTag())")
    }

    @MainActor
    private func fillFirstBootForm(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        if !serverField.waitForExistence(timeout: 20) {
            attachStrictE2EScreenshot(app: app, name: "firstboot-missing-\(currentDeviceTag())")
            if app.buttons["slideshow.control.settings.button"].exists {
                XCTFail("Playback page after uninstall means a dirty install container; cannot continue manual entry.")
            } else {
                XCTFail("A fresh install must reach the normal first-boot page.")
            }
            return
        }
        replaceText(in: serverField, with: input.serverURL)
        XCTAssertEqual(
            serverField.value as? String,
            input.serverURL,
            "The public test URL must be entered verbatim, not guessed from a default value."
        )

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 8), "The first-boot page must show the API Key field.")
        replaceText(in: apiKeyField, with: input.publicKey)
        XCTAssertTrue(
            waitUntil(timeout: 3) { self.secureFieldHasEnteredValue(apiKeyField) },
            "API Key must reach the secure field; tapping blank space to hide the keyboard clears uncommitted input."
        )
        commitFocusedInputIfNeeded(app: app)
        attachStrictE2EScreenshot(app: app, name: "firstboot-form-filled-\(currentDeviceTag())")
    }

    @MainActor
    private func tapTestConnection(app: XCUIApplication) {
        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(
            testConnectionButton.waitForExistence(timeout: 8),
            "The first-boot page must show the Test Connection button."
        )
        tapElement(testConnectionButton)
    }

    @MainActor
    private func attachOrientationEvidence(app: XCUIApplication, name: String) {
        attachStrictE2EScreenshot(app: app, name: "\(name)-\(currentDeviceTag())")
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            waitUntil(timeout: 4) { XCUIDevice.shared.orientation.isLandscape },
            "iPad must rotate to landscape to record split-view evidence."
        )
        attachStrictE2EScreenshot(app: app, name: "\(name)-ipad-landscape")
        XCUIDevice.shared.orientation = .portrait
        _ = waitUntil(timeout: 4) { XCUIDevice.shared.orientation.isPortrait }
    }

    @MainActor
    private func chooseOnboardingModeAndContinue(
        app: XCUIApplication,
        identifier: String
    ) {
        let modeButton = firstBootControl(in: app, identifier: identifier)
        XCTAssertTrue(modeButton.waitForExistence(timeout: 8), "The mode page must offer \(identifier).")
        let continueButton = firstBootControl(
            in: app,
            identifier: "mode.continue.button"
        )
        // First boot preselects random, so Continue is enabled from the start; isEnabled does not mean the
        // filter mode is selected.
        _ = waitUntil(timeout: 2) { continueButton.exists && continueButton.isEnabled }
        if !isOnboardingModeSelected(modeButton) {
            modeButton.tap()
        }
        if !waitUntil(timeout: 2, condition: { self.isOnboardingModeSelected(modeButton) }) {
            modeButton.tap()
            _ = waitUntil(timeout: 2, condition: { self.isOnboardingModeSelected(modeButton) })
        }
        // A late system "Save Password?" prompt, shown in the simulator's language, can swallow the
        // Continue tap. Dismiss it with Not Now only, so the test credential is never saved, and tap
        // Continue again while the mode page is still showing.
        for _ in 0..<3 {
            dismissSavePasswordPromptIfShown(app: app)
            guard continueButton.exists else { return }
            if continueButton.isHittable {
                continueButton.tap()
            }
            let settled = waitUntil(timeout: 4) {
                !continueButton.exists || self.savePasswordPromptShown(app: app)
            }
            if settled && !continueButton.exists {
                return
            }
        }
    }

    @MainActor
    private func savePasswordPromptShown(app: XCUIApplication) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        return [app, springboard].contains { host in
            // ui-label-lookup: Detect the simulator-owned Save Password prompt.
            ["以后", "Not Now"].contains { host.buttons[$0].exists }
        }
    }

    @MainActor
    private func dismissSavePasswordPromptIfShown(app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for host in [app, springboard] {
            // ui-label-lookup: Dismiss the simulator-owned Save Password prompt with Not Now.
            for label in ["以后", "Not Now"] where host.buttons[label].exists {
                // ui-label-lookup: Dismiss the system Save Password sheet without saving credentials.
                host.buttons[label].tap()
                _ = waitUntil(timeout: 2) { !self.savePasswordPromptShown(app: app) }
                return
            }
        }
    }

    @MainActor
    private func isOnboardingModeSelected(_ modeButton: XCUIElement) -> Bool {
        modeButton.isSelected || modeButton.images["checkmark.circle.fill"].exists
    }

    @MainActor
    private func waitForFilterSummary(app: XCUIApplication) {
        let reached = waitUntil(timeout: 20) {
            app.buttons["filterSummary.album.button"].exists
                || app.descendants(matching: .any)["filterSummary.album.button"].exists
                || app.staticTexts["filterSummary.page.title"].exists
        }
        if reached { return }
        attachStrictE2EScreenshot(app: app, name: "journey-b-filter-missing-\(currentDeviceTag())")
        if app.buttons["slideshow.control.settings.button"].exists {
            XCTFail("Chose filter but reached the playback page, so the mode card tap did not register.")
        } else if app.buttons["mode.random.button"].exists {
            XCTFail("Still on the mode page after Continue; filter mode did not start.")
        } else {
            XCTFail("Filter mode must reach the filter summary page.")
        }
    }

    // On iPhone the root back button under the safe area / wizard header often exists but is not hittable;
    // tapping its center coordinate hits the scroll layer.
    @MainActor
    private func returnToModeSelectionFromFilterSummary(app: XCUIApplication) {
        let backButton = app.buttons["global.back.button"]
        XCTAssertTrue(
            backButton.waitForExistence(timeout: 8),
            "The first-boot filter summary must offer a way back to mode selection."
        )
        XCTAssertFalse(
            app.buttons["filterSummary.backToMode.button"].exists,
            "The iOS filter summary should no longer use a bottom back button, to avoid duplicating the second entry."
        )
        _ = app.staticTexts["filterSummary.page.title"].waitForExistence(timeout: 4)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let offsets = [
            CGVector(dx: 0.20, dy: 0.20),
            CGVector(dx: 0.10, dy: 0.55),
            CGVector(dx: 0.35, dy: 0.80)
        ]
        for (attempt, offset) in offsets.enumerated() {
            if backButton.isHittable {
                backButton.tap()
            } else {
                backButton.coordinate(withNormalizedOffset: offset).tap()
            }
            if app.buttons["mode.random.button"].waitForExistence(timeout: 5) {
                return
            }
            attachStrictE2EScreenshot(app: app, name: "journey-b-back-retry-\(attempt)-\(currentDeviceTag())")
        }
        attachStrictE2EScreenshot(app: app, name: "journey-b-back-failed-\(currentDeviceTag())")
        XCTFail("Going back from the filter summary must return to mode selection.")
    }

    @MainActor
    private func dismissPlaybackEntryHintIfNeeded(app: XCUIApplication) {
        let banner = app.descendants(matching: .any)["slideshow.entryHint.banner"]
        if banner.waitForExistence(timeout: 2) {
            tapElement(banner)
            _ = waitUntil(timeout: 2) { !banner.exists }
        }
    }

    @MainActor
    private func waitForPlaybackControls(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            let settings = app.buttons["slideshow.control.settings.button"]
            if settings.exists && settings.isHittable {
                return true
            }
            app.tap()
            return false
        }
    }

    // String? ?? NSNull() has no common type and cannot go into the array; upcast to Any? first to get JSON null.
    private func jsonSafeMarks(_ marks: [String?]) -> [Any] {
        marks.map { $0 as Any? ?? NSNull() }
    }

    @MainActor
    private func captureHistoryIdentity(app: XCUIApplication, step: String) -> StrictE2EPhotoIdentity.Result {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        revealPlaybackControlsWithoutWaitHelper(app: app)
        let png = captureNamedPNG(app: app, name: step)
        let identity = StrictE2EPhotoIdentity.classify(png: png)
        XCTAssertEqual(
            identity.status,
            .match,
            "Visual ID failed \(step): \(identity.status.rawValue) \(identity.notes.joined(separator: " "))"
        )
        return identity
    }

    @MainActor
    private func captureNamedPNG(app: XCUIApplication, name: String) -> Data {
        let png = app.screenshot().pngRepresentation
        if !png.isEmpty {
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            StrictE2EVisualEvidence.writePNG(png, name: name)
        }
        return png
    }

    @MainActor
    private func recordControlTimeline(app: XCUIApplication, event: String) {
        let playPause = app.buttons["slideshow.control.playPause.button"]
        let previous = app.buttons["slideshow.control.previous.button"]
        // The probes only give an EXIF/asset cross-check; they cannot replace the in-repository visual identity
        // contract.
        let visibleImageProbe = app.descendants(matching: .any)["slideshow.currentAssetId.flag"]
        let smartFillProbe = app.descendants(matching: .any)["slideshow.smartfill.currentManifest.flag"]
        let payload: [String: Any] = [
            "event": event,
            "device": currentDeviceTag(),
            "firstboot_visible": app.textFields["firstboot.serverURL.field"].exists,
            "mode_visible": app.buttons["mode.random.button"].exists,
            "filter_summary_visible": app.buttons["filterSummary.album.button"].exists,
            "settings_visible": app.buttons["slideshow.control.settings.button"].exists,
            "previous_enabled": previous.exists ? previous.isEnabled : false,
            "play_pause": playPause.exists ? playPauseState(playPause) : "",
            "visible_image_asset_id": visibleImageProbe.exists ? visibleImageProbe.label : "",
            "smartfill_manifest": smartFillProbe.exists ? smartFillProbe.label : ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else {
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "strict-e2e-control-timeline-\(event)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func capturePauseStage(app: XCUIApplication, stage: String) -> [String: Any] {
        let uptime = ProcessInfo.processInfo.systemUptime
        let playPause = app.buttons["slideshow.control.playPause.button"]
        let settings = app.buttons["slideshow.control.settings.button"]
        let previous = app.buttons["slideshow.control.previous.button"]
        let next = app.buttons["slideshow.control.next.button"]
        let playPauseExists = playPause.exists
        let settingsExists = settings.exists
        let previousExists = previous.exists
        let nextExists = next.exists
        let visibleImageProbe = app.descendants(matching: .any)["slideshow.currentAssetId.flag"]
        let visibleImageAssetId = visibleImageProbe.exists ? visibleImageProbe.label : ""
        let originalConditionNote: String
        if visibleImageAssetId == "asset-a-2" {
            originalConditionNote = ""
        } else if visibleImageAssetId.isEmpty {
            originalConditionNote = "Original condition not covered: probe gave no asset id; identify by screenshot"
        } else {
            originalConditionNote = "Original condition not covered: probe is not A2 (\(visibleImageAssetId))"
        }

        let payload: [String: Any] = [
            "stage": stage,
            "system_uptime": uptime,
            "device": currentDeviceTag(),
            "play_pause_exists": playPauseExists,
            "play_pause_hittable": playPauseExists && playPause.isHittable,
            "play_pause": playPauseExists ? playPauseState(playPause) : "",
            "settings_exists": settingsExists,
            "settings_hittable": settingsExists && settings.isHittable,
            "previous_exists": previousExists,
            "previous_hittable": previousExists && previous.isHittable,
            "next_exists": nextExists,
            "next_hittable": nextExists && next.isHittable,
            "visible_image_asset_id": visibleImageAssetId,
            "original_a2_condition_note": originalConditionNote
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "pause-stage-\(stage)-\(currentDeviceTag())"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        attachStrictE2EScreenshot(app: app, name: "pause-stage-\(stage)-\(currentDeviceTag())")
        return payload
    }

    private func attachPauseStageTimeline(_ stages: [[String: Any]]) {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: ["stages": stages],
                options: [.prettyPrinted, .sortedKeys]
            )
        else {
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "pause-stage-timeline"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func playPauseState(_ button: XCUIElement) -> String {
        ((button.value as? String) ?? "").lowercased()
    }

    private func currentDeviceTag() -> String {
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let orientation = XCUIDevice.shared.orientation.isLandscape ? "landscape" : "portrait"
        return "\(idiom)-\(orientation)"
    }

    private func replaceText(in field: XCUIElement, with value: String) {
        field.tap()
        let existingValue = field.value as? String ?? ""
        let looksLikePlaceholder =
            existingValue.contains("请输入") || existingValue.localizedCaseInsensitiveContains("enter")
        if !existingValue.isEmpty && !looksLikePlaceholder {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingValue.count))
        }
        field.typeText(value)
    }

    private func secureFieldHasEnteredValue(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return !value.isEmpty && !value.contains("请输入") && !value.localizedCaseInsensitiveContains("api key")
    }

    private func commitFocusedInputIfNeeded(app: XCUIApplication) {
        // ui-label-lookup: Match the simulator-localized system keyboard action.
        for label in ["完成", "Done", "next", "Next"] {
            // ui-label-lookup: System keyboard keys follow the simulator language.
            let keyboardButton = app.keyboards.buttons[label]
            if keyboardButton.exists && keyboardButton.isHittable {
                keyboardButton.tap()
                return
            }
            let accessory = app.buttons["server.keyboard.done.button"]
            if accessory.exists && accessory.isHittable && accessory.identifier != "firstboot.saveConfig.button" {
                accessory.tap()
                return
            }
        }
    }

    private func waitForSaveEnabled(
        app: XCUIApplication,
        saveButton: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            acceptLocalNetworkPermissionIfNeeded()
            if saveButton.exists && saveButton.isEnabled {
                return true
            }
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let alert = app.alerts.firstMatch
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
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
        // ui-label-lookup: Dismiss the simulator-owned local network permission prompt.
        for label in ["允许", "Allow"] {
            // ui-label-lookup: The permission action belongs to SpringBoard.
            let button = springboard.alerts.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
    }

    private func dismissFirstAlertIfNeeded(app: XCUIApplication) {
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let alert = app.alerts.firstMatch
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        guard alert.exists else { return }
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        for label in ["好", "确定", "OK", "关闭"] {
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let button = alert.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        if alert.buttons.count > 0 {
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            alert.buttons.element(boundBy: 0).tap()
        }
    }

    private func firstBootControl(
        in app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        let identifiedElement = app.descendants(matching: .any)[identifier]
        return identifiedElement
    }

    private func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func waitForElement(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    // launchStrictE2EApp clears launchEnvironment and rejects leftover UI_TEST_* keys. This pause-window
    // run needs exactly these five: server URL/key so first-boot is skipped, reset plus mode-selection to
    // reach a clean mode page, and the scene-presentation probe the outgoing-translucent check reads.
    @MainActor
    private func launchOutgoingPauseWindowApp() throws -> XCUIApplication {
        let input = try requireStrictE2EInput()
        let app = XCUIApplication()
        app.launchEnvironment = [
            "UI_TEST_SERVER_URL": input.serverURL,
            "UI_TEST_API_KEY": input.publicKey,
            "UI_TEST_RESET_STATE": "1",
            "UI_TEST_FORCE_MODE_SELECTION": "1",
            "UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE": "1"
        ]
        let audit = try JSONSerialization.data(
            withJSONObject: ["launch_environment_keys": app.launchEnvironment.keys.sorted()],
            options: [.prettyPrinted, .sortedKeys]
        )
        let attachment = XCTAttachment(data: audit, uniformTypeIdentifier: "public.json")
        attachment.name = "pause-window-launch-environment-keys"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.launch()
        return app
    }

    @MainActor
    private func pausePlaybackIfNeeded(app: XCUIApplication) {
        let playPause = app.buttons["slideshow.control.playPause.button"]
        guard playPause.waitForExistence(timeout: 4) else { return }
        if playPauseState(playPause) != "play" {
            tapElement(playPause)
        }
        XCTAssertTrue(
            waitUntil(timeout: 4) { self.playPauseState(playPause) == "play" },
            "Pause before opening settings or identifying photos, so autoplay does not move away."
        )
    }

    // iPad sidebar handling is copied from PlaybackHistoryIOSUITests.openPlaybackSettingsFromSlideshow, into
    // this file only.
    @MainActor
    private func openPlaybackSettingsFromSlideshow(app: XCUIApplication) {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(settingsButton.exists && settingsButton.isHittable, "The settings button must be tappable.")
        tapElement(settingsButton)

        let playbackEntry: XCUIElement
        if UIDevice.current.userInterfaceIdiom == .pad {
            if app.switches["settings.playback.autoPlay.toggle"].waitForExistence(timeout: 2) { return }
            let sidebar = app.buttons["ToggleSidebar"]
            // ui-label-lookup: Check the simulator-owned navigation control's localized title before toggling it.
            if sidebar.exists && ["显示边栏", "Show Sidebar"].contains(sidebar.label) {
                tapElement(sidebar)
            }
            playbackEntry = app.descendants(matching: .any)["settings.item.playback"].firstMatch
        } else {
            playbackEntry = app.buttons["settings.item.playback"]
        }
        XCTAssertTrue(
            playbackEntry.waitForExistence(timeout: 8),
            "The settings list must offer the playback settings entry"
        )
        tapElement(playbackEntry)
    }

    @MainActor
    private func returnToSlideshowFromPlaybackSettings(app: XCUIApplication) {
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
            "Could not return from playback settings to the playback page"
        )
    }

    @MainActor
    private func selectSinglePhotoDisplayMode(app: XCUIApplication) {
        let picker = app.segmentedControls["settings.playback.displayMode.picker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 8),
            "Playback settings must offer the display mode segmented control."
        )
        let singlePhoto = picker.buttons["settings.playback.displayMode.singlePhoto.option"]
        XCTAssertTrue(singlePhoto.waitForExistence(timeout: 3), "Display mode must offer single photo mode.")
        tapElement(singlePhoto)
        XCTAssertTrue(singlePhoto.exists, "The segmented control must remain after selecting single photo mode.")
        // ui-label-lookup: Preserve the Simplified Chinese display-mode copy assertion after identifier lookup.
        XCTAssertEqual(singlePhoto.label, "单图模式", "The display mode option must keep its Simplified Chinese copy.")
    }

    @MainActor
    private func confirmExifOnAndFiveSecondInterval(app: XCUIApplication) {
        let exifToggle = app.switches["settings.playback.showExif.toggle"]
        XCTAssertTrue(exifToggle.waitForExistence(timeout: 8), "Playback settings must offer the EXIF toggle.")
        let toggleValue = ((exifToggle.value as? String) ?? "").lowercased()
        XCTAssertTrue(toggleValue == "1" || toggleValue == "true", "Show EXIF info must be on.")
        let intervalValue = app.staticTexts["settings.playback.interval.value"]
        // ui-label-lookup: Preserve the Simplified Chinese playback-interval copy assertion after identifier lookup.
        XCTAssertTrue(
            waitUntil(timeout: 3) { intervalValue.exists && intervalValue.label == "5 秒" }
                || (intervalValue.exists && intervalValue.label.contains("5 秒")),
            "The playback interval must be 5 seconds."
        )
    }

    @MainActor
    private func locateStableA2WithoutFixture3(app: XCUIApplication) throws {
        let next = app.buttons["slideshow.control.next.button"]
        let previous = app.buttons["slideshow.control.previous.button"]
        for step in 0...4 {
            revealPlaybackControlsWithoutWaitHelper(app: app)
            waitForSettledPhoto(app: app)
            let overlay = visibleExifOverlayText(app: app)
            let mark = classifyVisibleFixture(app: app)
            attachStrictE2EScreenshot(app: app, name: "find-a2-step-\(step)-\(mark)")
            let hasOddFixture =
                overlay.contains("Fixture 1") || overlay.contains("Fixture 3") || overlay.contains("Fixture 5")
            if hasOddFixture || mark == "A1" || mark == "A3" || mark == "A5" {
                tapElement(next)
                continue
            }
            let maybeA2 = mark == "A2" || (mark == "unknown" && !hasOddFixture)
            if maybeA2 {
                XCTAssertTrue(
                    next.waitForExistence(timeout: 4),
                    "After identifying A2, Next must be tappable to check its successor."
                )
                tapElement(next)
                waitForSettledPhoto(app: app)
                let successorOverlay = visibleExifOverlayText(app: app)
                let successor = classifyVisibleFixture(app: app)
                attachStrictE2EScreenshot(app: app, name: "a2-successor-\(successor)")
                let successorIsA3 = successor == "A3" || successorOverlay.contains("Fixture 3")
                if successor == "A4" || successor == "A5" || successorOverlay.contains("Fixture 5") {
                    if mark == "A2" {
                        attachVerdict([
                            "verdict": "PRECONDITION_FAIL",
                            "reason": "A2 successor is \(successor), not A3",
                            "visible_exif": successorOverlay,
                            "visible_mark": successor
                        ])
                        XCTFail("PRECONDITION_FAIL: order became A2→\(successor), not A2→A3.")
                        return
                    }
                    continue
                }
                if !successorIsA3 {
                    if mark == "A2" {
                        attachVerdict([
                            "verdict": "PRECONDITION_FAIL",
                            "reason": "A2 successor is not A3",
                            "visible_exif": successorOverlay,
                            "visible_mark": successor
                        ])
                        XCTFail("PRECONDITION_FAIL: A2 successor is not A3 (\(successor)).")
                        return
                    }
                    continue
                }
                revealPlaybackControlsWithoutWaitHelper(app: app)
                tapElement(previous)
                waitForSettledPhoto(app: app)
                let restoredOverlay = visibleExifOverlayText(app: app)
                let restored = classifyVisibleFixture(app: app)
                if restoredOverlay.contains("Fixture 3") || (restored != "A2" && restored != "unknown") {
                    attachVerdict([
                        "verdict": "PRECONDITION_FAIL",
                        "reason": "After returning from the successor, it is not an A2 without Fixture 3",
                        "visible_exif": restoredOverlay,
                        "visible_mark": restored
                    ])
                    XCTFail("PRECONDITION_FAIL: not the large-text A2 after returning.")
                    return
                }
                return
            }
            tapElement(next)
        }
        attachVerdict([
            "verdict": "PRECONDITION_FAIL",
            "reason": "Large-text A2 still not identified after four Next taps"
        ])
        XCTFail("PRECONDITION_FAIL: could not identify the large-text A2 using Next.")
    }

    @MainActor
    private func revealPlaybackControlsWithoutWaitHelper(app: XCUIApplication) {
        let playPause = app.buttons["slideshow.control.playPause.button"]
        if playPause.exists && playPause.isHittable { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        _ = waitUntil(timeout: 4) { playPause.exists }
    }

    @MainActor
    private func waitForSettledPhoto(app: XCUIApplication) {
        _ = waitUntil(timeout: 4) {
            guard let state = self.probeState(from: self.contractProbeRaw(app: app), elapsedSeconds: 0) else {
                return false
            }
            return state.phase == "stablePhoto"
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    @MainActor
    private func contractProbeRaw(app: XCUIApplication) -> String {
        probeRaw(app: app, identifier: "slideshow.scenePresentation.contract.summary")
    }

    @MainActor
    private func frameSynchronizedProbeRaw(app: XCUIApplication) -> String {
        probeRaw(app: app, identifier: "slideshow.scenePresentation.frameSynchronized.summary")
    }

    @MainActor
    private func probeRaw(app: XCUIApplication, identifier: String) -> String {
        let probe = app.descendants(matching: .any)[identifier]
        guard probe.exists else { return "" }
        return probe.label
    }

    private struct PauseWindowProbeState {
        let phase: String
        let layerRoles: [String]
        let layerOpacities: [Double]
    }

    // Parsing copied from ScenePresentationContractUITests.probeState, keeping only the phase / roles /
    // opacities this test's HIT needs.
    private func probeState(from label: String, elapsedSeconds: Double) -> PauseWindowProbeState? {
        _ = elapsedSeconds
        let fields = probeFields(from: label)
        guard fields["schemaVersion"] == "scene-presentation-contract-probe-v1",
            let phase = fields["phase"]
        else {
            return nil
        }
        let roles = list(fields["layerRoles"])
        let opacities = list(fields["layerOpacities"]).compactMap(Double.init)
        return PauseWindowProbeState(phase: phase, layerRoles: roles, layerOpacities: opacities)
    }

    private func probeFields(from label: String) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: label.split(separator: ";").compactMap { pair in
                guard let separator = pair.firstIndex(of: "=") else { return nil }
                return (
                    String(pair[..<separator]),
                    String(pair[pair.index(after: separator)...])
                )
            }
        )
    }

    private func list(_ raw: String?) -> [String] {
        guard let raw, raw != "none", !raw.isEmpty else { return [] }
        return raw.split(separator: "|").map(String.init)
    }

    private func isOutgoingOnlyPauseWindow(_ state: PauseWindowProbeState) -> Bool {
        guard state.phase == "transition" else { return false }
        guard state.layerRoles.count == state.layerOpacities.count else { return false }
        var outgoingFading = false
        var incomingHidden = false
        for (role, opacity) in zip(state.layerRoles, state.layerOpacities) {
            if role == "outgoing", opacity > 0, opacity < 1 {
                outgoingFading = true
            }
            if role == "incoming", opacity == 0 {
                incomingHidden = true
            }
        }
        return outgoingFading && incomingHidden
    }

    private func layerOpacity(in state: PauseWindowProbeState, role: String) -> Double? {
        guard state.layerRoles.count == state.layerOpacities.count else { return nil }
        for (layerRole, opacity) in zip(state.layerRoles, state.layerOpacities) {
            if layerRole == role { return opacity }
        }
        return nil
    }

    // Positive condition after freezing: outgoing is still visible and incoming is still fully invisible.
    private func isPostPauseProbePositive(_ raw: String) -> Bool {
        guard let state = probeState(from: raw, elapsedSeconds: 0),
            let outgoing = layerOpacity(in: state, role: "outgoing"), outgoing > 0,
            let incoming = layerOpacity(in: state, role: "incoming"), incoming == 0
        else {
            return false
        }
        return true
    }

    // Missing probe or outgoing at 0 means black/blank; 'no Fixture 3' alone must not count as a pass.
    private func isPostPauseBlackOrBlank(_ raw: String) -> Bool {
        guard !raw.isEmpty, let state = probeState(from: raw, elapsedSeconds: 0) else {
            return true
        }
        guard let outgoing = layerOpacity(in: state, role: "outgoing") else {
            return true
        }
        return !(outgoing > 0)
    }

    @MainActor
    private func visibleExifOverlayText(app: XCUIApplication) -> String {
        app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
    }

    @MainActor
    private func classifyVisibleFixture(app: XCUIApplication) -> String {
        StrictE2EPhotoIdentity.classify(png: app.screenshot().pngRepresentation).mark ?? "unknown"
    }

    @MainActor
    private func attachPauseWindowPNG(app: XCUIApplication, name: String) -> Bool {
        let png = app.screenshot().pngRepresentation
        guard !png.isEmpty else { return false }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return true
    }

    @MainActor
    private func attachKeepAlwaysFrame(app: XCUIApplication, index: Int) -> Bool {
        attachPauseWindowPNG(app: app, name: String(format: "play-to-pause-frame-%03d", index))
    }

    private func attachVerdict(_ payload: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
        else {
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "verdict.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
