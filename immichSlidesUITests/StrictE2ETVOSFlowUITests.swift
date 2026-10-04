import XCTest

#if os(tvOS)
final class StrictE2ETVOSFlowUITests: XCTestCase {
    private enum Timing {
        static let focusMovementSettleSeconds: TimeInterval = 0.15
        static let focusPollingSeconds: TimeInterval = 0.1
        static let playbackSceneSettleSeconds: TimeInterval = 3.5
        static let autoPlayObservationSeconds: TimeInterval = 6
        static let minimumPauseEvidenceSeconds: TimeInterval = 10
        static let pausedPlaybackObservationSeconds: TimeInterval = 10.5
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
        defer { app.terminate() }

        try configureServerThroughFirstBoot(app: app, input: input)

        let randomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(
            randomButton.waitForExistence(timeout: 15),
            "After saving settings, the app must reach the mode selection page."
        )
        XCTAssertTrue(
            waitForFocus(on: randomButton, timeout: 5),
            "Default focus on the mode selection page must land on random playback."
        )
        attachScreenshot(app: app, name: "tvos-cold-launch-01-mode-selection-default-focus")

        app.terminate()
        app.launch()

        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 3),
            "A cold launch with saved settings must not return to the first-boot form."
        )
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: 30),
            "A configured cold launch must go straight to the playback page."
        )
        XCTAssertTrue(
            waitForFocus(on: playPauseButton, timeout: 8),
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
        defer { app.terminate() }

        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 12), "A clean install must reach the first-boot form.")
        replaceFocusedText(in: serverField, app: app, with: input.serverURL)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 8), "The first-boot form must show the API Key field.")
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
            testConnectionButton.waitForExistence(timeout: 5),
            "The first-boot form must show the Test Connection button."
        )
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let alert = app.alerts.firstMatch
        let failureAppeared = waitUntil(timeout: 30) {
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
            XCUIRemote.shared.press(.select)
        }
        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 8),
            "After the failure, the app must still be on the connection page."
        )
        XCTAssertFalse(saveButton.isEnabled, "A failed connection test must not save by mistake.")
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
        attachScreenshot(app: app, name: "tvos-firstboot-failure-html-200-after-relaunch")
    }

    @MainActor
    func testTVOSFirstBootModeSelectionAndCorePlayback() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The full tvOS flow must run on a tvOS Simulator.")
            return
        }

        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try configureServerThroughFirstBoot(app: app, input: input)

        let randomButton = app.buttons["mode.random.button"]
        let filteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(
            randomButton.waitForExistence(timeout: 15),
            "After saving settings, the app must reach the mode selection page."
        )
        XCTAssertTrue(
            waitForFocus(on: randomButton, timeout: 5),
            "Default focus on the mode selection page must land on random playback."
        )
        moveFocus(
            .right,
            to: filteredButton,
            maximumPresses: 2,
            message: "Focus on the mode page must be able to move to filtered playback."
        )
        XCUIRemote.shared.press(.select)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 5),
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
        XCUIRemote.shared.press(.select)

        let filterSummaryBackButton = app.buttons["filterSummary.backToMode.button"]
        XCTAssertTrue(
            filterSummaryBackButton.waitForExistence(timeout: 15),
            "Filter mode must reach the filter summary page."
        )
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(
            waitForFocus(on: filterSummaryBackButton, timeout: 5),
            "Focus on the filter summary page must be able to move to Back to Mode Selection."
        )
        attachScreenshot(app: app, name: "tvos-playback-01-filter-summary-back-focused")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            randomButton.waitForExistence(timeout: 10),
            "Going back from the filter summary must return to the mode selection page."
        )
        XCTAssertTrue(
            waitForFocus(on: randomButton, timeout: 5),
            "After returning to mode selection, default focus must go back to random playback."
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(continueButton.isEnabled, "After choosing random playback, the Continue button must be enabled.")
        moveFocus(
            .down,
            to: continueButton,
            maximumPresses: 2,
            message: "After choosing random playback, focus must be able to move down to the Continue button."
        )
        attachScreenshot(app: app, name: "tvos-playback-01-random-selected-continue-focused")
        XCUIRemote.shared.press(.select)

        let settingsButton = app.buttons["slideshow.control.settings.button"]
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        let previousButton = app.buttons["slideshow.control.previous.button"]
        let nextButton = app.buttons["slideshow.control.next.button"]
        let entryHint = app.otherElements["slideshow.entryHint.banner"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 30),
            "After Continue, the app must reach the playback page and show the control bar."
        )
        XCTAssertTrue(
            entryHint.waitForExistence(timeout: 10),
            "The first playback round must show the one-time remote hint."
        )
        XCTAssertTrue(
            waitForFocus(on: settingsButton, timeout: 8),
            "While the one-time hint is shown, default focus must land on the settings button."
        )
        XCTAssertTrue(
            previousButton.waitForExistence(timeout: 5),
            "The playback control bar must show the previous button."
        )
        XCTAssertFalse(previousButton.isEnabled, "At the initial history boundary, previous must be disabled.")
        attachScreenshot(app: app, name: "tvos-playback-02-entry-hint-settings-focused")

        moveFocus(
            .right,
            to: playPauseButton,
            maximumPresses: 3,
            message: "Before the history chain starts, focus must be able to move to Play/Pause."
        )
        let playingValue = String(describing: playPauseButton.value ?? "")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: 4) { String(describing: playPauseButton.value ?? "") != playingValue },
            "Autoplay must be paused before the history chain starts."
        )

        XCUIRemote.shared.press(.down)
        XCTAssertTrue(
            waitForDisappearance(of: playPauseButton, timeout: 5),
            "After pressing Down, the hint and the control bar must hide."
        )
        let wakeReceiver = app.descendants(matching: .any)["slideshow.hiddenWakeReceiver"]
        XCTAssertTrue(
            wakeReceiver.waitForExistence(timeout: 5),
            "After the control bar hides, the wake focus receiver layer must appear."
        )
        XCTAssertTrue(
            waitForFocus(on: wakeReceiver, timeout: 5),
            "Before sending the wake arrow key, the hidden receiver layer must have system focus."
        )
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: 5),
            "With the control bar hidden, an arrow key must wake it again."
        )
        attachFocusAudit(app: app, name: "tvos-playback-focus-after-control-bar-wake")
        XCTAssertTrue(
            waitForFocus(on: playPauseButton, timeout: 6),
            "After the control bar wakes again, focus must land on Play/Pause."
        )
        attachScreenshot(app: app, name: "tvos-playback-03-control-bar-wake-playpause-focused")

        let indexProbe = app.otherElements["slideshow.control.indexProbe"]
        XCTAssertTrue(
            indexProbe.waitForExistence(timeout: 5),
            "The playback page must expose the read-only index probe."
        )
        let indexAtA = try requireIndexValue(indexProbe)
        XCTAssertTrue(
            previousButton.waitForExistence(timeout: 5),
            "The start of the history chain must show the previous button."
        )
        XCTAssertFalse(previousButton.isEnabled, "A must be at the history start of the current playback session.")
        let historyStart = captureVisualIdentity(
            app: app,
            evidenceName: "history-start",
            attachmentName: "tvos-playback-05-history-a-paused"
        )

        moveFocus(
            .right,
            to: nextButton,
            maximumPresses: 2,
            message: "Focus must be able to move from Play/Pause to Next."
        )
        XCUIRemote.shared.press(.select)
        let indexAfterFirstNext = try waitForIndexChange(
            indexProbe,
            from: indexAtA,
            app: app,
            playPauseButton: playPauseButton,
            timeout: 10
        )
        XCTAssertNotEqual(indexAfterFirstNext, indexAtA, "The first next must advance the playback cursor.")
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        let firstNext = captureVisualIdentity(
            app: app,
            evidenceName: "history-first-next",
            attachmentName: "tvos-playback-06-history-b-after-next"
        )

        moveFocus(
            .right,
            to: nextButton,
            maximumPresses: 2,
            message: "After the first next settles, focus must be able to move to Next again."
        )
        XCUIRemote.shared.press(.select)
        let indexAfterSecondNext = try waitForIndexChange(
            indexProbe,
            from: indexAfterFirstNext,
            app: app,
            playPauseButton: playPauseButton,
            timeout: 10
        )
        XCTAssertNotEqual(
            indexAfterSecondNext,
            indexAfterFirstNext,
            "The second next must advance the playback cursor further."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        let secondNext = captureVisualIdentity(
            app: app,
            evidenceName: "history-second-next",
            attachmentName: "tvos-playback-07-history-c-after-next"
        )

        moveFocus(
            .left,
            to: playPauseButton,
            maximumPresses: 2,
            message: "Focus must be able to move from Next back to Play/Pause."
        )
        moveFocus(
            .left,
            to: previousButton,
            maximumPresses: 2,
            message: "Once history exists, focus must be able to move to Previous."
        )
        XCUIRemote.shared.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
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

        moveFocus(
            .left,
            to: previousButton,
            maximumPresses: 2,
            message: "After going back once, focus must be able to move to Previous again."
        )
        XCUIRemote.shared.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        _ = try requireIndexValue(indexProbe)
        XCTAssertTrue(
            previousButton.waitForExistence(timeout: 5),
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
        do {
            try StrictE2EPhotoIdentity.assertRoundTrip(
                [historyStart, firstNext, secondNext, firstPrevious, secondPrevious]
            )
        } catch {
            XCTFail(error.localizedDescription)
        }

        moveFocus(
            .right,
            to: nextButton,
            maximumPresses: 3,
            message: "Before checking autoplay, focus must be able to move to Next."
        )
        XCUIRemote.shared.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        _ = try requireIndexValue(indexProbe)
        moveFocus(
            .right,
            to: nextButton,
            maximumPresses: 2,
            message: "After consuming one step of forward history, focus must be able to move to Next again."
        )
        XCUIRemote.shared.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        _ = try requireIndexValue(indexProbe)

        moveFocus(
            .left,
            to: playPauseButton,
            maximumPresses: 2,
            message: "At the history frontier, focus must be able to move to Play/Pause."
        )
        let pausedValue = String(describing: playPauseButton.value ?? "")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: 4) { String(describing: playPauseButton.value ?? "") != pausedValue },
            "Pressing Select again after pausing must resume autoplay."
        )
        let indexBeforeAutoPlay = try requireIndexValue(indexProbe)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.autoPlayObservationSeconds))
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        XCTAssertTrue(
            waitForFocus(on: playPauseButton, timeout: 6),
            "After auto-advance, focus on wake must return to Play/Pause."
        )
        let indexAfterAutoPlay = try waitForIndexChange(
            indexProbe,
            from: indexBeforeAutoPlay,
            app: app,
            playPauseButton: playPauseButton,
            timeout: 3
        )
        attachScreenshot(app: app, name: "tvos-playback-10-auto-advanced-visible-frame")

        let resumedValue = String(describing: playPauseButton.value ?? "")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: 4) { String(describing: playPauseButton.value ?? "") != resumedValue },
            "Pressing Select after auto-advance must pause playback."
        )
        let pauseStartedAt = Date()
        let pausedControlValue = String(describing: playPauseButton.value ?? "")
        XCTAssertEqual(
            try requireIndexValue(indexProbe),
            indexAfterAutoPlay,
            "Pausing must not advance an extra photo."
        )
        let pauseImmediate = captureVisualIdentity(
            app: app,
            evidenceName: "pause-immediate",
            attachmentName: "tvos-playback-11-pause-immediate-visible-frame"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.pausedPlaybackObservationSeconds))
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        let pauseVerifiedAt = Date()
        let pauseElapsedSeconds = pauseVerifiedAt.timeIntervalSince(pauseStartedAt)
        XCTAssertGreaterThanOrEqual(
            pauseElapsedSeconds,
            Timing.minimumPauseEvidenceSeconds,
            "The paused-frame comparison must span at least 10 seconds."
        )
        XCTAssertEqual(
            try requireIndexValue(indexProbe),
            indexAfterAutoPlay,
            "During a pause of at least 10 seconds, autoplay must not catch up."
        )
        XCTAssertTrue(
            waitForFocus(on: playPauseButton, timeout: 6),
            "After the pause wait, focus on wake must return to Play/Pause."
        )
        let pauseHeld = captureVisualIdentity(
            app: app,
            evidenceName: "pause-after-10s",
            attachmentName: "tvos-playback-12-pause-after-10-seconds-visible-frame"
        )
        do {
            try StrictE2EPhotoIdentity.assertPauseHold(pauseImmediate, pauseHeld)
        } catch {
            XCTFail(error.localizedDescription)
        }
        let pauseEvidence = XCTAttachment(
            string: """
                pauseStartedAtUnixSeconds=\(pauseStartedAt.timeIntervalSince1970)
                pauseVerifiedAtUnixSeconds=\(pauseVerifiedAt.timeIntervalSince1970)
                pauseElapsedSeconds=\(pauseElapsedSeconds)
                pausedControlValue=\(pausedControlValue)
                verifiedControlValue=\(String(describing: playPauseButton.value ?? ""))
                """
        )
        pauseEvidence.name = "tvos-playback-pause-state-and-timing"
        pauseEvidence.lifetime = .keepAlways
        add(pauseEvidence)

        let retainedPausedValue = String(describing: playPauseButton.value ?? "")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: 4) { String(describing: playPauseButton.value ?? "") != retainedPausedValue },
            "After the pause wait, autoplay must be resumable."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.autoPlayObservationSeconds))
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        XCTAssertTrue(
            waitForFocus(on: playPauseButton, timeout: 6),
            "After autoplay resumes, focus on wake must return to Play/Pause."
        )
        let indexAfterResume = try waitForIndexChange(
            indexProbe,
            from: indexAfterAutoPlay,
            app: app,
            playPauseButton: playPauseButton,
            timeout: 3
        )
        XCTAssertNotEqual(
            indexAfterResume,
            indexAfterAutoPlay,
            "After resuming, playback must advance to another photo."
        )
        let resumed = captureVisualIdentity(
            app: app,
            evidenceName: "resumed",
            attachmentName: "tvos-playback-13-resumed-advanced-visible-frame"
        )
        do {
            try StrictE2EPhotoIdentity.assertResumedAdvanced(pauseHeld, resumed)
        } catch {
            XCTFail(error.localizedDescription)
        }
        StrictE2EVisualEvidence.writeJSON(
            [
                "suite": "tvos-flow",
                "history": [
                    StrictE2EPhotoIdentity.payload(historyStart),
                    StrictE2EPhotoIdentity.payload(firstNext),
                    StrictE2EPhotoIdentity.payload(secondNext),
                    StrictE2EPhotoIdentity.payload(firstPrevious),
                    StrictE2EPhotoIdentity.payload(secondPrevious)
                ],
                "pause_immediate": StrictE2EPhotoIdentity.payload(pauseImmediate),
                "pause_after_10s": StrictE2EPhotoIdentity.payload(pauseHeld),
                "resumed": StrictE2EPhotoIdentity.payload(resumed)
            ],
            name: "visual-identity.json"
        )

        let finalPlayingValue = String(describing: playPauseButton.value ?? "")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: 4) { String(describing: playPauseButton.value ?? "") != finalPlayingValue },
            "Autoplay must be pausable again before entering settings."
        )
        moveFocus(
            .left,
            to: settingsButton,
            maximumPresses: 4,
            message: "Focus in the playback control bar must be able to move to Settings."
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["settings.item.playback"].waitForExistence(timeout: 8),
            "The settings button must open the settings page."
        )
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 8),
            "Pressing Back/Menu on the settings page must return to the playback page."
        )
    }

    @MainActor
    private func configureServerThroughFirstBoot(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 12), "A clean install must reach the first-boot form.")
        replaceFocusedText(in: serverField, app: app, with: input.serverURL)

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 8), "The first-boot form must show the API Key field.")
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
            testConnectionButton.waitForExistence(timeout: 5),
            "The first-boot form must show the Test Connection button."
        )
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.right)
        attachFocusAudit(app: app, name: "tvos-firstboot-focus-before-test-connection")
        XCUIRemote.shared.press(.select)

        let success = app.staticTexts["firstboot.connection.success"]
        XCTAssertTrue(
            success.waitForExistence(timeout: 45),
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
            saveButton.waitForExistence(timeout: 5),
            "After a successful connection, the Save Settings button must appear."
        )
        XCTAssertTrue(saveButton.isEnabled, "After a successful connection, Save Settings must be enabled.")
        attachFocusAudit(app: app, name: "tvos-firstboot-focus-before-save")
        attachScreenshot(app: app, name: "tvos-firstboot-connection-success-save-focused")
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    private func replaceFocusedText(in field: XCUIElement, app: XCUIApplication, with value: String) {
        XCTAssertTrue(waitForFocus(on: field, timeout: 4), "The field must be focused before typing.")
        XCUIRemote.shared.press(.select)
        app.typeText(value)

        let submit = app.buttons.matching(
            // ui-label-lookup: Match the simulator-localized system keyboard submit key.
            NSPredicate(format: "label IN %@", ["下一项", "Next", "完成", "Done"])
        ).firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 4), "The system keyboard must show Next or Done.")
        for _ in 0..<6 where !submit.hasFocus {
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(submit.hasFocus, "Focus the system keyboard submit button before submitting text.")
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.menu)

        if field.identifier == "firstboot.serverURL.field" {
            XCTAssertEqual(field.value as? String, value, "The server address must be submitted verbatim.")
        }
        XCTAssertTrue(
            waitForFocus(on: field, timeout: 4),
            "After submitting text, focus must return to the original field."
        )
    }

    @MainActor
    private func moveFocus(
        _ direction: XCUIRemote.Button,
        to element: XCUIElement,
        maximumPresses: Int,
        message: String
    ) {
        for _ in 0..<maximumPresses {
            if element.exists && element.hasFocus { return }
            XCUIRemote.shared.press(direction)
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusMovementSettleSeconds))
        }
        XCTAssertTrue(waitForFocus(on: element, timeout: 4), message)
    }

    @MainActor
    private func waitForFocus(on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.hasFocus { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPollingSeconds))
        }
        return element.exists && element.hasFocus
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { !element.exists }
    }

    @MainActor
    private func ensureControlBarVisible(app: XCUIApplication, playPauseButton: XCUIElement) {
        if !playPauseButton.exists {
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5), "An arrow key must wake the playback control bar.")
    }

    private func requireIndexValue(_ indexProbe: XCUIElement) throws -> String {
        let value = String(describing: indexProbe.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(
            value.isEmpty ? nil : value,
            "The playback index probe is empty, so autoplay and retained-history cannot be proven."
        )
    }

    @MainActor
    private func waitForIndexChange(
        _ indexProbe: XCUIElement,
        from oldValue: String,
        app: XCUIApplication,
        playPauseButton: XCUIElement,
        timeout: TimeInterval
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !indexProbe.exists {
                ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
            }
            if indexProbe.exists {
                let value = String(describing: indexProbe.value ?? "")
                if !value.isEmpty && value != oldValue { return value }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPollingSeconds))
        }
        XCTFail("The index probe must change after a playback action.")
        return try requireIndexValue(indexProbe)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPollingSeconds))
        }
        return condition()
    }

    private func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func captureVisualIdentity(
        app: XCUIApplication,
        evidenceName: String,
        attachmentName: String
    ) -> StrictE2EPhotoIdentity.Result {
        let png = app.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = attachmentName
        attachment.lifetime = .keepAlways
        add(attachment)
        StrictE2EVisualEvidence.writePNG(png, name: evidenceName)
        let identity = StrictE2EPhotoIdentity.classify(png: png)
        XCTAssertEqual(
            identity.status,
            .match,
            "Visual ID failed \(evidenceName): \(identity.status.rawValue) \(identity.notes.joined(separator: " "))"
        )
        return identity
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
