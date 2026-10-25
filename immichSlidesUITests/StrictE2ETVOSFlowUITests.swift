import XCTest

#if os(tvOS)
final class StrictE2ETVOSFlowUITests: XCTestCase {
    override func invokeTest() {
        FirstFailureContext.reset()
        super.invokeTest()
    }

    override func record(_ issue: XCTIssue) {
        FirstFailureEvidence.record(self, issue: issue)
        super.record(issue)
    }

    private enum Timing {
        static let focusPollingSeconds: TimeInterval = TestWait.seconds(.product(0.1))
        static let playbackSceneSettleSeconds: TimeInterval = TestWait.seconds(.product(3.5))
        static let autoPlayObservationSeconds: TimeInterval = TestWait.seconds(.product(6))
        static let minimumPauseEvidenceSeconds: TimeInterval = TestWait.seconds(.product(10))
        static let pausedPlaybackObservationSeconds: TimeInterval = TestWait.seconds(.product(10.5))
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTVOSFirstBootSaveAndConfiguredColdLaunch() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The full tvOS flow must run on a tvOS Simulator.")
            return
        }

        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminateForFailureEvidence() }

        try configureServerThroughFirstBoot(app: app, input: input)

        let randomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(
            randomButton.waitForPublicElement("mode.random.button", timeout: TestWait.seconds(.product(15))),
            "After saving settings, the app must reach the mode selection page."
        )
        XCTAssertTrue(
            waitForFocus(on: randomButton, timeout: TestWait.seconds(.product(5))),
            "Default focus on the mode selection page must land on random playback."
        )
        attachScreenshot(app: app, name: "tvos-cold-launch-01-mode-selection-default-focus")

        app.terminateForFailureEvidence()
        app.launchForFailureEvidence()

        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForPublicElement(
                "firstboot.serverURL.field", timeout: TestWait.seconds(.product(3))),
            "A cold launch with saved settings must not return to the first-boot form."
        )
        var didSendWake = false
        XCTAssertTrue(
            waitForColdLaunchControls(app: app, timeout: TestWait.seconds(.product(30)), didSendWake: &didSendWake),
            "A configured cold launch must go straight to the playback page."
        )
        XCTAssertTrue(
            waitForColdLaunchFocus(app: app, timeout: TestWait.seconds(.product(8)), didSendWake: &didSendWake),
            "Default focus on the cold-launch playback page must land on the Play/Pause button."
        )
        attachScreenshot(app: app, name: "tvos-cold-launch-02-configured-slideshow")
    }

    // Seam: tvOS adds only HTML 200. The public error must be readable, and the app stays on the connection
    // page without saving by mistake.
    @MainActor
    func testTVOSAlbumServerFirstBootFailureHTML200() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The full tvOS flow must run on a tvOS Simulator.")
            return
        }
        let scenario = ProcessInfo.processInfo.environment["STRICT_E2E_INPUT_SCENARIO"] ?? ""
        XCTAssertEqual(scenario, "html-200", "The extra tvOS failure check runs only HTML 200.")
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminateForFailureEvidence() }

        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForPublicElement(
                "firstboot.serverURL.field", timeout: TestWait.seconds(.infrastructure(12))),
            "A clean install must reach the first-boot form.")
        replaceFocusedText(in: serverField, app: app, with: input.serverURL)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForPublicElement("firstboot.apiKey.field", timeout: TestWait.seconds(.infrastructure(8))),
            "The first-boot form must show the API Key field.")
        moveFocus(
            .down,
            to: apiKeyField,
            maximumPresses: 2,
            message: "After submitting the URL, focus must be able to move down to API Key."
        )
        replaceFocusedText(in: apiKeyField, app: app, with: input.publicKey)

        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(
            testConnectionButton.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(5))),
            "The first-boot form must show the Test Connection button."
        )
        FirstFailureRemote.press(.down)
        FirstFailureRemote.press(.right)
        FirstFailureRemote.press(.select)

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let alert = app.alerts.firstMatch
        let failureAppeared = waitUntil(timeout: TestWait.seconds(.product(30))) {
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            alert.exists
                || app.staticTexts.containing(
                    // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                    NSPredicate(format: "label CONTAINS %@", "不是 JSON")
                ).firstMatch.exists
                || app.staticTexts.containing(
                    // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                    NSPredicate(format: "label CONTAINS %@", "填错了 Immich")
                ).firstMatch.exists
        }
        XCTAssertTrue(failureAppeared, "HTML 200 must show an actionable error message.")
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let texts =
            ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label)
            + app.staticTexts.allElementsBoundByIndex.prefix(12).map(\.label))
            .joined(separator: " | ")
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        XCTAssertTrue(
            texts.contains("不是 JSON") || texts.contains("填错了 Immich"),
            "HTML 200 must say the address/entry point is wrong, actual: \(texts)"
        )
        attachScreenshot(app: app, name: "tvos-firstboot-failure-html-200")
        if alert.exists {
            FirstFailureRemote.press(.select)
        }
        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            saveButton.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "After the failure, the app must still be on the connection page."
        )
        XCTAssertFalse(saveButton.isEnabled, "A failed connection test must not save by mistake.")
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
        attachScreenshot(app: app, name: "tvos-firstboot-failure-html-200-after-relaunch")
    }

    @MainActor
    func testTVOSFirstBootModeSelectionAndCorePlayback() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The full tvOS flow must run on a tvOS Simulator.")
            return
        }

        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp(recordSceneSequence: true)
        defer { app.terminateForFailureEvidence() }

        try configureServerThroughFirstBoot(app: app, input: input)

        let randomButton = app.buttons["mode.random.button"]
        let filteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(
            randomButton.waitForPublicElement("mode.random.button", timeout: TestWait.seconds(.product(15))),
            "After saving settings, the app must reach the mode selection page."
        )
        XCTAssertTrue(
            waitForFocus(on: randomButton, timeout: TestWait.seconds(.product(5))),
            "Default focus on the mode selection page must land on random playback."
        )
        moveFocus(
            .right,
            to: filteredButton,
            maximumPresses: 2,
            message: "Focus on the mode page must be able to move to filtered playback."
        )
        FirstFailureRemote.press(.select)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForPublicElement("mode.continue.button", timeout: TestWait.seconds(.product(5))),
            "After choosing filtered playback, the Continue button must appear."
        )
        XCTAssertTrue(
            continueButton.isEnabled,
            "After choosing filtered playback, the Continue button must be enabled."
        )
        moveFocus(
            .down,
            to: continueButton,
            maximumPresses: 2,
            message: "After choosing a mode, focus must be able to move down to the Continue button."
        )
        FirstFailureRemote.press(.select)

        let filterSummaryBackButton = app.buttons["filterSummary.backToMode.button"]
        XCTAssertTrue(
            filterSummaryBackButton.waitForFailureEvidence(timeout: TestWait.seconds(.product(15))),
            "Filter mode must reach the filter summary page."
        )
        FirstFailureRemote.press(.right)
        FirstFailureRemote.press(.right)
        FirstFailureRemote.press(.down)
        XCTAssertTrue(
            waitForFocus(on: filterSummaryBackButton, timeout: TestWait.seconds(.product(5))),
            "Focus on the filter summary page must be able to move to Back to Mode Selection."
        )
        attachScreenshot(app: app, name: "tvos-playback-01-filter-summary-back-focused")
        FirstFailureRemote.press(.select)

        XCTAssertTrue(
            randomButton.waitForPublicElement("mode.random.button", timeout: TestWait.seconds(.product(10))),
            "Going back from the filter summary must return to the mode selection page."
        )
        XCTAssertTrue(
            waitForFocus(on: randomButton, timeout: TestWait.seconds(.product(5))),
            "After returning to mode selection, default focus must go back to random playback."
        )
        FirstFailureRemote.press(.select)
        XCTAssertTrue(continueButton.isEnabled, "After choosing random playback, the Continue button must be enabled.")
        moveFocus(
            .down,
            to: continueButton,
            maximumPresses: 2,
            message: "After choosing random playback, focus must be able to move down to the Continue button."
        )
        attachScreenshot(app: app, name: "tvos-playback-01-random-selected-continue-focused")
        FirstFailureRemote.press(.select)

        let settingsButton = app.buttons["slideshow.control.settings.button"]
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        let previousButton = app.buttons["slideshow.control.previous.button"]
        let nextButton = app.buttons["slideshow.control.next.button"]
        let entryHint = app.otherElements["slideshow.entryHint.banner"]
        let playbackEntryDeadline = Date().addingTimeInterval(TestWait.seconds(.product(30)))
        XCTAssertTrue(
            settingsButton.waitForPublicElement(
                "slideshow.control.settings.button", timeout: TestWait.seconds(.product(30))),
            "After Continue, the app must reach the playback page and show the control bar."
        )
        // Pause freezes incoming layers too; finish the initial fade within the existing entry budget.
        var previousEntryObservation: [String: String] = [:]
        var entryObservation: [String: String] = [:]
        let didReachStableEntry = TestWait.until(.product(max(0, playbackEntryDeadline.timeIntervalSinceNow))) {
            previousEntryObservation = entryObservation
            entryObservation = self.strictSceneFrameObservation(app: app)
            return StrictE2ESceneCapture.isStableWindow(entryObservation) && Date() < playbackEntryDeadline
        }
        attachStrictSceneObservation(
            before: previousEntryObservation, after: entryObservation, name: "tvos-entry-capture-window")
        XCTAssertEqual(
            didReachStableEntry, true,
            "tvOS flow entry precondition failed: initial scene did not stabilize before Pause."
        )
        // Pause before screenshots or focus travel can consume the first autoplay interval.
        let playingValue = String(describing: playPauseButton.value ?? "")
        FirstFailureRemote.press(.playPause)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(4))) {
                String(describing: playPauseButton.value ?? "") != playingValue
            },
            "Autoplay must be paused before the history chain starts."
        )
        let historyStart = captureVisualIdentity(
            app: app,
            evidenceName: "history-start",
            attachmentName: "tvos-playback-05-history-a-paused"
        )
        let startObservation = historyStart["after"] as? [String: String] ?? [:]
        let startRender = SharedSceneEvidenceManifest.parseKeyValueFields(startObservation["render"] ?? "")
        XCTAssertEqual(
            startRender["historyCount"], "1",
            "tvOS flow entry precondition failed: autoplay advanced before the initial scene was paused."
        )
        XCTAssertEqual(
            startRender["playbackPaused"], "true",
            "tvOS flow entry anchor must remain paused before checking the history boundary."
        )
        XCTAssertTrue(
            entryHint.waitForFailureEvidence(timeout: TestWait.seconds(.product(10))),
            "The first playback round must show the one-time remote hint."
        )
        XCTAssertTrue(
            waitForFocus(on: settingsButton, timeout: TestWait.seconds(.product(8))),
            "While the one-time hint is shown, default focus must land on the settings button."
        )
        XCTAssertTrue(
            previousButton.waitForPublicElement(
                "slideshow.control.previous.button", timeout: TestWait.seconds(.product(5))),
            "The playback control bar must show the previous button."
        )
        XCTAssertFalse(previousButton.isEnabled, "At the initial history boundary, previous must be disabled.")
        attachScreenshot(app: app, name: "tvos-playback-02-entry-hint-settings-focused")

        ensureControlBarVisible(app: app)
        moveFocus(
            .right,
            to: playPauseButton,
            maximumPresses: 3,
            message: "Before the history chain starts, focus must be able to move to Play/Pause."
        )

        FirstFailureRemote.press(.down)
        XCTAssertTrue(
            waitForDisappearance(of: playPauseButton, timeout: TestWait.seconds(.product(5))),
            "After pressing Down, the hint and the control bar must hide."
        )
        let wakeReceiver = app.descendants(matching: .any)["slideshow.hiddenWakeReceiver"]
        XCTAssertTrue(
            wakeReceiver.waitForFailureEvidence(timeout: TestWait.seconds(.product(5))),
            "After the control bar hides, the wake focus receiver layer must appear."
        )
        XCTAssertTrue(
            waitForFocus(on: wakeReceiver, timeout: TestWait.seconds(.product(5))),
            "Before sending the wake arrow key, the hidden receiver layer must have system focus."
        )
        FirstFailureRemote.press(.up)
        XCTAssertTrue(
            playPauseButton.waitForPublicElement(
                "slideshow.control.playPause.button", timeout: TestWait.seconds(.product(5))),
            "With the control bar hidden, an arrow key must wake it again."
        )
        attachFocusAudit(app: app, name: "tvos-playback-focus-after-control-bar-wake")
        XCTAssertTrue(
            waitForFocus(on: playPauseButton, timeout: TestWait.seconds(.product(6))),
            "After the control bar wakes again, focus must land on Play/Pause."
        )
        attachScreenshot(app: app, name: "tvos-playback-03-control-bar-wake-playpause-focused")

        ensureControlBarVisible(app: app)
        let indexProbe = app.otherElements["slideshow.control.indexProbe"]
        XCTAssertTrue(
            indexProbe.waitForFailureEvidence(timeout: TestWait.seconds(.product(5))),
            "The playback page must expose the read-only index probe."
        )
        _ = try requireIndexValue(indexProbe)
        XCTAssertTrue(
            previousButton.waitForPublicElement(
                "slideshow.control.previous.button", timeout: TestWait.seconds(.product(5))),
            "The start of the history chain must show the previous button."
        )
        XCTAssertFalse(previousButton.isEnabled, "A must be at the history start of the current playback session.")

        ensureControlBarVisible(app: app)
        moveFocus(
            .right,
            to: nextButton,
            maximumPresses: 2,
            message: "Focus must be able to move from Play/Pause to Next."
        )
        FirstFailureRemote.press(.select)
        XCTAssertTrue(
            waitForScenePublicationAdvance(
                app: app, baseline: historyStart["after"] as? [String: String] ?? [:]),
            "The first next must advance the playback cursor."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
        ensureControlBarVisible(app: app)
        let firstNext = captureVisualIdentity(
            app: app,
            evidenceName: "history-first-next",
            attachmentName: "tvos-playback-06-history-b-after-next"
        )

        ensureControlBarVisible(app: app)
        moveFocus(
            .right,
            to: nextButton,
            maximumPresses: 2,
            message: "After the first next settles, focus must be able to move to Next again."
        )
        FirstFailureRemote.press(.select)
        XCTAssertTrue(
            waitForScenePublicationAdvance(
                app: app, baseline: firstNext["after"] as? [String: String] ?? [:]),
            "The second next must advance the playback cursor further."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
        ensureControlBarVisible(app: app)
        let secondNext = captureVisualIdentity(
            app: app,
            evidenceName: "history-second-next",
            attachmentName: "tvos-playback-07-history-c-after-next"
        )

        ensureControlBarVisible(app: app)
        moveFocus(
            .left,
            to: playPauseButton,
            maximumPresses: 2,
            message: "Focus must be able to move from Next back to Play/Pause."
        )
        moveFocus(
            .left,
            to: previousButton,
            identifier: "slideshow.control.previous.button",
            maximumPresses: 2,
            message: "Once history exists, focus must be able to move to Previous."
        )
        FirstFailureRemote.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
        ensureControlBarVisible(app: app)
        _ = try requireIndexValue(indexProbe)
        XCTAssertTrue(
            previousButton.isEnabled,
            "After the first previous, one earlier history entry remains, so the button must stay enabled."
        )
        let firstPrevious = captureVisualIdentity(
            app: app,
            evidenceName: "history-first-previous",
            attachmentName: "tvos-playback-08-history-return-step-1"
        )

        ensureControlBarVisible(app: app)
        moveFocus(
            .left,
            to: previousButton,
            identifier: "slideshow.control.previous.button",
            maximumPresses: 2,
            message: "After going back once, focus must be able to move to Previous again."
        )
        FirstFailureRemote.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
        ensureControlBarVisible(app: app)
        _ = try requireIndexValue(indexProbe)
        XCTAssertTrue(
            previousButton.waitForPublicElement(
                "slideshow.control.previous.button", timeout: TestWait.seconds(.product(5))),
            "The end of the history chain must show the previous button."
        )
        XCTAssertFalse(
            previousButton.isEnabled,
            "After the second previous returns to the history start, the button must be disabled again."
        )
        let secondPrevious = captureVisualIdentity(
            app: app,
            evidenceName: "history-second-previous",
            attachmentName: "tvos-playback-09-history-return-step-2"
        )

        ensureControlBarVisible(app: app)
        moveFocus(
            .right,
            to: nextButton,
            maximumPresses: 3,
            message: "Before checking autoplay, focus must be able to move to Next."
        )
        FirstFailureRemote.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
        ensureControlBarVisible(app: app)
        _ = try requireIndexValue(indexProbe)
        moveFocus(
            .right,
            to: nextButton,
            maximumPresses: 2,
            message: "After consuming one step of forward history, focus must be able to move to Next again."
        )
        FirstFailureRemote.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
        ensureControlBarVisible(app: app)
        _ = try requireIndexValue(indexProbe)

        moveFocus(
            .left,
            to: playPauseButton,
            maximumPresses: 2,
            message: "At the history frontier, focus must be able to move to Play/Pause."
        )
        let pausedValue = String(describing: playPauseButton.value ?? "")
        FirstFailureRemote.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(4))) {
                String(describing: playPauseButton.value ?? "") != pausedValue
            },
            "Pressing Select after pausing must resume autoplay."
        )
        let autoPlayBaseline = strictSceneFrameObservation(app: app)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.autoPlayObservationSeconds))
        ensureControlBarVisible(app: app)
        XCTAssertTrue(
            waitForFocus(on: playPauseButton, timeout: TestWait.seconds(.product(6))),
            "After auto-advance, focus on wake must return to Play/Pause."
        )
        XCTAssertTrue(
            waitForScenePublicationAdvance(
                app: app, baseline: autoPlayBaseline),
            "The index probe must change after a playback action."
        )
        let publicationAfterAutoPlay = scenePublication(in: strictSceneFrameObservation(app: app))
        XCTAssertNotNil(publicationAfterAutoPlay, "The index probe must change after a playback action.")
        attachScreenshot(app: app, name: "tvos-playback-10-auto-advanced-visible-frame")

        ensureControlBarVisible(app: app)
        XCTAssertTrue(
            waitForFocus(on: playPauseButton, timeout: TestWait.seconds(.product(6))),
            "After auto-advance, focus on wake must return to Play/Pause."
        )
        let resumedValue = String(describing: playPauseButton.value ?? "")
        FirstFailureRemote.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(4))) {
                String(describing: playPauseButton.value ?? "") != resumedValue
            },
            "Pressing Select after auto-advance must pause playback."
        )
        let pauseStartedAt = Date()
        let pausedControlValue = String(describing: playPauseButton.value ?? "")
        XCTAssertEqual(
            scenePublication(in: strictSceneFrameObservation(app: app)),
            publicationAfterAutoPlay,
            "Pausing must not advance an extra photo."
        )
        let pauseImmediate = captureVisualIdentity(
            app: app,
            evidenceName: "pause-immediate",
            attachmentName: "tvos-playback-11-pause-immediate-visible-frame"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.pausedPlaybackObservationSeconds))
        ensureControlBarVisible(app: app)
        let pauseVerifiedAt = Date()
        let pauseElapsedSeconds = pauseVerifiedAt.timeIntervalSince(pauseStartedAt)
        XCTAssertGreaterThanOrEqual(
            pauseElapsedSeconds,
            Timing.minimumPauseEvidenceSeconds,
            "The paused-frame comparison must span at least 10 seconds."
        )
        XCTAssertEqual(
            scenePublication(in: strictSceneFrameObservation(app: app)),
            publicationAfterAutoPlay,
            "During a pause of at least 10 seconds, autoplay must not catch up."
        )
        XCTAssertTrue(
            waitForFocus(on: playPauseButton, timeout: TestWait.seconds(.product(6))),
            "After the pause wait, focus on wake must return to Play/Pause."
        )
        let pauseHeld = captureVisualIdentity(
            app: app,
            evidenceName: "pause-after-10s",
            attachmentName: "tvos-playback-12-pause-after-10-seconds-visible-frame"
        )
        ensureControlBarVisible(app: app)
        XCTAssertTrue(
            waitForFocus(on: playPauseButton, timeout: TestWait.seconds(.product(6))),
            "After the pause wait, focus on wake must return to Play/Pause."
        )
        let retainedPausedValue = String(describing: playPauseButton.value ?? "")
        let pauseEvidence = XCTAttachment(
            string: """
                pauseStartedAtUnixSeconds=\(pauseStartedAt.timeIntervalSince1970)
                pauseVerifiedAtUnixSeconds=\(pauseVerifiedAt.timeIntervalSince1970)
                pauseElapsedSeconds=\(pauseElapsedSeconds)
                pausedControlValue=\(pausedControlValue)
                verifiedControlValue=\(retainedPausedValue)
                """
        )
        pauseEvidence.name = "tvos-playback-pause-state-and-timing"
        pauseEvidence.lifetime = .keepAlways
        add(pauseEvidence)

        FirstFailureRemote.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(4))) {
                String(describing: playPauseButton.value ?? "") != retainedPausedValue
            },
            "After the pause wait, autoplay must be resumable."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.autoPlayObservationSeconds))
        ensureControlBarVisible(app: app)
        XCTAssertTrue(
            waitForFocus(on: playPauseButton, timeout: TestWait.seconds(.product(6))),
            "After autoplay resumes, focus on wake must return to Play/Pause."
        )
        XCTAssertTrue(
            waitForScenePublicationAdvance(
                app: app,
                baseline: pauseHeld["after"] as? [String: String] ?? [:],
                requiresStableCaptureWindow: true
            ),
            "After resuming, playback must advance to another photo."
        )
        let resumed = captureVisualIdentity(
            app: app,
            evidenceName: "resumed",
            attachmentName: "tvos-playback-13-resumed-advanced-visible-frame"
        )
        StrictE2EVisualEvidence.writeJSON(
            [
                "suite": "tvos-flow",
                "history": [
                    historyStart, firstNext, secondNext, firstPrevious, secondPrevious
                ],
                "pause_immediate": pauseImmediate,
                "pause_after_10s": pauseHeld,
                "resumed": resumed
            ],
            name: "visual-identity.json"
        )

        ensureControlBarVisible(app: app)
        XCTAssertTrue(
            waitForFocus(on: playPauseButton, timeout: TestWait.seconds(.product(6))),
            "After autoplay resumes, focus on wake must return to Play/Pause."
        )
        let finalPlayingValue = String(describing: playPauseButton.value ?? "")
        FirstFailureRemote.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(4))) {
                String(describing: playPauseButton.value ?? "") != finalPlayingValue
            },
            "Autoplay must be pausable again before entering settings."
        )
        moveFocus(
            .left,
            to: settingsButton,
            maximumPresses: 4,
            message: "Focus in the playback control bar must be able to move to Settings."
        )
        FirstFailureRemote.press(.select)
        XCTAssertTrue(
            app.buttons["settings.item.playback"].waitForPublicElement(
                "settings.item.playback", timeout: TestWait.seconds(.product(8))),
            "The settings button must open the settings page."
        )
        FirstFailureRemote.press(.menu)
        XCTAssertTrue(
            settingsButton.waitForPublicElement(
                "slideshow.control.settings.button", timeout: TestWait.seconds(.product(8))),
            "Pressing Back/Menu on the settings page must return to the playback page."
        )
    }

    @MainActor
    private func configureServerThroughFirstBoot(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForPublicElement(
                "firstboot.serverURL.field", timeout: TestWait.seconds(.infrastructure(12))),
            "A clean install must reach the first-boot form.")
        replaceFocusedText(in: serverField, app: app, with: input.serverURL)

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForPublicElement("firstboot.apiKey.field", timeout: TestWait.seconds(.infrastructure(8))),
            "The first-boot form must show the API Key field.")
        moveFocus(
            .down,
            to: apiKeyField,
            maximumPresses: 2,
            message: "After submitting the URL, focus must be able to move down to API Key."
        )
        replaceFocusedText(in: apiKeyField, app: app, with: input.publicKey)

        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(
            testConnectionButton.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(5))),
            "The first-boot form must show the Test Connection button."
        )
        FirstFailureRemote.press(.down)
        FirstFailureRemote.press(.right)
        attachFocusAudit(app: app, name: "tvos-firstboot-focus-before-test-connection")
        FirstFailureRemote.press(.select)

        let success = app.staticTexts["firstboot.connection.success"]
        XCTAssertTrue(
            success.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(45))),
            "Once the real controlled service is reachable, the connection-test-passed status must show."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["server.apiKey.help.sheet"].exists,
            "Select must not accidentally hit the API Key help sheet."
        )

        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            saveButton.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(5))),
            "After a successful connection, the Save Settings button must appear."
        )
        XCTAssertTrue(saveButton.isEnabled, "After a successful connection, Save Settings must be enabled.")
        attachFocusAudit(app: app, name: "tvos-firstboot-focus-before-save")
        attachScreenshot(app: app, name: "tvos-firstboot-connection-success-save-focused")
        FirstFailureRemote.press(.select)
    }

    @MainActor
    private func replaceFocusedText(in field: XCUIElement, app: XCUIApplication, with value: String) {
        XCTAssertTrue(
            waitForFocus(on: field, timeout: TestWait.seconds(.product(4))), "The field must be focused before typing.")
        FirstFailureRemote.press(.select)
        app.typeForFailureEvidence(value)

        let submit = app.buttons.matching(
            // ui-label-lookup: Match the simulator-localized system keyboard submit key.
            NSPredicate(format: "label IN %@", ["下一项", "Next", "完成", "Done"])
        ).firstMatch
        XCTAssertTrue(
            submit.waitForFailureEvidence(timeout: TestWait.seconds(.product(4))),
            "The system keyboard must show Next or Done.")
        for _ in 0..<6 where !submit.hasFocus {
            FirstFailureRemote.press(.down)
        }
        XCTAssertTrue(submit.hasFocus, "Focus the system keyboard submit button before submitting text.")
        FirstFailureRemote.press(.select)
        FirstFailureRemote.press(.menu)

        if field.identifier == "firstboot.serverURL.field" {
            XCTAssertEqual(field.value as? String, value, "The server address must be submitted verbatim.")
        }
        XCTAssertTrue(
            waitForFocus(on: field, timeout: TestWait.seconds(.product(4))),
            "After submitting text, focus must return to the original field."
        )
    }

    @MainActor
    private func moveFocus(
        _ direction: XCUIRemote.Button,
        to element: XCUIElement,
        identifier: String? = nil,
        maximumPresses: Int,
        message: String
    ) {
        var identifier = identifier
        for _ in 0..<maximumPresses {
            if identifier == nil { identifier = (try? element.snapshot())?.identifier }
            let snapshots = XCUIApplication().evidenceSnapshotsByIdentifier()
            if let identifier, let target = snapshots[identifier] {
                // Previous is reachable only while the current retained history has an earlier entry.
                if target.identifier == "slideshow.control.previous.button", !target.isEnabled { break }
                if target.hasFocus { return }
            }
            _ = XCUIApplication().pressAndWaitForTVOSFocusMovement(
                direction, to: identifier, timeout: TestWait.seconds(.product(1)))
        }
        XCTAssertTrue(
            waitForFocus(on: element, identifier: identifier, timeout: TestWait.seconds(.product(4))), message)
    }

    @MainActor
    private func waitForFocus(on element: XCUIElement, identifier: String? = nil, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var identifier = identifier
        while Date() < deadline {
            if identifier == nil { identifier = (try? element.snapshot())?.identifier }
            let snapshots = XCUIApplication().evidenceSnapshotsByIdentifier()
            if let identifier, let target = snapshots[identifier], target.hasFocus {
                if target.identifier == "slideshow.control.previous.button", !target.isEnabled { return false }
                return Date() < deadline
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPollingSeconds))
        }
        return false
    }

    @MainActor
    private func waitForColdLaunchControls(
        app: XCUIApplication, timeout: TimeInterval, didSendWake: inout Bool
    ) -> Bool {
        FirstFailureContext.beginWait(seconds: timeout)
        defer {
            FirstFailureContext.endWait()
            attachColdLaunchWakePath(phase: "controls", didSendWake: didSendWake)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshots = app.evidenceSnapshotsByIdentifier()
            guard Date() < deadline else { return false }
            if snapshots["slideshow.control.playPause.button"] != nil { return true }
            if !didSendWake && snapshots["slideshow.hiddenWakeReceiver"]?.hasFocus == true {
                FirstFailureRemote.press(.up)
                didSendWake = true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPollingSeconds))
        }
        return false
    }

    @MainActor
    private func waitForColdLaunchFocus(
        app: XCUIApplication, timeout: TimeInterval, didSendWake: inout Bool
    ) -> Bool {
        FirstFailureContext.beginWait(seconds: timeout)
        defer {
            FirstFailureContext.endWait()
            attachColdLaunchWakePath(phase: "focus", didSendWake: didSendWake)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshots = app.evidenceSnapshotsByIdentifier()
            guard Date() < deadline else { return false }
            if snapshots["slideshow.control.playPause.button"]?.hasFocus == true { return true }
            if !didSendWake && snapshots["slideshow.hiddenWakeReceiver"]?.hasFocus == true {
                FirstFailureRemote.press(.up)
                didSendWake = true
            }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(Timing.focusPollingSeconds)))
        }
        return false
    }

    private func attachColdLaunchWakePath(phase: String, didSendWake: Bool) {
        let attachment = XCTAttachment(string: "phase=\(phase);didSendWake=\(didSendWake)")
        attachment.name = "cold-launch-\(phase)-wake-path"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { !element.exists }
    }

    @MainActor
    private func ensureControlBarVisible(app: XCUIApplication) {
        XCTAssertTrue(
            app.refreshTVOSSlideshowControlBar(timeout: TestWait.seconds(.product(5))),
            "An arrow key must wake the playback control bar.")
    }

    private func requireIndexValue(_ indexProbe: XCUIElement) throws -> String {
        let value = String(describing: indexProbe.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(
            value.isEmpty ? nil : value,
            "The playback index probe is empty, so autoplay and retained-history cannot be proven."
        )
    }

    private struct ScenePublication: Equatable {
        let actionTimestamp: TimeInterval
        let publishedTimestamp: TimeInterval
    }

    private func scenePublication(in observation: [String: String]) -> ScenePublication? {
        let fields = SharedSceneEvidenceManifest.parseKeyValueFields(observation["manifest"] ?? "")
        guard let action = Double(fields["actionTimestamp"] ?? ""),
            let published = Double(fields["scenePublishTimestamp"] ?? ""),
            action.isFinite, published.isFinite, action > 0, published >= action
        else { return nil }
        return ScenePublication(actionTimestamp: action, publishedTimestamp: published)
    }

    @MainActor
    private func waitForScenePublicationAdvance(
        app: XCUIApplication,
        baseline: [String: String],
        requiresStableCaptureWindow: Bool = false
    ) -> Bool {
        let guardWait = TestWait.hangGuard()
        let baselinePublication = scenePublication(in: baseline)
        let baselineFields = SharedSceneEvidenceManifest.parseKeyValueFields(baseline["manifest"] ?? "")
        let isInitialPublication =
            baselineFields["publishReason"] == "initial"
            && baselineFields["actionTimestamp"] == nil && baselineFields["scenePublishTimestamp"] == nil
        var advanceObservation: [String: String] = [:]
        var previousObservation: [String: String] = [:]
        var lastObservation: [String: String] = [:]
        var didObserveAdvance = false
        let didObserve = guardWait.transaction().until(pollIntervalSeconds: Timing.focusPollingSeconds) {
            previousObservation = lastObservation
            lastObservation = strictSceneFrameObservation(app: app)
            // The displayed index saturates at the pool size; repeated photos still publish new timing.
            let publication = scenePublication(in: lastObservation)
            let didPublish =
                publication.map { current in
                    baselinePublication.map { previous in
                        current.actionTimestamp > previous.actionTimestamp
                            && current.publishedTimestamp > previous.publishedTimestamp
                    } ?? isInitialPublication
                } ?? false
            if !didObserveAdvance && didPublish {
                didObserveAdvance = true
                advanceObservation = lastObservation
            }
            return didObserveAdvance
                && (!requiresStableCaptureWindow || StrictE2ESceneCapture.isStableWindow(lastObservation))
        }
        if didObserve {
            attachStrictSceneObservation(
                before: baseline, after: advanceObservation, name: "tvos-scene-publication-advance")
            attachStrictSceneObservation(
                before: previousObservation, after: lastObservation, name: "tvos-resume-capture-window")
            return true
        }
        attachStrictSceneObservation(
            before: baseline, after: advanceObservation, name: "tvos-scene-publication-advance")
        attachStrictSceneObservation(
            before: previousObservation, after: lastObservation, name: "tvos-resume-capture-window-timeout")
        XCTFail(
            "The index probe must change after a playback action. advanceObserved=\(didObserveAdvance) \(strictSceneCaptureDiagnostic(before: previousObservation, after: lastObservation, stable: StrictE2ESceneCapture.isStableWindow(lastObservation)))"
        )
        return false
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        FirstFailureContext.beginWait(seconds: timeout)
        defer { FirstFailureContext.endWait() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPollingSeconds))
        }
        return condition()
    }

    private func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshotForFailureEvidence())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func captureVisualIdentity(
        app: XCUIApplication,
        evidenceName: String,
        attachmentName: String
    ) -> [String: Any] {
        captureStrictSceneFrame(app: app, name: evidenceName, attachmentName: attachmentName)
    }

    private func attachFocusAudit(app: XCUIApplication, name: String) {
        let focused = app.descendants(matching: .any).allElementsBoundByIndex.filter(\.hasFocus)
        let lines = focused.map { element in
            "type=\(element.elementType.rawValue) id=\(element.identifier) label=\(element.label) frame=\(element.frame)"
        }
        let attachment = XCTAttachment(string: lines.isEmpty ? "no-focused-element" : lines.joined(separator: "\n"))
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
        let identifiedElement = app.descendants(matching: .any)[identifier]
        if identifiedElement.exists { return identifiedElement }
        return identifiedElement
    }
}
#endif
