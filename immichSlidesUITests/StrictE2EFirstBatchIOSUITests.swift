import XCTest

enum StrictE2EFirstBatchIOSUITestsProbeTiming {
    static let pauseWindowTimeoutSeconds: TimeInterval = TestWait.seconds(.product(7.0))
    static let probePollIntervalSeconds: TimeInterval = TestWait.seconds(.product(0.06))
}

#if os(iOS)
final class StrictE2EFirstBatchIOSUITests: XCTestCase, StrictE2EOnboardingIOS {
    override func invokeTest() {
        FirstFailureContext.reset()
        super.invokeTest()
    }

    override func record(_ issue: XCTIssue) {
        FirstFailureEvidence.record(self, issue: issue)
        super.record(issue)
    }

    let autoplayObservationSeconds: TimeInterval = TestWait.seconds(.product(6.5))
    let pauseHoldObservationSeconds: TimeInterval = TestWait.seconds(.product(10.5))

    override func setUpWithError() throws {
        continueAfterFailure = false
        FirstFailureOrientation.set(.portrait)
    }

    // Seam: manual entry on a clean install, the mode page, and the playback page after a cold relaunch of the
    // same container. Identity relies only on the in-repository visual identity contract.
    @MainActor
    func testFirstBootSetupSurvivesColdRelaunch() throws {
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminateForFailureEvidence() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "journey-a")
        attachOrientationEvidence(app: app, name: "journey-a-mode-selection")

