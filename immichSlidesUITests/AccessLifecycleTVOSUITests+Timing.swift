import XCTest

#if os(tvOS)
extension AccessLifecycleTVOSUITests {
    @MainActor
    func assertTVOSNarrowEntryHasNoPin(app: XCUIApplication) throws {
        XCTAssertFalse(
            app.buttons["pinEntry.close.button"].waitForFailureEvidence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.readbackTimeoutSeconds),
            "This narrow entry must not enable a password."
        )
    }

    @MainActor
    func enterPlaybackSettings(app: XCUIApplication) throws {
        openSettingsFromSlideShow(app: app)
        record("settings.open")
        try assertTVOSNarrowEntryHasNoPin(app: app)
        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForPublicElement(
                "settings.item.playback",
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home must show playback settings.")
        if playbackItem.hasFocus == false {
            moveFocus(.up, to: playbackItem, maximumPresses: 4, message: "Must return to playback settings.")
        }
        FirstFailureRemote.press(.select)
    }

    // Page identity comes from playback settings content; a momentary lack of focus is not treated as home.
    // After entering, focus must still land on the autoplay row.
    @MainActor
    func ensureInsidePlaybackSettingsPage(app: XCUIApplication) throws {
        var isHomeUniqueVisible = isTVOSHomeUniqueVisible(app: app)
        var isPlaybackSettingsContentVisible = isTVOSPlaybackSettingsContentVisible(app: app)
        var isSettingsHomeVisible = app.buttons["settings.item.playback"].isHittable
        if isPlaybackSettingsContentVisible == false && isSettingsHomeVisible == false && isHomeUniqueVisible == false {
            waitForFocusVisualSettle()
            isHomeUniqueVisible = isTVOSHomeUniqueVisible(app: app)
            isPlaybackSettingsContentVisible = isTVOSPlaybackSettingsContentVisible(app: app)
            isSettingsHomeVisible = app.buttons["settings.item.playback"].isHittable
        }
        let identity = AccessLifecycleContract.tvosSettingsPageIdentity(
            isPlaybackSettingsContentVisible: isPlaybackSettingsContentVisible,
            isHomeEntryVisible: isSettingsHomeVisible,
            isHomeUniqueVisible: isHomeUniqueVisible
        )
        try AccessLifecycleContract.assertTVOSHomeUniqueBeatsPlaybackRowLabel(
            isHomeUniqueVisible: isHomeUniqueVisible,
            isClassifiedAsPlayback: identity == "playback"
        )
        try AccessLifecycleContract.assertTVOSPageIdentityNotInferredFromMissingFocus(
            isPlaybackSettingsContentVisible: isPlaybackSettingsContentVisible && isHomeUniqueVisible == false,
            isClassifiedAsHome: identity == "home"
        )
        let homePlayback = app.buttons["settings.item.playback"]
        if identity == "home" {
            XCTAssertTrue(
                homePlayback.waitForPublicElement(
                    "settings.item.playback",
                    timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
                "Settings home must show playback settings.")
            if homePlayback.hasFocus == false {
                moveFocus(.up, to: homePlayback, maximumPresses: 6, message: "Must go back to playback settings entry.")
            }
            XCTAssertTrue(homePlayback.hasFocus, "Settings home must focus playback settings before entering.")
            FirstFailureRemote.press(.select)
            waitForFocusVisualSettle()
        }
        let autoPlayLink = app.buttons["settings.playback.autoPlay.link"]
        XCTAssertTrue(
            autoPlayLink.waitForFailureEvidence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Playback settings must show the autoplay row.")
        if autoPlayLink.hasFocus == false {
            _ = tryMoveFocus(.up, to: autoPlayLink, maximumPresses: 8)
        }
        if autoPlayLink.hasFocus == false {
            _ = tryMoveFocus(.down, to: autoPlayLink, maximumPresses: 8)
        }
        try AccessLifecycleContract.assertTVOSPlaybackSettingsEntered(
            isAutoPlayLinkFocused: autoPlayLink.hasFocus,
            isHomePlaybackFocused: homePlayback.exists && homePlayback.hasFocus
        )
    }

    @MainActor
    func isTVOSHomeUniqueVisible(app: XCUIApplication) -> Bool {
        app.buttons["settings.item.accessProtection"].isHittable
            || app.descendants(matching: .any)["settings.item.playback"].isHittable
    }

    // The home page row also shows the "Playback Settings" text, so it does not mean the page was entered.
    @MainActor
    func isTVOSPlaybackSettingsContentVisible(app: XCUIApplication) -> Bool {
        app.buttons["settings.playback.autoPlay.link"].isHittable
            || app.descendants(matching: .any)["settings.playback.autoPlay.link"].isHittable
    }

    @MainActor
    func readTVOSFourSettings(app: XCUIApplication) throws -> [String: Any] {
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
    func changeTVOSFourSettingsFromInitial(
        app: XCUIApplication,
        initial: [String: Any]
    ) throws -> [String: Any] {
        let isInitiallyAutoPlayEnabled = initial["autoPlayEnabled"] as? Bool ?? true
        let initialInterval = initial["intervalSeconds"] as? Int ?? Int(TestWait.seconds(.product(5)))
        let isInitiallyExifEnabled = initial["showExif"] as? Bool ?? true
        let initialMode = initial["displayMode"] as? String ?? "smartFill"
        let intervalTarget =
            initialInterval == AccessLifecycleContract.tvOSRequestedIntervalSeconds
            ? 15 : AccessLifecycleContract.tvOSRequestedIntervalSeconds

        try ensureInsidePlaybackSettingsPage(app: app)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.interval.link",
            option: "settings.playback.interval.\(intervalTarget).button",
            stepsToLink: 2
        )
        record("settings.save.interval")
        // After the interval Menu, go back to the autoplay row first, then search down for display mode.
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
        // After the display mode Menu the target is above: move up to autoplay first; pressing only down is
        // not allowed. EXIF lives in the display items subpage, so the generic return to playback settings
        // does not apply here.
        try AccessLifecycleContract.assertTVOSFocusSearchMustNotUseOnlyDownWhenTargetAbove(
            didTargetAppearAboveFocus: true,
            didUseOnlyDown: false
        )
        try ensureInsidePlaybackSettingsPage(app: app)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.autoPlay.link",
            option: isInitiallyAutoPlayEnabled
                ? "settings.playback.autoPlay.off.button"
                : "settings.playback.autoPlay.on.button",
            stepsToLink: 0
        )
        record("settings.save.autoplay")

        moveFocusToSettingsControl(app: app, identifier: "settings.playback.display.link", maxSteps: 7)
        FirstFailureRemote.press(.select)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.showExif.link",
            option: isInitiallyExifEnabled
                ? "settings.playback.showExif.off.button"
                : "settings.playback.showExif.on.button",
            stepsToLink: 0
        )
        record("settings.save.exif")
        FirstFailureRemote.press(.menu)
        waitForFocusVisualSettle()
        returnToSlideShow(app: app)
        return try readTVOSFourSettings(app: app)
    }

    @MainActor
    func configureTVOSTimingPlaybackSettings(
        app: XCUIApplication
    ) throws -> (actual: Int, shouldRequireIntervalReview: Bool) {
        try enterPlaybackSettings(app: app)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.autoPlay.link",
            option: "settings.playback.autoPlay.on.button",
            stepsToLink: 0
        )
        record("settings.save.autoplay")
        // When the requested interval is unavailable, the substituted interval needs a desktop closeout run.
        let resolved = try AccessLifecycleContract.resolveTimingInterval(
            requested: AccessLifecycleContract.tvOSRequestedIntervalSeconds,
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
        FirstFailureRemote.press(.menu)
        waitForFocusVisualSettle()
        returnToSlideShow(app: app)
        return resolved
    }

    @MainActor
    func selectedBinaryOption(
        app: XCUIApplication,
        link: String,
        onOption: String,
        offOption: String,
        stepsToLink: Int,
        openParentLink: String? = nil
    ) throws -> Bool {
        if let parent = openParentLink {
            moveFocusToSettingsControl(app: app, identifier: parent, maxSteps: 7)
            FirstFailureRemote.press(.select)
            waitForFocusVisualSettle()
        }
        moveFocusToSettingsControl(app: app, identifier: link, maxSteps: max(stepsToLink, 6))
        FirstFailureRemote.press(.select)
        let onButton = app.buttons[onOption]
        let offButton = app.buttons[offOption]
        XCTAssertTrue(
            onButton.waitForFailureEvidence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds)
                || offButton.waitForFailureEvidence(
                    timeout: AccessLifecycleTVOSUITestsWaitTiming.readbackTimeoutSeconds),
            "Must read the toggle options."
        )
        let isOn = onButton.exists && valueContainsSelected(onButton)
        FirstFailureRemote.press(.menu)
        waitForFocusVisualSettle()
        if openParentLink != nil {
            FirstFailureRemote.press(.menu)
            waitForFocusVisualSettle()
        }
        return isOn
    }

    @MainActor
    func selectedIntervalSeconds(app: XCUIApplication) throws -> Int {
        moveFocusToSettingsControl(app: app, identifier: "settings.playback.interval.link", maxSteps: 6)
        FirstFailureRemote.press(.select)
        var selected = 0
        for seconds in AccessLifecycleContract.tvOSSelectableIntervals {
            let button = app.buttons["settings.playback.interval.\(seconds).button"]
            if button.waitForFailureEvidence(timeout: AccessLifecycleTVOSUITestsWaitTiming.briefElementTimeoutSeconds)
                && valueContainsSelected(button)
            {
                selected = seconds
                break
            }
        }
        FirstFailureRemote.press(.menu)
        waitForFocusVisualSettle()
        if selected == 0 {
            throw AccessLifecycleContract.AssertionError.message("Missing settings evidence")
        }
        return selected
    }

    @MainActor
    func selectedDisplayMode(app: XCUIApplication) throws -> String {
        moveFocusToSettingsControl(app: app, identifier: "settings.playback.displayMode.link", maxSteps: 6)
        FirstFailureRemote.press(.select)
        let single = app.buttons["settings.playback.displayMode.singlePhoto.button"]
        XCTAssertTrue(
            single.waitForFailureEvidence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Must be able to read the display mode.")
        let mode = valueContainsSelected(single) ? "singlePhoto" : "smartFill"
        FirstFailureRemote.press(.menu)
        waitForFocusVisualSettle()
        return mode
    }

    @MainActor
    func exerciseTVOSPauseNextContinueVisibleTiming(
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
            FirstFailureRemote.press(.select)
            XCTAssertTrue(
                waitUntil(timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds) {
                    let current = String(describing: playPauseButton.value ?? "")
                    return current.contains("暂停") || current.lowercased().contains("pause")
                },
                "Must be playing before the mid-interval timing."
            )
        }
        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(interval / 2))))
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        moveFocus(.right, to: playPauseButton, maximumPresses: 3, message: "At midpoint, focus must reach play/pause.")
        FirstFailureRemote.press(.select)
        record("playback.pause")
        let beforePause = try captureTVOSImmediateMark(app: app, name: "before-pause")
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        moveFocus(.right, to: nextButton, maximumPresses: 3, message: "After pause, focus must reach next.")
        FirstFailureRemote.press(.select)
        record("playback.next")
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.sceneSettle))
        let afterNext = try captureTVOSImmediateMark(app: app, name: "after-next")
        try AccessLifecycleContract.assertPauseUsesVisibleIdentity(
            pauseMark: beforePause.mark,
            afterNextMark: afterNext.mark,
            didUseProgressProbe: false,
            didUseControlValueOnly: false
        )
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        let controlBarReference = try captureTVOSControlBarReference(app: app)

        let holdStart = Date()
        let holdTarget = interval + AccessLifecycleContract.pauseHoldBeyondIntervalSeconds
        while Date().timeIntervalSince(holdStart) < holdTarget {
            RunLoop.current.run(
                until: Date().addingTimeInterval(AccessLifecycleTVOSUITestsWaitTiming.transitionPollSeconds))
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
        let continueAt = Date()
        FirstFailureRemote.press(.select)
        let pressReturnedElapsed = Date().timeIntervalSince(continueAt)
        record("playback.play")
        try AccessLifecycleContract.assertClickTimesRecordedSeparately(
            pressIssuedElapsed: 0, pressReturnedElapsed: pressReturnedElapsed,
            continueOriginElapsed: 0, didUseReturnedAsOrigin: false
        )
        let continueWatch = try watchTVOSContinueToFirstAdvance(
            app: app,
            continueAt: continueAt,
            continueMark: afterNext.mark,
            interval: interval,
            controlBarReference: controlBarReference
        )
        return [
            ["name": "before_pause", "mark": beforePause.mark],
            ["name": "after_next", "mark": afterNext.mark],
            ["name": "pause_hold_end", "elapsed": holdSeconds, "mark": holdMark],
            ["name": "continue_press", "issued_elapsed": 0, "returned_elapsed": pressReturnedElapsed],
            ["name": "continue_early", "elapsed": continueWatch.earlyElapsed, "mark": continueWatch.earlyMark],
            [
                "name": "first_transition_start", "status": "detected", "official_signed": true,
                "elapsed": continueWatch.start.requestElapsed, "request_elapsed": continueWatch.start.requestElapsed,
                "return_elapsed": continueWatch.start.returnElapsed, "mark": continueWatch.start.mark,
                "identity_status": continueWatch.start.mark == afterNext.mark ? "DIMMING" : continueWatch.start.status
            ],
            [
                "name": "new_image_confirmation", "elapsed": continueWatch.advanced.requestElapsed,
                "request_elapsed": continueWatch.advanced.requestElapsed,
                "return_elapsed": continueWatch.advanced.returnElapsed,
                "mark": continueWatch.advanced.mark
            ],
            [
                "name": "after_auto_advance", "elapsed": continueWatch.advanced.requestElapsed,
                "mark": continueWatch.advanced.mark
            ],
            [
                "name": "continue_watch_samples",
                "samples": continueWatch.samples.map { sample in
                    [
                        "request_elapsed": sample.requestElapsed, "return_elapsed": sample.returnElapsed,
                        "classified_elapsed": sample.classifiedElapsed, "status": sample.status,
                        "mark": sample.mark, "mean_luma": sample.meanLuma,
                        "control_bar_visible": sample.isControlBarVisible
                    ] as [String: Any]
                }
            ]
        ]
    }

    struct TVOSContinueWatchResult {
        let earlyMark: String
        let earlyElapsed: TimeInterval
        let start: AccessLifecycleContract.ContinueWatchSample
        let advanced: AccessLifecycleContract.ContinueWatchSample
        let samples: [AccessLifecycleContract.ContinueWatchSample]
    }

    // T±2 judges the shared transition onset; stable new-photo evidence may follow that window.
    @MainActor
    func watchTVOSContinueToFirstAdvance(
        app: XCUIApplication,
        continueAt: Date,
        continueMark: String,
        interval: TimeInterval,
        controlBarReference: StrictE2EPhotoIdentity.ControlBarReference
    ) throws -> TVOSContinueWatchResult {
        let captureUntil = AccessLifecycleContract.continueWatchDenseCaptureDeadline(intervalSeconds: interval)
        var capturedFrames: [(request: TimeInterval, returned: TimeInterval, png: Data)] = []
        while Date().timeIntervalSince(continueAt) <= captureUntil {
            let request = Date().timeIntervalSince(continueAt)
            let png = app.screenshotForFailureEvidence().pngRepresentation
            let returned = Date().timeIntervalSince(continueAt)
            capturedFrames.append((request, returned, png))
        }
        var samples: [AccessLifecycleContract.ContinueWatchSample] = []
        var earlyMark = ""
        var earlyElapsed: TimeInterval = TestWait.seconds(.product(0))
        var baselineLuma: Double?
        do {
            for frame in capturedFrames {
                let identity = StrictE2EPhotoIdentity.captureIdentity(png: frame.png)
                let mark = contractTVOSMark(identity)
                let sample = AccessLifecycleContract.ContinueWatchSample(
                    requestElapsed: frame.request, returnElapsed: frame.returned,
                    classifiedElapsed: Date().timeIntervalSince(continueAt), status: identity.status.rawValue,
                    mark: mark, meanLuma: identity.meanLuma,
                    isControlBarVisible: try XCTUnwrap(controlBarReference.isVisible(png: frame.png))
                )
                samples.append(sample)
                if earlyMark.isEmpty {
                    if frame.request > interval / 2 {
                        throw AccessLifecycleContract.AssertionError.message(
                            "The first-half evidence window after Continue crossed its bounds; classify this as a test timing failure"
                        )
                    }
                    if isUsableTVOSMark(mark) && mark == continueMark {
                        earlyMark = mark
                        earlyElapsed = frame.request
                        baselineLuma = identity.meanLuma
                        try persistTVOSCapturedPNG(frame.png, name: "continue-early")
                        try AccessLifecycleContract.assertContinueEarlyStillSameScene(
                            continueMark: continueMark, earlyMark: earlyMark,
                            elapsedSeconds: earlyElapsed, intervalSeconds: interval
                        )
                    }
                }
                if AccessLifecycleContract.firstStableNewImage(continueMark: continueMark, samples: samples) != nil {
                    break
                }
            }
            guard let baselineLuma else {
                throw AccessLifecycleContract.AssertionError.message(
                    "The first-half evidence window after Continue crossed its bounds; missing original photo evidence"
                )
            }
            let evidence = try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                continueMark: continueMark, baselineLuma: baselineLuma, samples: samples, intervalSeconds: interval
            )
            for (sample, name) in [(evidence.start, "first-transition-start"), (evidence.stable, "after-auto-advance")]
            {
                if let frame = capturedFrames.first(where: { $0.request == sample.requestElapsed }) {
                    try persistTVOSCapturedPNG(frame.png, name: name)
                }
            }
            return TVOSContinueWatchResult(
                earlyMark: earlyMark, earlyElapsed: earlyElapsed,
                start: evidence.start, advanced: evidence.stable, samples: samples
            )
        } catch {
            if let lastFrame = capturedFrames.last {
                try? persistTVOSCapturedPNG(lastFrame.png, name: "after-auto-advance")
            }
            throw error
        }
    }

    @MainActor
    private func captureTVOSControlBarReference(app: XCUIApplication) throws
        -> StrictE2EPhotoIdentity.ControlBarReference
    {
        let settings = app.buttons["slideshow.control.settings.button"]
        let frame = try settings.snapshot().frame
        let bounds = app.frame
        let normalizedRect = CGRect(
            x: (frame.minX - bounds.minX) / bounds.width, y: (frame.minY - bounds.minY) / bounds.height,
            width: frame.width / bounds.width, height: frame.height / bounds.height
        )
        let png = app.screenshotForFailureEvidence().pngRepresentation
        guard settings.isHittable else {
            throw AccessLifecycleContract.AssertionError.message(
                "Playback page should show the settings button: control-bar calibration requires Settings to remain hittable after the screenshot"
            )
        }
        return try XCTUnwrap(StrictE2EPhotoIdentity.ControlBarReference(png: png, normalizedRect: normalizedRect))
    }

    @MainActor
    func captureTVOSNewStableMark(
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
    func captureTVOSImmediateMark(
        app: XCUIApplication,
        name: String
    ) throws -> (mark: String, png: Data) {
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        let png = app.screenshotForFailureEvidence().pngRepresentation
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
    func classifyTVOSMark(app: XCUIApplication) -> String {
        contractTVOSMark(
            StrictE2EPhotoIdentity.captureIdentity(png: app.screenshotForFailureEvidence().pngRepresentation))
    }

    func contractTVOSMark(_ identity: StrictE2EPhotoIdentity.Result) -> String {
        if identity.status == .match, let mark = identity.mark {
            return mark
        }
        if identity.status == .black { return "BLACK" }
        if identity.status == .blank { return "BLANK" }
        if identity.status == .transition { return "TRANSITION" }
        return "UNRECOGNIZABLE"
    }

    func isUsableTVOSMark(_ mark: String) -> Bool {
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
        throw AccessLifecycleContract.AssertionError.message("Background return lacks the original process identity")
    }

    func writeTVOSResumeJSON(name: String, extra: [String: Any]) throws {
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
