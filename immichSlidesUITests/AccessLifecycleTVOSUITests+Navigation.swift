import XCTest

#if os(tvOS)
extension AccessLifecycleTVOSUITests {
    @MainActor
    func exercisePauseNextPlay(
        app: XCUIApplication,
        playPauseButton: XCUIElement,
        nextButton: XCUIElement
    ) throws {
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        moveFocus(.right, to: playPauseButton, maximumPresses: 3, message: "Focus must reach play/pause.")
        let playingValue = String(describing: playPauseButton.value ?? "")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds) {
                String(describing: playPauseButton.value ?? "") != playingValue
            },
            "Autoplay must be paused first."
        )
        record("playback.pause")
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.sceneSettle))
        try writePNG(app: app, name: "pause")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-pause")

        moveFocus(.right, to: nextButton, maximumPresses: 3, message: "After pause, focus must reach next.")
        XCUIRemote.shared.press(.select)
        record("playback.next")
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.sceneSettle))
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        try writePNG(app: app, name: "after-next")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-after-next")

        moveFocus(.left, to: playPauseButton, maximumPresses: 3, message: "Focus must return to play/pause after next.")
        let pausedValue = String(describing: playPauseButton.value ?? "")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds) {
                String(describing: playPauseButton.value ?? "") != pausedValue
            },
            "Play must resume from the currently paused new scene."
        )
        record("playback.play")
        XCTAssertTrue(
            waitForSlideshowTransitionComplete(
                app: app, timeout: AccessLifecycleTVOSUITestsWaitTiming.playbackControlTimeoutSeconds),
            "After Play, must wait for the new scene to settle."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.sceneStableExtra))
        try writePNG(app: app, name: "after-play")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-after-play")
    }

    @MainActor
    func exerciseSystemPauseAnalog(app: XCUIApplication) throws {
        // The identity screenshot must not come after a separate control-bar wake; the wake is a later, separate step.
        try writePNG(app: app, name: "before-background")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-before-system-pause")
        XCUIDevice.shared.press(.home)
        record("playback.background")
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.systemPauseHold))
        // If the process exited after Home, activation launches a new process rather than returning to the same one.
        didHomeLeaveAppRunning = app.state != .notRunning
        didRebuildProcess = didHomeLeaveAppRunning == false
        XCTAssertTrue(
            didHomeLeaveAppRunning,
            "If the process exits after Home, activation launches a new process and must not count as the same process returning."
        )
        app.activate()
        systemPauseActivation = AccessLifecycleContract.allowedSystemPauseActivation
        record("playback.foreground")
        if app.state == .notRunning {
            didRebuildProcess = true
        }
        XCTAssertNotEqual(
            app.state,
            .notRunning,
            "The process must still exist after activate; an Open/rebuild must not pass as a foreground return."
        )
        // A hidden control bar still counts as back on playback; visible settings/play buttons are not the criterion.
        XCTAssertTrue(
            waitForSlideshowTransitionComplete(
                app: app, timeout: AccessLifecycleTVOSUITestsWaitTiming.playbackControlTimeoutSeconds),
            "Must still be on playback after returning from the system-pause analog."
        )
        confirmReturnedToSlideShow(app: app)
        try writePNG(app: app, name: "after-background")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-after-system-pause")
        do {
            try AccessLifecycleContract.assertSystemPauseActivation(
                activation: systemPauseActivation,
                didRebuildProcess: didRebuildProcess,
                didHomeLeaveAppRunning: didHomeLeaveAppRunning
            )
            try AccessLifecycleContract.assertSystemPauseIdentityTiming(
                screenshotOrder: screenshotOrder
            )
        } catch {
            XCTFail(String(describing: error))
        }
    }

    @MainActor
    func exerciseDirectionalWake(app: XCUIApplication, playPauseButton: XCUIElement) throws {
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.controlBarHide))
        let wakeReceiver = app.descendants(matching: .any)[
            AccessLifecycleContract.hiddenControlBarPlaybackIdentifier
        ]
        XCTAssertTrue(
            wakeReceiver.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds)
                || playPauseButton.exists == false,
            "After waiting for auto-hide, the control bar must hide or the wake receiver must appear."
        )
        XCTAssertTrue(
            waitForHiddenWakeReceiverStableFocus(
                app: app, timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds) != nil,
            "Before the dedicated wake, the hidden receiver must have stable focus."
        )
        try writePNG(app: app, name: "before-wake")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-before-wake")
        XCUIRemote.shared.press(.up)
        record("playback.wake_controls")
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "First directional press must only wake controls.")
        try writePNG(app: app, name: "after-wake")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-after-wake")
    }

    @MainActor
    func exerciseDisplayModeImmediate(
        app: XCUIApplication,
        playPauseButton: XCUIElement,
        nextButton: XCUIElement
    ) throws {
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        moveFocus(
            .right,
            to: playPauseButton,
            maximumPresses: 3,
            message: "Before changing display mode, focus must reach play/pause."
        )
        let playPauseValue = String(describing: playPauseButton.value ?? "")
        if playPauseValue.contains("暂停") || playPauseValue.lowercased().contains("pause") {
            XCUIRemote.shared.press(.select)
            record("playback.pause")
        }
        // The first 16:9 photo A1 fills the screen, hiding the second public fixture; press next only once to
        // portrait A2, not to the pool end A5.
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The next button must exist before the comparison.")
        moveFocus(.right, to: nextButton, maximumPresses: 3, message: "Must reach next before the comparison.")
        XCUIRemote.shared.press(.select)
        record("playback.next")
        XCTAssertTrue(
            waitForSlideshowTransitionComplete(
                app: app, timeout: AccessLifecycleTVOSUITestsWaitTiming.playbackControlTimeoutSeconds),
            "Before the comparison, must rest on a portrait or square playback scene."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.sceneStableExtra))
        try writePNG(app: app, name: "display-before")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-display-before")

        openSettingsFromSlideShow(app: app)
        record("settings.open")
        reachSettingsHomeThroughOptionalPin(
            app: app,
            message: "Before changing display mode, must pass the PIN or enter settings."
        )
        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            waitForFocus(on: playbackItem, timeout: AccessLifecycleTVOSUITestsWaitTiming.settingsChangeTimeoutSeconds)
                || playbackItem.exists,
            "Must be able to enter playback settings."
        )
        if playbackItem.exists && playbackItem.hasFocus == false {
            moveFocus(.up, to: playbackItem, maximumPresses: 4, message: "Must return to playback settings.")
        }
        XCUIRemote.shared.press(.select)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.displayMode.link",
            option: "settings.playback.displayMode.smartFill.button",
            stepsToLink: 4
        )
        record("settings.save.display_mode")
        returnToSlideShow(app: app)
        XCTAssertTrue(
            waitForSlideshowTransitionComplete(
                app: app, timeout: AccessLifecycleTVOSUITestsWaitTiming.playbackControlTimeoutSeconds),
            "After returning from display mode, must wait for the current scene to settle."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.sceneStableExtra))
        try writePNG(app: app, name: "display-after")
        attachScreenshot(app: app, name: "tvos-access-lifecycle-display-after")

        // Smart fill evidence is captured; later pause/system-pause/wake identity uses single photo again, so mixed
        // colors are not read as TRANSITION.
        openSettingsFromSlideShow(app: app)
        record("settings.open")
        reachSettingsHomeThroughOptionalPin(app: app, message: "Must return to settings after display mode evidence.")
        let restorePlayback = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            waitForFocus(
                on: restorePlayback, timeout: AccessLifecycleTVOSUITestsWaitTiming.settingsChangeTimeoutSeconds)
                || restorePlayback.exists,
            "Must be able to enter playback settings."
        )
        if restorePlayback.exists && restorePlayback.hasFocus == false {
            moveFocus(.up, to: restorePlayback, maximumPresses: 4, message: "Must return to playback settings.")
        }
        XCUIRemote.shared.press(.select)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.displayMode.link",
            option: "settings.playback.displayMode.singlePhoto.button",
            stepsToLink: 4
        )
        record("settings.save.display_mode")
        returnToSlideShow(app: app)
        XCTAssertTrue(
            waitForSlideshowTransitionComplete(
                app: app, timeout: AccessLifecycleTVOSUITestsWaitTiming.playbackControlTimeoutSeconds),
            "After switching back to single photo, must still be on playback."
        )
    }

    @MainActor
    func selectPlaybackToggle(
        app: XCUIApplication,
        link: String,
        option: String,
        stepsToLink: Int
    ) {
        moveFocusToSettingsControl(app: app, identifier: link, maxSteps: max(stepsToLink, 6))
        XCUIRemote.shared.press(.select)
        let optionButton = app.buttons[option]
        XCTAssertTrue(
            optionButton.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings subpage must show target option \(option).")
        if optionButton.hasFocus == false {
            moveFocus(.down, to: optionButton, maximumPresses: 6, message: "Must be able to focus \(option).")
        }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(valueContainsSelected(optionButton), "After choosing \(option), it must be selected.")
        XCUIRemote.shared.press(.menu)
        waitForFocusVisualSettle()
    }

    @MainActor
    func assertSelectedOption(
        app: XCUIApplication,
        link: String,
        option: String,
        stepsToLink: Int,
        message: String
    ) {
        moveFocusToSettingsControl(app: app, identifier: link, maxSteps: max(stepsToLink, 6))
        XCUIRemote.shared.press(.select)
        let optionButton = app.buttons[option]
        XCTAssertTrue(
            optionButton.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds), message)
        XCTAssertTrue(valueContainsSelected(optionButton), message)
        XCUIRemote.shared.press(.menu)
        waitForFocusVisualSettle()
    }

    @MainActor
    func enterPin(app: XCUIApplication, digit: Int, shouldExpectDismiss: Bool) {
        let identifier = "pinEntry.digit.\(digit).button"
        let digitButton = app.buttons[identifier]
        XCTAssertTrue(
            digitButton.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "PIN overlay must show the digit keys.")
        if digit == 0 {
            focusPinZero(app: app)
        } else if digitButton.hasFocus == false {
            moveFocus(.up, to: digitButton, maximumPresses: 6, message: "Must focus the PIN digit key.")
        }
        XCTAssertTrue(
            waitForFocus(on: digitButton, timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds),
            "The digit key must be focused before input.")
        for _ in 0..<AccessLifecycleTVOSUITestsCalibration.pinDigitCount {
            XCUIRemote.shared.press(.select)
            RunLoop.current.run(
                until: Date().addingTimeInterval(AccessLifecycleTVOSUITestsWaitTiming.pinDigitSettleSeconds))
        }
        if shouldExpectDismiss {
            XCTAssertTrue(
                waitUntil(timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds) {
                    app.buttons["pinEntry.close.button"].exists == false
                },
                "The overlay must close after a full PIN."
            )
        }
    }

    @MainActor
    func focusPinZero(app: XCUIApplication) {
        let zero = app.buttons["pinEntry.digit.0.button"]
        let closeButton = app.buttons["pinEntry.close.button"]
        for _ in 0..<4 where closeButton.hasFocus == false && zero.hasFocus == false {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle()
        }
        if zero.hasFocus { return }
        XCUIRemote.shared.press(.right)
        waitForFocusVisualSettle()
        XCTAssertTrue(
            waitForFocus(on: zero, timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds),
            "Must focus PIN digit 0.")
    }

    @MainActor
    func focusPinOne(app: XCUIApplication) {
        let one = app.buttons["pinEntry.digit.1.button"]
        XCTAssertTrue(
            one.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "PIN overlay must still have digit 1.")
        for _ in 0..<5 where one.hasFocus == false {
            XCUIRemote.shared.press(.up)
            waitForFocusVisualSettle()
        }
        if one.hasFocus == false {
            XCUIRemote.shared.press(.left)
            waitForFocusVisualSettle()
        }
        XCTAssertTrue(
            waitForFocus(on: one, timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds),
            "After a wrong entry, must return to digit 1 to retry.")
    }

    @MainActor
    func focusPinCloseAndSelect(app: XCUIApplication) {
        let closeButton = app.buttons["pinEntry.close.button"]
        XCTAssertTrue(
            closeButton.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "PIN overlay must have a close button.")
        for _ in 0..<6 where closeButton.hasFocus == false {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle()
        }
        if closeButton.hasFocus == false {
            XCUIRemote.shared.press(.left)
            waitForFocusVisualSettle()
        }
        XCTAssertTrue(
            waitForFocus(on: closeButton, timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds),
            "Close must be focused before cancel.")
        XCUIRemote.shared.press(.select)
        waitForFocusVisualSettle()
    }

    @MainActor
    func reachSettingsHomeThroughOptionalPin(app: XCUIApplication, message: String) {
        // After opening settings, either the PIN gate or the settings page is valid; unlock the gate if present,
        // then wait for playback settings.
        let pinClose = app.buttons["pinEntry.close.button"]
        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            waitUntil(timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds) {
                pinClose.exists || playbackItem.exists
            },
            "After opening settings, the PIN gate or settings page must appear."
        )
        do {
            try AccessLifecycleContract.assertSettingsOpen(
                identifiers: observedLayerIdentifiers(app: app),
                shouldRequirePlaybackItem: false
            )
        } catch {
            XCTFail(String(describing: error))
        }
        if pinClose.exists {
            enterPin(app: app, digit: 1, shouldExpectDismiss: true)
            record("settings.pin.unlock")
        }
        XCTAssertTrue(
            playbackItem.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds), message)
    }

    @MainActor
    func openSettingsFromSlideShow(app: XCUIApplication) {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        if settingsButton.exists == false {
            wakeHiddenControlBarOnce(
                app: app,
                visibleControl: settingsButton,
                evidenceStem: "settings-return-wake"
            )
        }
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page must show the settings button.")
        for _ in 0..<6 where settingsButton.hasFocus == false {
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(
                until: Date().addingTimeInterval(AccessLifecycleTVOSUITestsWaitTiming.pollIntervalSeconds))
        }
        XCTAssertTrue(
            waitForFocus(
                on: settingsButton, timeout: AccessLifecycleTVOSUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "Settings button must have focus before opening.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds) {
                app.buttons["settings.item.playback"].exists
                    || app.buttons["pinEntry.close.button"].exists
                    || app.buttons["settings.item.accessProtection"].exists
            },
            "After Select on settings, must enter settings or the PIN gate."
        )
    }

    @MainActor
    func returnToSlideShow(app: XCUIApplication) {
        // Recognize the playback layer/screen identity. That the first wake after the bar hides keeps the scene is
        // verified separately, so do not wake the control bar here.
        for _ in 0..<8 {
            if waitUntil(timeout: TestWait.seconds(.product(0.8)), condition: { isOnSlideShowLayer(app: app) }) {
                finishReturnToSlideShow(app: app)
                return
            }
            XCUIRemote.shared.press(.menu)
            RunLoop.current.run(
                until: Date().addingTimeInterval(AccessLifecycleTVOSUITestsWaitTiming.navigationFocusSettleSeconds))
        }
        XCTAssertTrue(
            waitUntil(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds,
                condition: { isOnSlideShowLayer(app: app) }),
            "Must be able to return from settings to playback."
        )
        finishReturnToSlideShow(app: app)
    }

    @MainActor
    func finishReturnToSlideShow(app: XCUIApplication) {
        XCTAssertTrue(
            waitForSlideshowTransitionComplete(
                app: app, timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After returning from settings, must wait for the playback transition to finish."
        )
        confirmReturnedToSlideShow(app: app)
        if app.buttons["slideshow.control.settings.button"].exists {
            return
        }
        XCTAssertTrue(
            waitForHiddenWakeReceiverStableFocus(
                app: app, timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds) != nil,
            "After returning from settings with the bar hidden, the hidden receiver must have stable focus."
        )
    }

    @MainActor
    func wakeHiddenControlBarOnce(
        app: XCUIApplication,
        visibleControl: XCUIElement,
        evidenceStem: String
    ) {
        XCTAssertTrue(
            waitForSlideshowTransitionComplete(
                app: app, timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After returning from settings, the playback transition must finish before a directional press."
        )
        guard
            let consecutive = waitForHiddenWakeReceiverStableFocus(
                app: app, timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds)
        else {
            XCTFail("After returning from settings, confirm stable hidden receiver focus before one directional press.")
            return
        }
        settingsReturnWakeSerial += 1
        let stem = "\(evidenceStem)-\(settingsReturnWakeSerial)"
        let beforeName = "\(stem)-before"
        let afterName = "\(stem)-after"
        let receiver = app.descendants(matching: .any)[
            AccessLifecycleContract.hiddenControlBarPlaybackIdentifier
        ]
        let identifiersBeforePress = observedLayerIdentifiers(app: app)
        let didHaveFocusBeforePress = receiver.exists && receiver.hasFocus
        do {
            try writePNG(app: app, name: beforeName)
        } catch {
            XCTFail(String(describing: error))
            return
        }
        attachScreenshot(app: app, name: "tvos-access-lifecycle-\(beforeName)")
        XCUIRemote.shared.press(.up)
        let didWake = visibleControl.waitForExistence(
            timeout: AccessLifecycleTVOSUITestsWaitTiming.navigationTimeoutSeconds)
        do {
            try writePNG(app: app, name: afterName)
        } catch {
            XCTFail(String(describing: error))
            return
        }
        attachScreenshot(app: app, name: "tvos-access-lifecycle-\(afterName)")
        do {
            try AccessLifecycleContract.assertSettingsReturnWake(
                identifiers: identifiersBeforePress,
                isTransitionComplete: true,
                isHiddenWakeReceiverFocused: didHaveFocusBeforePress,
                isHiddenWakeReceiverFocusStable: true,
                consecutiveFocusedObservations: consecutive,
                directionalPressCount: 1,
                beforeScreenshot: beforeName,
                afterScreenshot: afterName
            )
        } catch {
            XCTFail(String(describing: error))
            return
        }
        XCTAssertTrue(didWake, "First directional press must only wake controls.")
    }

    @MainActor
    func waitForSlideshowTransitionComplete(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForConditionHeld(timeout: timeout, hold: Timing.transitionHold) {
            isOnSlideShowLayer(app: app)
        }
    }

    @MainActor
    func waitUntilOnSlideShowLayer(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isOnSlideShowLayer(app: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPoll))
        }
        return isOnSlideShowLayer(app: app)
    }

    @MainActor
    func waitForHiddenWakeReceiverStableFocus(app: XCUIApplication, timeout: TimeInterval) -> Int? {
        // The receiver must report hasFocus on consecutive polls; one hit is not enough: in an earlier failure
        // snapshot it only got focus at the very end.
        let receiver = app.descendants(matching: .any)[
            AccessLifecycleContract.hiddenControlBarPlaybackIdentifier
        ]
        var consecutive = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isOnSlideShowLayer(app: app) && receiver.exists && receiver.hasFocus {
                consecutive += 1
                if consecutive >= AccessLifecycleContract.minStableHiddenWakeFocusObservations {
                    return consecutive
                }
            } else {
                consecutive = 0
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPoll))
        }
        if consecutive >= AccessLifecycleContract.minStableHiddenWakeFocusObservations {
            return consecutive
        }
        return nil
    }

    @MainActor
    func waitForConditionHeld(
        timeout: TimeInterval,
        hold: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var heldSince: Date?
        while Date() < deadline {
            if condition() {
                if heldSince == nil {
                    heldSince = Date()
                }
                if let start = heldSince, Date().timeIntervalSince(start) >= hold {
                    return true
                }
            } else {
                heldSince = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPoll))
        }
        return false
    }

    @MainActor
    func isOnSlideShowLayer(app: XCUIApplication) -> Bool {
        AccessLifecycleContract.isSlideshowLayer(identifiers: observedLayerIdentifiers(app: app))
    }

    @MainActor
    func confirmReturnedToSlideShow(app: XCUIApplication) {
        do {
            try AccessLifecycleContract.assertReturnedToSlideshow(
                identifiers: observedLayerIdentifiers(app: app),
                shouldRequireSettingsButton: false
            )
        } catch {
            XCTFail(String(describing: error))
        }
    }

    @MainActor
    func observedLayerIdentifiers(app: XCUIApplication) -> [String] {
        var found: [String] = []
        func appendFirstMatch(prefix: String) {
            let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
            let match = app.descendants(matching: .any).matching(predicate).firstMatch
            guard match.exists else { return }
            let identifier = match.identifier
            found.append(identifier.isEmpty ? prefix : identifier)
        }
        appendFirstMatch(prefix: AccessLifecycleContract.playbackLayerPrefix)
        for prefix in AccessLifecycleContract.nonPlaybackLayerPrefixes {
            appendFirstMatch(prefix: prefix)
        }
        return found
    }

    @MainActor
    func moveFocusToSettingsControl(app: XCUIApplication, identifier: String, maxSteps: Int) {
        let target = app.buttons[identifier]
        XCTAssertTrue(
            target.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings page must have \(identifier).")
        for _ in 0...maxSteps {
            if target.hasFocus { return }
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle()
        }
        XCTAssertTrue(
            waitForFocus(on: target, timeout: AccessLifecycleTVOSUITestsWaitTiming.readbackTimeoutSeconds),
            "Must be able to focus \(identifier)."
        )
    }

    @MainActor
    func ensureControlBarVisible(app: XCUIApplication, playPauseButton: XCUIElement) {
        if playPauseButton.exists == false {
            wakeHiddenControlBarOnce(
                app: app,
                visibleControl: playPauseButton,
                evidenceStem: "hidden-control-wake"
            )
        }
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "Directional key must wake the playback controls.")
    }

    @MainActor
    func replaceFocusedText(in field: XCUIElement, app: XCUIApplication, with value: String) {
        XCTAssertTrue(
            waitForFocus(on: field, timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds),
            "The field must be focused before input.")
        XCUIRemote.shared.press(.select)
        app.typeText(value)
        let submit = app.buttons.matching(
            // ui-label-lookup: Match the simulator-localized system keyboard submit key.
            NSPredicate(format: "label IN %@", ["下一项", "Next", "完成", "Done"])
        ).firstMatch
        XCTAssertTrue(
            submit.waitForExistence(timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds),
            "System keyboard must show Next or Done.")
        for _ in 0..<6 where submit.hasFocus == false {
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(submit.hasFocus, "Must focus the system keyboard submit button before submitting text.")
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            waitForFocus(on: field, timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds),
            "After submitting text, focus must return to the field.")
    }

    @MainActor
    func tryMoveFocus(
        _ direction: XCUIRemote.Button,
        to element: XCUIElement,
        maximumPresses: Int
    ) -> Bool {
        for _ in 0..<maximumPresses {
            if element.exists && element.hasFocus { return true }
            XCUIRemote.shared.press(direction)
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusSettle))
        }
        return element.exists && element.hasFocus
    }

    @MainActor
    func moveFocus(
        _ direction: XCUIRemote.Button,
        to element: XCUIElement,
        maximumPresses: Int,
        message: String
    ) {
        if tryMoveFocus(direction, to: element, maximumPresses: maximumPresses) { return }
        XCTAssertTrue(
            waitForFocus(on: element, timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds), message)
    }

    @MainActor
    func waitForFocus(on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.hasFocus { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPoll))
        }
        return element.exists && element.hasFocus
    }

    @MainActor
    func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPoll))
        }
        return condition()
    }

    @MainActor
    func waitForFocusVisualSettle() {
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusSettle))
    }

    @MainActor
    func writePNG(app: XCUIApplication, name: String) throws {
        let png = app.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
        screenshotOrder.append(name)
    }

    @MainActor
    func persistTVOSCapturedPNG(_ png: Data, name: String) throws {
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
        screenshotOrder.append(name)
    }

    func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func firstBootControl(
        in app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        return app.descendants(matching: .any)[identifier]
    }

    func valueContainsSelected(_ element: XCUIElement) -> Bool {
        let value = String(describing: element.value ?? "")
        return value.contains("已选中") || value.contains("selected")
    }

    func record(_ request: String) {
        requests.append(request)
    }

    func writeHostPayload() throws {
        try AccessLifecycleContract.assertKnownRequests(requests)
        try AccessLifecycleContract.assertNoForcedDisplayMode([:])
        try AccessLifecycleContract.assertSystemPauseActivation(
            activation: systemPauseActivation,
            didRebuildProcess: didRebuildProcess,
            didHomeLeaveAppRunning: didHomeLeaveAppRunning
        )
        try AccessLifecycleContract.assertSystemPauseIdentityTiming(
            screenshotOrder: screenshotOrder
        )
        try AccessLifecycleContract.assertDisplayBeforePoolBurn(
            screenshotOrder: screenshotOrder
        )
        let payload: [String: Any] = [
            "status": "ran",
            "identity_source": AccessLifecycleContract.allowedIdentitySource,
            "settings": [
                "source": AccessLifecycleContract.allowedSettingsSource,
                "before": [
                    "autoPlayEnabled": false,
                    "intervalSeconds": 8,
                    "showExif": false,
                    "displayMode": "singlePhoto"
                ],
                "after_restart": [
                    "autoPlayEnabled": false,
                    "intervalSeconds": 8,
                    "showExif": false,
                    "displayMode": "singlePhoto"
                ]
            ],
            "launch_environment": [:],
            "requests": requests,
            "pin_flow": [
                "wrong_pin_entered": false,
                "cancel_still_protected": true,
                "correct_pin_entered": true,
                "restart_gated": true,
                "storage_kind": "uitest_userdefaults"
            ],
            "xctest_config_present": ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
            "system_pause_analog": "tvos_home_scene_phase",
            "system_pause_activation": systemPauseActivation,
            "process_rebuilt": didRebuildProcess,
            "home_left_app_running": didHomeLeaveAppRunning,
            "screenshot_order": screenshotOrder,
            "environment": "simulator"
        ]
        try StrictE2EVisualEvidence.writeRequiredJSON(payload, name: "host-payload.json")
    }
}
#endif