        try relaunchStrictE2EApp(app)
        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForPublicElement(
                "firstboot.serverURL.field", timeout: TestWait.seconds(.product(3))),
            "A cold launch with saved settings must not return to the first-boot page."
        )
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: TestWait.seconds(.product(30))),
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
        let app = try launchStrictE2EApp(recordSceneSequence: true)
        defer { app.terminateForFailureEvidence() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "journey-b")

        guard
            let summaryDeadline = chooseOnboardingModeAndContinue(
                app: app, identifier: "mode.filtered.button", departureTimeout: TestWait.seconds(.product(20)))
        else { return }
        waitForFilterSummary(app: app, deadline: summaryDeadline)
        attachOrientationEvidence(app: app, name: "journey-b-filter-summary")
        returnToModeSelectionFromFilterSummary(app: app)

        guard let playbackDeadline = chooseOnboardingModeAndContinue(app: app, identifier: "mode.random.button")
        else { return }
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: max(.zero, playbackDeadline.timeIntervalSinceNow)),
            "Random mode must reach the playback page.")
        let previous = app.buttons["slideshow.control.previous.button"]
        var initialSnapshots: [String: XCUIElementSnapshot] = [:]
        let initialBoundaryTimeout = TestWait.seconds(.product(8))
        let initialBoundaryDeadline = Date().addingTimeInterval(initialBoundaryTimeout)
        FirstFailureContext.beginWait(seconds: initialBoundaryTimeout)
        var didReadInitialBoundary = false
        while Date() < initialBoundaryDeadline {
            initialSnapshots = app.evidenceSnapshotsByIdentifier()
            let render = SharedSceneEvidenceManifest.parseKeyValueFields(
                initialSnapshots["slideshow.scenePresentation.contract.summary"]?.label ?? "")
            if initialSnapshots["slideshow.control.previous.button"] != nil,
                let historyCount = Int(render["historyCount"] ?? ""), historyCount > 0
            {
                didReadInitialBoundary = Date() < initialBoundaryDeadline
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.1))))
        }
        FirstFailureContext.endWait()
        XCTAssertTrue(
            didReadInitialBoundary,
            "The playback page must show the Previous button.")
        let initialPrevious = try XCTUnwrap(initialSnapshots["slideshow.control.previous.button"])
        let initialRender = SharedSceneEvidenceManifest.parseKeyValueFields(
            initialSnapshots["slideshow.scenePresentation.contract.summary"]?.label ?? "")
        XCTAssertFalse(
            initialPrevious.isEnabled, "Previous must be disabled at the history boundary when playback starts.")
        XCTAssertEqual(
            initialRender["historyCount"], "1",
            "Playback must start with exactly one retained history entry.")
        recordControlTimeline(app: app, event: "journey-b-initial-boundary")
        dismissPlaybackEntryHintIfNeeded(app: app)
        attachOrientationEvidence(app: app, name: "journey-b-random-playback-start")

        RunLoop.current.run(until: Date().addingTimeInterval(autoplayObservationSeconds))
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: TestWait.seconds(.product(8))),
            "After auto-advance, the playback controls must be revealable."
        )
        revealPlaybackControlsWithoutWaitHelper(app: app, shouldRefreshAutoHideTimer: true)
        attachStrictE2EScreenshot(app: app, name: "journey-b-after-autoplay-5s-\(currentDeviceTag())")
        recordControlTimeline(app: app, event: "journey-b-after-autoplay")

        let playPause = app.buttons["slideshow.control.playPause.button"]
        // Screenshots and timeline reads may outlast the control bar's auto-hide delay, so tap the screen to
        // reveal it again before acting.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tapForFailureEvidence()
        XCTAssertTrue(
            playPause.waitForPublicElement(
                "slideshow.control.playPause.button", timeout: TestWait.seconds(.product(4))),
            "The playback page must show Play/Pause.")
        if playPauseState(playPause) != "play" {
            tapElement(playPause)
        }
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(4))) { self.playPauseState(playPause) == "play" },
            "After pausing, the control value must be play."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(pauseHoldObservationSeconds))
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: TestWait.seconds(.product(8))),
            "After pausing, the playback controls must still be revealable."
        )
        revealPlaybackControlsWithoutWaitHelper(app: app, shouldRefreshAutoHideTimer: true)
        attachStrictE2EScreenshot(app: app, name: "journey-b-after-pause-10s-\(currentDeviceTag())")
        XCTAssertEqual(
            playPauseState(playPause),
            "play",
            "After a pause of at least 10 seconds, autoplay must not resume on its own."
        )
        recordControlTimeline(app: app, event: "journey-b-after-pause")

        tapElement(playPause)
        let resumeCaptureDeadline = Date().addingTimeInterval(TestWait.seconds(.product(4)))
        var previousResumeObservation: [String: String] = [:]
        var lastResumeObservation: [String: String] = [:]
        let resumedInStableWindow = waitUntil(timeout: TestWait.seconds(.product(4))) {
            previousResumeObservation = lastResumeObservation
            lastResumeObservation = self.strictSceneFrameObservation(app: app)
            return self.playPauseState(playPause) == "pause"
                && StrictE2ESceneCapture.isStableWindow(lastResumeObservation)
                && Date() < resumeCaptureDeadline
        }
        attachStrictSceneObservation(
            before: previousResumeObservation, after: lastResumeObservation, name: "journey-b-resume-capture-window")
        XCTAssertTrue(
            resumedInStableWindow,
            "Resuming must continue from the current photo, with the control value back to pause. \(strictSceneCaptureDiagnostic(before: previousResumeObservation, after: lastResumeObservation, stable: StrictE2ESceneCapture.isStableWindow(lastResumeObservation)))"
        )
        tapElement(playPause)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(4))) { self.playPauseState(playPause) == "play" },
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
        let visualIdentity: [String: Any] = [
            "suite": "journey-b",
            "device": currentDeviceTag(),
            "steps": [
                historyStart, firstNext, secondNext, firstPrevious, secondPrevious
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
        defer { app.terminateForFailureEvidence() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "pause-stage")
        guard
            let playbackDeadline = chooseOnboardingModeAndContinue(
                app: app,
                identifier: "mode.random.button"
            )
        else { return }
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: max(.zero, playbackDeadline.timeIntervalSinceNow)),
            "Random mode must reach the playback page.")
        dismissPlaybackEntryHintIfNeeded(app: app)

        RunLoop.current.run(until: Date().addingTimeInterval(autoplayObservationSeconds))

        var stages: [[String: Any]] = []
        stages.append(capturePauseStage(app: app, stage: "before-control-reveal"))

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tapForFailureEvidence()
        _ = waitUntil(timeout: TestWait.seconds(.product(4))) {
            app.buttons["slideshow.control.playPause.button"].exists
        }
        stages.append(capturePauseStage(app: app, stage: "after-control-reveal-before-pause"))

        let playPause = app.buttons["slideshow.control.playPause.button"]
        if playPause.exists, playPauseState(playPause) != "play" {
            tapElement(playPause)
        }
        _ = waitUntil(timeout: TestWait.seconds(.product(4))) {
            playPause.exists && self.playPauseState(playPause) == "play"
        }
        stages.append(capturePauseStage(app: app, stage: "after-pause-confirmed-play"))

        RunLoop.current.run(until: Date().addingTimeInterval(pauseHoldObservationSeconds))
        stages.append(capturePauseStage(app: app, stage: "after-hold-10s"))

        attachPauseStageTimeline(stages)
    }

    // Seam: observe the Debug midpoint pause with the frame-synchronized probe only. The visual verdict is
    // recorded separately and never identifies the photo by currentAssetId.
    @MainActor
    func testSinglePhotoOutgoingPauseWindowCapture() throws {
        let app = try launchOutgoingPauseWindowApp()
        defer { app.terminateForFailureEvidence() }

        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForPublicElement(
                "mode.random.button", timeout: TestWait.seconds(.infrastructure(20))),
            "After injecting the public fixture, the app must reach the mode page."
        )
        guard
            let playbackDeadline = chooseOnboardingModeAndContinue(
                app: app,
                identifier: "mode.random.button"
            )
        else { return }
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: max(.zero, playbackDeadline.timeIntervalSinceNow)),
            "Random mode must reach the playback page.")
        dismissPlaybackEntryHintIfNeeded(app: app)
        pausePlaybackIfNeeded(app: app)

        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: TestWait.seconds(.product(8))),
            "The control bar must be visible before opening settings."
        )
        openPlaybackSettingsFromSlideshow(app: app)
        selectSinglePhotoDisplayMode(app: app)
        confirmExifOnAndFiveSecondInterval(app: app)
        attachStrictE2EScreenshot(app: app, name: "settings-single-photo")
        returnToSlideshowFromPlaybackSettings(app: app)
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: TestWait.seconds(.product(8))),
            "After returning to the playback page, the control bar must be revealed again."
        )
        dismissPlaybackEntryHintIfNeeded(app: app)
        pausePlaybackIfNeeded(app: app)

        try locateStableA2WithoutFixture3(app: app)
        revealPlaybackControlsWithoutWaitHelper(app: app)
        let brightFrame = capturePauseWindowFrame(app: app)
        let brightPNG = captureNamedPNG(app: app, name: "a2-stable-before-play", capturedPNG: brightFrame.sample.png)
        let brightIdentity = StrictE2EPhotoIdentity.classify(png: brightPNG)
        let brightOverlayText = visibleExifOverlayText(app: app)
        XCTAssertTrue(
            brightIdentity.status == .match && brightIdentity.mark == "A2",
            "Pause window bright proof must show A2."
        )
        let brightReference = brightPauseWindowReference(brightFrame)
        XCTAssertNotNil(
            brightReference,
            "Pause window bright proof must be one frozen opaque scene."
        )
        guard let brightReference else { return }
        do {
            try StrictE2EPhotoIdentity.assertExifCorrespondence(brightIdentity, overlayText: brightOverlayText)
        } catch {
            XCTFail(error.localizedDescription)
        }
        _ = capturePauseStage(app: app, stage: "a2-stable-before-play")

        guard
            let playPause = preparePauseWindowPlayPause(
                app: app, deadline: Date().addingTimeInterval(TestWait.seconds(.product(4))))
        else { return }
        let playUptime = ProcessInfo.processInfo.systemUptime
        tapPauseWindowPlayPause(app: app, button: playPause)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(2))) {
                app.evidenceSnapshotsByIdentifier()["slideshow.control.playPause.button"].map {
                    self.playPauseState($0)
                } == "pause"
            },
            "After tapping Play, the button value must become pause."
        )

        var frameIndex = 0
        var keepAlwaysFrameCount = 0
        var attachedNamedScreenshots = Set<String>()
        var hitProbeRaw = ""
        var hitContractProbeRaw = ""
        var hitProbeUptime: TimeInterval = TestWait.seconds(.product(0))
        var lastProbeRaw = ""
        var lastContractProbeRaw = ""
        var lastProbeUptime = playUptime
        var didDetectWindow = false
        let probeDeadline = playUptime + StrictE2EFirstBatchIOSUITestsProbeTiming.pauseWindowTimeoutSeconds
        while ProcessInfo.processInfo.systemUptime <= probeDeadline {
            lastProbeRaw = frameSynchronizedProbeRaw(app: app)
            let now = ProcessInfo.processInfo.systemUptime
            lastProbeUptime = now
            guard now <= probeDeadline else { break }
            if !lastProbeRaw.isEmpty,
                let state = probeState(from: lastProbeRaw),
                isOutgoingOnlyPauseWindow(state)
            {
                hitProbeRaw = lastProbeRaw
                hitProbeUptime = now
                didDetectWindow = true
                break
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(StrictE2EFirstBatchIOSUITestsProbeTiming.probePollIntervalSeconds))
        }

        lastContractProbeRaw = contractProbeRaw(app: app)
        var windowFrame: PauseWindowFrame?
        if didDetectWindow {
            hitContractProbeRaw = lastContractProbeRaw
            if attachKeepAlwaysFrame(app: app, index: frameIndex) {
                keepAlwaysFrameCount += 1
            }
            frameIndex += 1
            let frame = capturePauseWindowFrame(app: app)
            windowFrame = frame
            let windowPNG = captureNamedPNG(app: app, name: "window-detected", capturedPNG: frame.sample.png)
            if !windowPNG.isEmpty {
                attachedNamedScreenshots.insert("window-detected")
            }
        } else {
            attachStrictE2EScreenshot(app: app, name: "window-timeout")
        }

        let pauseUptime = ProcessInfo.processInfo.systemUptime
        let postPauseProbeRaw = frameSynchronizedProbeRaw(app: app)
        let isPausedAfterHook = probeState(from: postPauseProbeRaw)?.isPaused == true
        if attachKeepAlwaysFrame(app: app, index: frameIndex) {
            keepAlwaysFrameCount += 1
        }
        frameIndex += 1
        let afterPauseFrame = capturePauseWindowFrame(app: app)
        let afterPauseSample = afterPauseFrame.sample
        let afterPausePNG = captureNamedPNG(app: app, name: "after-pause", capturedPNG: afterPauseSample.png)
        if !afterPausePNG.isEmpty {
            attachedNamedScreenshots.insert("after-pause")
        }
        _ = capturePauseStage(app: app, stage: "after-pause")
        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.3))))
        let postPause03ProbeRaw = frameSynchronizedProbeRaw(app: app)
        if attachKeepAlwaysFrame(app: app, index: frameIndex) {
            keepAlwaysFrameCount += 1
        }
        let afterPause03Frame = capturePauseWindowFrame(app: app)
        let afterPause03Sample = afterPause03Frame.sample
        let afterPause03PNG = captureNamedPNG(app: app, name: "after-pause-0_3s", capturedPNG: afterPause03Sample.png)
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
        let midpointFrames = [windowFrame, afterPauseFrame, afterPause03Frame].compactMap { $0 }
        let midpointHasVisiblePixels = midpointFrames.allSatisfy {
            pauseWindowHasVisiblePhotoPixels($0.sample.png)
        }
        let probeHit = didDetectWindow ? "HIT" : "MISS"
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
        let visualVerdict: String
        if !requiredFramesPresent {
            visualVerdict = "MISSING_FRAMES"
        } else if postPauseBlackOrBlank {
            visualVerdict = "BLACK_OR_BLANK"
        } else if probeHit == "HIT" && postPausePositive {
            visualVerdict = "NEEDS_HUMAN_REVIEW"
        } else {
            visualVerdict = ""
        }

        attachVerdict([
            "probe_hit": probeHit,
            "visual_verdict": visualVerdict,
            "window_detected": didDetectWindow,
            "hit_probe_identifier": "slideshow.scenePresentation.frameSynchronized.summary",
            "probe_raw_at_hit": hitProbeRaw,
            "outgoing_opacity_at_hit": probeState(from: hitProbeRaw).flatMap {
                layerOpacity(in: $0, role: "outgoing")
            } as Any? ?? NSNull(),
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
            "probe_paused_after_hook": isPausedAfterHook,
            "frame_count": keepAlwaysFrameCount,
            "after_pause_identity": StrictE2EPhotoIdentity.payload(afterPauseIdentity),
            "after_pause_0_3s_identity": StrictE2EPhotoIdentity.payload(afterPause03Identity),
            "bright_identity": StrictE2EPhotoIdentity.payload(brightIdentity)
        ])

        XCTAssertTrue(
            isPausedAfterHook,
            "The midpoint hook must leave the frame-synchronized probe paused."
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
        } else if visualVerdict != "NEEDS_HUMAN_REVIEW" {
            XCTFail("After pausing, the synced probe does not meet outgoing opacity>0 and incoming opacity=0.")
        }
        XCTAssertTrue(
            midpointFrames.count == 3
                && midpointFrames.allSatisfy {
                    pauseWindowFrame($0, hasOutgoingReference: brightReference)
                        && isSameFrozenProbeFrame(hitProbeRaw, $0.probeBefore)
                }
                && isSameFrozenProbeFrame(hitProbeRaw, postPauseProbeRaw)
                && isSameFrozenProbeFrame(postPauseProbeRaw, postPause03ProbeRaw),
            "The paused pause-window probe identity must not change. Opacity and motion must remain frozen."
        )
        var pixelComparisons = [
            PlaybackHistoryIOSUITests.comparePausedPhotoPixels(afterPause03Sample, against: afterPauseSample)
        ]
        if let windowSample = windowFrame?.sample {
            pixelComparisons.append(
                PlaybackHistoryIOSUITests.comparePausedPhotoPixels(afterPauseSample, against: windowSample))
        }
        XCTAssertTrue(
            windowFrame != nil
                && pixelComparisons.allSatisfy {
                    $0.failureReason == nil && $0.differingPixelCount == 0
                },
            "Paused pause-window frames must be pixel-identical. \(pixelComparisons.map(\.summary).joined(separator: "; "))"
        )
        XCTAssertTrue(midpointHasVisiblePixels, "Pause window midpoint must contain visible photo pixels.")
        XCTAssertTrue(
            midpointFrames.allSatisfy {
                let identity = StrictE2EPhotoIdentity.classifyRejectionEvidence(png: $0.sample.png)
                return identity.status != .match || identity.mark == "A2"
            },
            "Target window shows the wrong image; cannot count as SUCCESS."
        )
        do {
            try StrictE2EPhotoIdentity.assertRequiredFrames(
                [
                    "window-detected": attachedNamedScreenshots.contains("window-detected"),
                    "after-pause": attachedNamedScreenshots.contains("after-pause"),
                    "after-pause-0_3s": attachedNamedScreenshots.contains("after-pause-0_3s")
                ],
                required: ["window-detected", "after-pause", "after-pause-0_3s"]
            )
        } catch {
            XCTFail(error.localizedDescription)
        }
        if let directory = StrictE2EVisualEvidence.directory() {
            try? overlayText.data(using: .utf8)?.write(
                to: directory.appendingPathComponent("after-pause.overlay.txt"),
                options: .atomic
            )
        }
        if let windowFrame {
            StrictE2EVisualEvidence.writeJSON(
                [
                    "schema_version": 1, "overlay_text_before_pause": brightOverlayText,
                    "bright": brightFrame.payload,
                    "frames": [
                        "window-detected": windowFrame.payload,
                        "after-pause": afterPauseFrame.payload,
                        "after-pause-0_3s": afterPause03Frame.payload
                    ]
                ], name: "pause-window-contract.json")
        }
        StrictE2EVisualEvidence.writeJSON(
            [
                "suite": "pause-window",
                "device": currentDeviceTag(),
                "before_pause": StrictE2EPhotoIdentity.payload(brightIdentity),
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
        defer { app.terminateForFailureEvidence() }

        try fillFirstBootForm(app: app, input: input)
        tapTestConnection(app: app)

        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            saveButton.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(8))),
            "The first-boot page must show the Save Settings button."
        )
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let alert = app.alerts.firstMatch
        let failureTimeout: TimeInterval = TestWait.seconds(
            .product((scenario == "unreachable" || scenario == "timeout") ? 60 : 30))
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
            app.textFields["firstboot.serverURL.field"].waitForPublicElement(
                "firstboot.serverURL.field",
                timeout: TestWait.seconds(.product(12))),
            "After a relaunch on the failure path, the app must still be on the first-boot page."
        )
        let saveAfterRelaunch = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(saveAfterRelaunch.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))))
        XCTAssertFalse(
            saveAfterRelaunch.isEnabled,
            "After a relaunch on the failure path, no half-finished settings may be saveable."
        )
        attachStrictE2EScreenshot(app: app, name: "firstboot-failure-after-relaunch-\(currentDeviceTag())")
    }
}
#endif
