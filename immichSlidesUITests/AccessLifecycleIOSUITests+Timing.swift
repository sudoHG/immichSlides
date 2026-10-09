import CryptoKit
import XCTest

#if os(iOS)
extension AccessLifecycleIOSUITests {
    @MainActor
    func playPauseButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["slideshow.control.playPause.button"]
    }

    // Cannot read value while the control is not in the tree; an empty string must not count as paused.
    @MainActor
    func playPauseState(_ button: XCUIElement) -> String {
        guard button.exists else {
            return AccessLifecycleContract.playPauseControlValue(isPresent: false, rawValue: nil)
        }
        return AccessLifecycleContract.playPauseControlValue(
            isPresent: true,
            rawValue: button.value as? String
        )
    }

    // Tap the screen to wake the control bar before reading state; once it disappears, do not tap play/pause.
    @MainActor
    func waitForPlayPauseState(
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
    func confirmPlayPauseState(
        app: XCUIApplication,
        expected: String,
        shouldTapIfNeeded: Bool,
        message: String
    ) {
        revealPlaybackControls(app: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertConfirmPlayPauseWakesCanvasBeforeWait(
                didWakeCanvas: true,
                didTapPlayPauseToWake: false
            )
        )
        let visible = playPauseButton(app)
        XCTAssertTrue(
            visible.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "The playback page must have play/pause.")
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(2))) { self.playPauseButton(app).isHittable },
            "Play/pause must be hittable."
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPlaybackControlsRevealedByTarget(
                isPlayPauseHittable: playPauseButton(app).isHittable,
                isSettingsPresent: app.buttons["slideshow.control.settings.button"].exists,
                isTreatedAsRevealed: true
            )
        )
        if shouldTapIfNeeded && playPauseState(visible) != expected {
            tapElement(visible)
        }
        if playPauseButton(app).exists == false {
            revealPlaybackControls(app: app)
        }
        XCTAssertTrue(
            waitForPlayPauseState(app: app, expected: expected, timeout: TestWait.seconds(.product(4))), message)
    }

    // The stopwatch starts when Continue is pressed; the return time is recorded separately, never as the origin.
    @MainActor
    func pressContinueStartingClock(app: XCUIApplication) -> (issued: Date, returned: Date) {
        revealPlaybackControls(app: app)
        let playPause = playPauseButton(app)
        XCTAssertTrue(
            playPause.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "The playback page must have play/pause.")
        XCTAssertTrue(playPause.exists, "Play/pause must be in the tree before continuing.")
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(2))) { self.playPauseButton(app).isHittable },
            "Play/pause must be hittable before continuing."
        )
        let issued = Date()
        tapElement(playPause)
        requests.append("playback.play")
        return (issued, Date())
    }

    @MainActor
    func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.1))))
        }
        return condition()
    }

    @MainActor
    func assertNarrowEntryHasNoPin(app: XCUIApplication) throws {
        XCTAssertFalse(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: TestWait.seconds(.product(2))),
            "This narrow entry must not enable a password."
        )
    }

    @MainActor
    func readFourSettingsFromRealUI(app: XCUIApplication) throws -> [String: Any] {
        openSettingsFromSlideshow(app: app)
        requests.append("settings.open")
        try assertNarrowEntryHasNoPin(app: app)
        return try readPlaybackSettings(app: app, shouldAllowPinUnlock: false)
    }

    @MainActor
    func changeFourSettingsFromInitial(
        app: XCUIApplication,
        initial: [String: Any]
    ) throws -> [String: Any] {
        openPlaybackSettings(app: app)
        let autoPlay = playbackSwitch(app: app, identifier: "settings.playback.autoPlay.toggle")
        XCTAssertTrue(
            autoPlay.waitForExistence(timeout: TestWait.seconds(.infrastructure(12))),
            "Playback settings must provide the autoplay toggle.")
        let isInitiallyAutoPlayEnabled = initial["autoPlayEnabled"] as? Bool ?? isToggleOn(autoPlay)
        if isToggleOn(autoPlay) == false {
            tapElement(autoPlay)
            XCTAssertTrue(
                waitUntil(timeout: TestWait.seconds(.product(4))) { self.isToggleOn(autoPlay) },
                "Autoplay must be turned on before changing the interval.")
        }
        let initialInterval = initial["intervalSeconds"] as? Int ?? Int(intervalMinimumSeconds)
        let intervalTarget =
            initialInterval == AccessLifecycleContract.requestedIntervalSeconds
            ? AccessLifecycleIOSUITestsCalibration.alternateIntervalSeconds
            : AccessLifecycleContract.requestedIntervalSeconds
        let observedInterval = try setIntervalFromUI(app: app, targetSeconds: intervalTarget)
        requests.append("settings.save.interval")
        XCTAssertNotEqual(observedInterval, initialInterval, "The interval must change to a different value.")

        let exif = playbackSwitch(app: app, identifier: "settings.playback.showExif.toggle")
        XCTAssertTrue(
            exif.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "Playback settings must provide the EXIF toggle.")
        let isInitiallyExifEnabled = initial["showExif"] as? Bool ?? isToggleOn(exif)
        if isToggleOn(exif) == isInitiallyExifEnabled {
            tapElement(exif)
        }
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(4))) { self.isToggleOn(exif) != isInitiallyExifEnabled },
            "EXIF must be switched to the opposite value through the real settings."
        )
        requests.append("settings.save.exif")

        let picker = app.segmentedControls["settings.playback.displayMode.picker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "Playback settings must provide the display policy.")
        let initialMode = initial["displayMode"] as? String ?? "smartFill"
        let targetIdentifier =
            initialMode == "smartFill"
            ? "settings.playback.displayMode.singlePhoto.option"
            : "settings.playback.displayMode.smartFill.option"
        let targetButton = picker.buttons[targetIdentifier]
        XCTAssertTrue(
            targetButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(3))),
            "The display policy must be able to switch to the other option.")
        tapElement(targetButton)
        requests.append("settings.save.display_mode")

        let shouldEnableAutoPlay = !isInitiallyAutoPlayEnabled
        if isToggleOn(autoPlay) != shouldEnableAutoPlay {
            tapElement(autoPlay)
            XCTAssertTrue(
                waitUntil(timeout: TestWait.seconds(.product(4))) { self.isToggleOn(autoPlay) == shouldEnableAutoPlay },
                "Autoplay must be switched to the opposite value through the real settings."
            )
        }
        requests.append("settings.save.autoplay")
        return try readPlaybackSettings(app: app, shouldAllowPinUnlock: false)
    }

    @MainActor
    func configureTimingPlaybackSettings(
        app: XCUIApplication,
        isAutoPlayEnabled: Bool
    ) throws -> Int {
        openSettingsFromSlideshow(app: app)
        requests.append("settings.open")
        try assertNarrowEntryHasNoPin(app: app)
        openPlaybackSettings(app: app)
        let autoPlay = playbackSwitch(app: app, identifier: "settings.playback.autoPlay.toggle")
        XCTAssertTrue(
            autoPlay.waitForExistence(timeout: TestWait.seconds(.infrastructure(12))),
            "Playback settings must provide the autoplay toggle.")
        if isToggleOn(autoPlay) != isAutoPlayEnabled {
            tapElement(autoPlay)
            XCTAssertTrue(
                waitUntil(timeout: TestWait.seconds(.product(4))) { self.isToggleOn(autoPlay) == isAutoPlayEnabled },
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
            picker.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "The pause/background cases must be able to switch to single-photo mode.")
        let singlePhoto = picker.buttons["settings.playback.displayMode.singlePhoto.option"]
        XCTAssertTrue(
            singlePhoto.waitForExistence(timeout: TestWait.seconds(.infrastructure(3))),
            "The display policy should offer single-photo mode.")
        tapElement(singlePhoto)
        requests.append("settings.save.display_mode")
        returnToSlideshowFromSettings(app: app)
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: TestWait.seconds(.product(15))),
            "Must return to the playback page after settings.")
        return interval
    }

    @MainActor
    func exercisePauseNextContinueVisibleTiming(
        app: XCUIApplication,
        intervalSeconds: Int
    ) throws -> [[String: Any]] {
        let interval = TimeInterval(intervalSeconds)
        confirmPlayPauseState(
            app: app,
            expected: "pause",
            shouldTapIfNeeded: true,
            message: "Must be playing before the mid-interval timing."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(interval / 2))))
        confirmPlayPauseState(
            app: app,
            expected: "play",
            shouldTapIfNeeded: true,
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
            didUseProgressProbe: false,
            didUseControlValueOnly: false
        )

        let holdStart = Date()
        let holdTarget = interval + AccessLifecycleContract.pauseHoldBeyondIntervalSeconds
        while Date().timeIntervalSince(holdStart) < holdTarget {
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.4))))
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
            didUseReturnedAsOrigin: false
        )
        try AccessLifecycleContract.assertContinueClockStartsAtPress(
            confirmWaitSecondsBeforeClock: 0
        )
        try AccessLifecycleContract.assertPlayPauseNotRetappedBecauseMissing(
            didAlreadyTap: true,
            didRetapBecauseMissing: false
        )
        XCTAssertTrue(
            waitForPlayPauseState(app: app, expected: "pause", timeout: TestWait.seconds(.product(4))),
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

    struct ContinueWatchRawFrame {
        let requestElapsed: TimeInterval
        let returnElapsed: TimeInterval
        let png: Data
        let isControlBarVisible: Bool
    }

    struct ContinueWatchFrame {
        let sample: AccessLifecycleContract.ContinueWatchSample
        let png: Data
    }

    struct ContinueWatchResult {
        let earlyMark: String
        let earlyElapsed: TimeInterval
        let startVerdict: AccessLifecycleContract.FirstTransitionStartVerdict
        let isOfficialStartSigned: Bool
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
                "official_signed": isOfficialStartSigned
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
                    "control_bar_visible": sample.isControlBarVisible
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
    func watchContinueToFirstAdvance(
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
        var earlyElapsed: TimeInterval = TestWait.seconds(.product(0))
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
                    "control_bar_visible": sample.isControlBarVisible
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
                isControlBarVisible: playPauseButton(app).exists
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
                isControlBarVisible: raw.isControlBarVisible
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
            hasConfirmedNewImage: confirmed != nil,
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
        let isOfficialSigned: Bool
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
            isOfficialSigned = true
        } else {
            isOfficialSigned = try AccessLifecycleContract.officialStartSigned(
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
            isOfficialStartSigned: isOfficialSigned,
            confirmedMark: confirmed.sample.mark,
            confirmedElapsed: confirmed.sample.requestElapsed,
            pressReturnedElapsed: pressReturnedElapsed,
            samples: samples,
            ipadTimingEvidence: ipadTimingEvidence
        )
    }

    func continueWatchMark(_ identity: StrictE2EPhotoIdentity.Result) -> String {
        if identity.status == .match, let mark = identity.mark {
            return mark
        }
        if identity.status == .black { return "BLACK" }
        if identity.status == .blank { return "BLANK" }
        if identity.status == .transition { return "TRANSITION" }
        return "UNRECOGNIZABLE"
    }

    @MainActor
    func captureStableNextMark(
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
                        isControlBarVisible: playPauseButton(app).exists
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
                    isControlBarVisible: raw.isControlBarVisible
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
    func captureImmediateRequiredMark(
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
    func classifyCurrentMark(app: XCUIApplication) -> String {
        contractMark(StrictE2EPhotoIdentity.captureIdentity(png: app.screenshot().pngRepresentation))
    }

    func isUsableSceneMark(_ mark: String) -> Bool {
        AccessLifecycleContract.isUsableSceneMark(mark)
    }

    // XCUIApplication has no public processIdentifier API; use processID or the pid in its description.
    func applicationProcessID(_ app: XCUIApplication) throws -> Int32 {
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

    func writeSettingsResumeJSON(name: String, extra: [String: Any]) throws {
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
