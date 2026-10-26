import ImageIO
import UIKit
import XCTest

#if os(iOS)
@MainActor
struct IOSDriver: PlaybackDriver {
    let app: XCUIApplication

    func launchToPlayback(input: StrictE2EInput) {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForPublicElement(
                "firstboot.serverURL.field", timeout: TestWait.seconds(.infrastructure(20))),
            "Fresh install must open the normal first-boot page.")
        replaceText(in: serverField, with: input.serverURL)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForPublicElement(
                "firstboot.apiKey.field", timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "First-boot page must show the API Key field.")
        replaceText(in: apiKeyField, with: input.publicKey)
        XCTAssertTrue(
            Wait.until(timeout: UITestSupportWaitTiming.shortInteractionTimeoutSeconds) {
                secureFieldHasValue(apiKeyField)
            },
            "The API Key must be entered into the secure field.")
        commitFocusedInput()

        let testConnection = control("firstboot.testConnection.button")
        XCTAssertTrue(
            testConnection.waitForPublicElement(
                "firstboot.testConnection.button", timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "First-boot page must show Test Connection.")
        tap(testConnection)
        let save = control("firstboot.saveConfig.button")
        XCTAssertTrue(
            save.waitForPublicElement(
                "firstboot.saveConfig.button", timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "First-boot page must show the Save Settings button.")
        XCTAssertTrue(waitForSaveEnabled(save), "Save must become enabled after a real connection test succeeds.")
        tap(save)

        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForPublicElement(
                "mode.random.button",
                timeout: UITestSupportWaitTiming.connectionTimeoutSeconds),
            "A successful save must lead to mode selection.")
        guard
            let playbackDeadline = IOSFirstBootNavigation(app: app).selectModeAndContinue(
                "mode.random.button", destinationIdentifier: "slideshow.control.settings.button")
        else { return }
        XCTAssertTrue(
            waitForPlaybackControls(playbackDeadline),
            "Random mode must reach the playback page.")
    }

    func applyPlaybackSettings(_ settings: [PlaybackSetting]) {
        openSettings()
        openPlaybackSection()
        for setting in settings {
            switch setting {
            case .interval30Seconds:
                let observed = PlaybackIntervalSliderIOS.adjust(in: app, targetSeconds: 30, accepting: { $0 == 30 })
                let reached30 = observed == 30
                if !reached30 {
                    try? Evidence().reject(
                        "interval30-setting", png: app.screenshotForFailureEvidence().pngRepresentation)
                }
                XCTAssertTrue(reached30, "The interval must be set to 30 seconds with the real slider.")
            case .interval15Seconds:
                let observed = PlaybackIntervalSliderIOS.adjust(in: app, targetSeconds: 15, accepting: { $0 == 15 })
                XCTAssertEqual(
                    observed, 15,
                    "The interval must be set to 15 seconds with the real slider."
                )
            case .displayMode(let isSinglePhoto):
                let picker = app.segmentedControls["settings.playback.displayMode.picker"]
                XCTAssertTrue(
                    picker.waitForPublicElement(
                        "settings.playback.displayMode.picker",
                        timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
                    "Playback settings must have display mode segments.")
                let option = picker.buttons[
                    isSinglePhoto
                        ? "settings.playback.displayMode.singlePhoto.option"
                        : "settings.playback.displayMode.smartFill.option"]
                XCTAssertTrue(
                    option.waitForFailureEvidence(timeout: UITestSupportWaitTiming.shortInteractionTimeoutSeconds),
                    "Display mode must offer the target option.")
                tap(option)
                XCTAssertTrue(
                    Wait.until(timeout: UITestSupportWaitTiming.shortInteractionTimeoutSeconds) { option.isSelected },
                    "Display mode must switch to the target option.")
            case .showExif(let isOn):
                let toggle = app.switches["settings.playback.showExif.toggle"]
                XCTAssertTrue(
                    toggle.waitForPublicElement(
                        "settings.playback.showExif.toggle",
                        timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
                    "Playback settings must provide the EXIF toggle.")
                if isToggleOn(toggle) != isOn { tap(toggle) }
                XCTAssertTrue(
                    Wait.until(timeout: UITestSupportWaitTiming.stateChangeTimeoutSeconds) {
                        isToggleOn(toggle) == isOn
                    },
                    "The EXIF toggle must reach the target state through the real settings.")
            }
        }
        returnToPlayback()
    }

    func pause() {
        pause(until: Date().addingTimeInterval(UITestSupportWaitTiming.controlAppearanceTimeoutSeconds))
    }

    func pause(until deadline: Date) {
        let identifier = "slideshow.control.playPause.button"
        var action = ControlAction()
        guard let before = prepareControl(identifier, until: deadline, action: &action) else {
            XCTFail("Playback page must provide play/pause. (\(action.diagnostic))")
            return
        }
        let initialValue = playPauseValue(before)
        guard initialValue == "pause" || initialValue == "play" else {
            XCTFail(
                "Play/pause value must be readable before pausing. (button-value-read-inconsistent; before=\(initialValue), \(action.diagnostic))"
            )
            return
        }
        if initialValue == "pause" { activateControl(before, action: &action) }
        let stateDeadline = Date().addingTimeInterval(UITestSupportWaitTiming.stateChangeTimeoutSeconds)
        var observedValues: Set<String> = []
        var didObserveLatePausedValue = false
        let paused = Wait.until(timeout: max(.zero, stateDeadline.timeIntervalSinceNow)) {
            guard Date() < stateDeadline else { return false }
            let verifyStartedAt = Date()
            defer { action.timing.verifySeconds += Date().timeIntervalSince(verifyStartedAt) }
            guard let observation = action.observe(app: app, identifier: identifier) else { return false }
            let value = playPauseValue(observation)
            observedValues.insert(value)
            let observedAt = Date()
            didObserveLatePausedValue = value == "play" && observedAt >= stateDeadline
            return value == "play" && observedAt < stateDeadline
        }
        let reason: String
        if didObserveLatePausedValue {
            reason = "paused-value-observed-after-deadline"
        } else if action.issuedAt == nil, initialValue == "play", observedValues.contains("pause") {
            reason = "initially-paused-value-changed-without-tap"
        } else if action.issuedAt != nil, observedValues == ["pause"] {
            reason = "tap-had-no-observed-effect"
        } else {
            reason = "button-value-read-inconsistent-or-unavailable"
        }
        XCTAssertTrue(
            paused,
            "After pausing, the control value must be play. (\(reason); before=\(initialValue), after=\(observedValues.sorted()), \(action.diagnostic))"
        )
        print(
            "IOSDriver Pause: successorPaused=\(paused), before=\(initialValue), after=\(observedValues.sorted()), \(action.diagnostic)"
        )
    }

    func next() {
        let identifier = "slideshow.control.next.button"
        let deadline = Date().addingTimeInterval(UITestSupportWaitTiming.stateChangeTimeoutSeconds)
        let totalDeadline = deadline.addingTimeInterval(UITestSupportWaitTiming.stateChangeTimeoutSeconds)
        var action = ControlAction()
        // Classifying the baseline can outlast auto-hide; only prepare the control afterward.
        var sceneBefore: String?
        _ = Wait.until(timeout: max(.zero, deadline.timeIntervalSinceNow)) {
            guard Date() < deadline else { return false }
            let sceneReadStartedAt = ProcessInfo.processInfo.systemUptime
            defer { action.sceneReadSeconds += ProcessInfo.processInfo.systemUptime - sceneReadStartedAt }
            let observation = visiblePhotoObservation()
            action.sceneCaptureSeconds += observation.captureSeconds
            action.sceneClassificationSeconds += observation.classificationSeconds
            sceneBefore = observation.mark
            return sceneBefore != nil && Date() < deadline
        }
        guard let sceneBefore, Date() < deadline else {
            XCTFail("The current scene must be readable before tapping Next. (\(action.diagnostic))")
            return
        }
        if !action.didWake, Date() < deadline {
            action.didWake = true
            FirstFailureContext.mark("reveal-controls", element: identifier)
            let revealStartedAt = Date()
            // EXIF passes hits through; the upper photo area stays clear of the bar, tip and DEBUG buttons.
            let playbackWakePoint = CGVector(dx: 0.5, dy: 0.2)
            FirstFailureContext.action("tap") {
                app.coordinate(withNormalizedOffset: playbackWakePoint).tap()
            }
            let duration = Date().timeIntervalSince(revealStartedAt)
            action.timing.revealSeconds += duration
            action.timing.revealDurationsSeconds.append(duration)
        }
        // Keep the pre-wake remainder; XCTest wake delivery is recorded separately from readiness.
        let preparationDeadline = deadline.addingTimeInterval(action.timing.revealSeconds)
        guard
            let before = prepareControl(
                identifier, until: preparationDeadline, action: &action, shouldRequireHittability: false)
        else {
            XCTFail("Final Next preparation must provide an actionable control. (\(action.diagnostic))")
            return
        }
        activateControl(before, action: &action)
        // Exclude only the measured wake from the original preparation plus outcome ceiling.
        let stateDeadline = min(
            totalDeadline.addingTimeInterval(action.timing.revealSeconds),
            Date().addingTimeInterval(UITestSupportWaitTiming.stateChangeTimeoutSeconds))
        var lastVisiblePhoto: String?
        var lastCaptureRemainingSeconds: TimeInterval?
        let changed = Wait.until(timeout: max(.zero, stateDeadline.timeIntervalSinceNow)) {
            guard Date() < stateDeadline else { return false }
            let verifyStartedAt = Date()
            defer { action.timing.verifySeconds += Date().timeIntervalSince(verifyStartedAt) }
            let observation = visiblePhotoObservation()
            lastCaptureRemainingSeconds = stateDeadline.timeIntervalSince(observation.capturedAt)
            guard observation.capturedAt < stateDeadline, let sceneAfter = observation.mark else { return false }
            lastVisiblePhoto = sceneAfter
            return sceneAfter != sceneBefore
        }
        XCTAssertTrue(
            changed,
            "One Next tap must change the visible scene. (before=\(sceneBefore), after=\(lastVisiblePhoto ?? "unrecognized"), captureRemainingSeconds=\(lastCaptureRemainingSeconds.map(String.init(describing:)) ?? "unknown"), \(action.diagnostic))"
        )
        print(
            "IOSDriver Next: successorSceneChanged=\(changed), before=\(sceneBefore), after=\(lastVisiblePhoto ?? "unrecognized"), captureRemainingSeconds=\(lastCaptureRemainingSeconds.map(String.init(describing:)) ?? "unknown"), \(action.diagnostic)"
        )
    }

    func returnToPlayback() {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        for _ in 0..<12 {
            if settingsButton.exists && settingsButton.isHittable { return }
            if !isOnSettingsSurface() {
                revealControls()
                if settingsButton.waitForPublicElement(
                    "slideshow.control.settings.button", timeout: UITestSupportWaitTiming.readbackTimeoutSeconds)
                {
                    return
                }
            }
            let globalBack = app.buttons["global.back.button"]
            if globalBack.exists && globalBack.isHittable {
                tap(globalBack)
                RunLoop.current.run(until: Date().addingTimeInterval(UITestSupportWaitTiming.identityPollSeconds))
                continue
            }
            let navigationButtons = app.navigationBars.buttons.allElementsBoundByIndex
            let backButton =
                navigationButtons.last { $0.exists && $0.isHittable && $0.identifier == "BackButton" }
                ?? navigationButtons.last { button in
                    button.exists && button.isHittable && button.identifier != "ToggleSidebar"
                        // ui-label-lookup: System navigation supplies the sidebar button label.
                        && !["显示边栏", "隐藏边栏", "Show Sidebar", "Hide Sidebar"].contains(button.label)
                }
            if let backButton {
                tap(backButton)
                RunLoop.current.run(until: Date().addingTimeInterval(UITestSupportWaitTiming.identityPollSeconds))
                continue
            }
            app.swipeDownForFailureEvidence()
        }
        XCTAssertTrue(
            settingsButton.waitForPublicElement(
                "slideshow.control.settings.button", timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "Must be able to return from settings to playback.")
    }

    func clearDiskCache(onCachePage: () throws -> Void) throws {
        openSettings()
        openCacheSection()
        let clearButton = app.buttons["settings.cache.clearDisk.button"]
        XCTAssertTrue(
            clearButton.waitForPublicElement(
                "settings.cache.clearDisk.button", timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "Cache page must provide the Clear Disk Cache button.")
        if !clearButton.isHittable { app.swipeUpForFailureEvidence() }
        try onCachePage()
        tap(clearButton)
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let alert = app.alerts["确认清理磁盘缓存"]
        XCTAssertTrue(
            alert.waitForFailureEvidence(timeout: UITestSupportWaitTiming.elementAppearanceTimeoutSeconds),
            "Tapping Clear must show the confirmation alert.")
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let confirm = alert.buttons.matching(NSPredicate(format: "label == %@", "清理")).firstMatch
        XCTAssertTrue(
            confirm.waitForFailureEvidence(timeout: UITestSupportWaitTiming.shortInteractionTimeoutSeconds),
            "Confirmation alert must offer Clear.")
        confirm.tapForFailureEvidence()
        waitForClearCompletion()
    }

    @discardableResult
    func openSettings(
        shouldAllowPINEntry: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Bool {
        let guardWait = TestWait.hangGuard()
        let target = guardWait.transaction()
        FirstFailureContext.beginWait(seconds: guardWait.remainingSeconds)
        defer { FirstFailureContext.endWait() }
        var action = ControlAction()
        action.timing.shouldVerifySettingsOutcome = true
        guard
            let before = prepareControl(
                "slideshow.control.settings.button", guardWait: guardWait, action: &action),
            target.perform("tap", { activateControl(before, action: &action) })
        else {
            XCTFail("Playback page must provide the settings entry. (\(action.diagnostic))", file: file, line: line)
            return false
        }
        let opened = target.until {
            let verifyStartedAt = Date()
            defer { action.timing.verifySeconds += Date().timeIntervalSince(verifyStartedAt) }
            let observation = action.observe(app: app, identifier: "slideshow.control.settings.button")
            action.timing.hasSettingsOutcome = observation?.hasSettingsOutcome == true
            let hasPINEntry = shouldAllowPINEntry && observation?.snapshots["pinEntry.close.button"] != nil
            return action.timing.hasSettingsOutcome || hasPINEntry
        }
        XCTAssertTrue(
            opened, "Tapping settings must open the settings page. (\(action.diagnostic))", file: file, line: line)
        print("IOSDriver Settings: successorObserved=\(opened), \(action.diagnostic)")
        return opened
    }

    // On iPad the split view shows playback settings on the right by default; iPhone goes through the list.
    private func openPlaybackSection() {
        let autoPlay = app.switches["settings.playback.autoPlay.toggle"]
        if autoPlay.waitForPublicElement(
            "settings.playback.autoPlay.toggle", timeout: UITestSupportWaitTiming.readbackTimeoutSeconds)
        {
            return
        }
        showSidebarIfCollapsed()
        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForPublicElement(
                "settings.item.playback", timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings list must have the playback settings entry.")
        playbackItem.tapForFailureEvidence()
        if !Wait.until(
            timeout: UITestSupportWaitTiming.readbackTimeoutSeconds,
            { autoPlay.exists || app.staticTexts["settings.playback.title"].exists })
        {
            app.cells.element(boundBy: 0).tapForFailureEvidence()
        }
        XCTAssertTrue(
            Wait.until(timeout: TestWait.seconds(.product(10))) {
                autoPlay.exists || app.staticTexts["settings.playback.title"].exists
            },
            "After opening playback settings, the auto-play toggle or the playback settings title must be visible."
        )
    }

    private func openCacheSection() {
        showSidebarIfCollapsed()
        let clearButton = app.buttons["settings.cache.clearDisk.button"]
        for attempt in 0..<6 {
            let candidates = [
                app.buttons["settings.item.cache"],
                app.descendants(matching: .any).matching(identifier: "settings.item.cache").firstMatch,
                app.staticTexts["settings.item.cache"]
            ]
            if let entry = candidates.first(where: {
                $0.waitForFailureEvidence(timeout: UITestSupportWaitTiming.briefElementTimeoutSeconds)
            }) {
                tap(entry)
                if clearButton.waitForPublicElement(
                    "settings.cache.clearDisk.button", timeout: UITestSupportWaitTiming.stateChangeTimeoutSeconds)
                {
                    return
                }
            }
            if attempt % 2 == 0 { app.swipeUpForFailureEvidence() } else { app.swipeDownForFailureEvidence() }
        }
        XCTFail("Settings list must be able to open cache management.")
    }

    private func showSidebarIfCollapsed() {
        let sidebar = app.buttons["ToggleSidebar"]
        // ui-label-lookup: System navigation supplies the sidebar button label.
        if sidebar.exists && ["显示边栏", "Show Sidebar"].contains(sidebar.label) {
            tap(sidebar)
        }
    }

    private func isOnSettingsSurface() -> Bool {
        let identifiers = [
            "settings.item.playback", "settings.playback.title", "settings.accessProtection.title",
            "settings.server.title", "settings.cache.title", "settings.about.title",
            "settings.about.opensource.page"
        ]
        if identifiers.contains(where: { app.descendants(matching: .any)[$0].exists }) { return true }
        return app.buttons["settings.item.playback"].exists
            || app.switches["settings.playback.autoPlay.toggle"].exists
            || app.buttons["settings.cache.clearDisk.button"].exists
    }

    // For orientation steady-state evidence: wake the control bar if it is hidden, then require play / next /
    // settings to all be tappable.
    func revealUsableControls(recordWake: ((TimeInterval) -> Void)? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(UITestSupportWaitTiming.shortInteractionTimeoutSeconds)
        var action = ControlAction()
        let prepared = prepareControl(
            "slideshow.control.playPause.button", until: deadline, action: &action,
            alsoRequiring: ["slideshow.control.next.button", "slideshow.control.settings.button"])
        action.timing.revealDurationsSeconds.forEach { recordWake?($0) }
        return prepared != nil
    }

    private struct ControlAction {
        var timing = SlideshowControlBarTiming()
        var didWake = false
        var isHittable: Bool?
        var isBarVisible = false
        var preparedTarget = "unknown"
        var preparedAt: TimeInterval?
        var sceneReadSeconds: TimeInterval = .zero
        var sceneCaptureSeconds: TimeInterval = .zero
        var sceneClassificationSeconds: TimeInterval = .zero
        var issuedAt: TimeInterval?
        var returnedAt: TimeInterval?

        mutating func observe(app: XCUIApplication, identifier: String) -> SlideshowControlBarButtonObservation? {
            timing.observe(app: app, identifier: identifier)
        }

        var diagnostic: String {
            let actionableToTapSeconds = preparedAt.flatMap { preparedAt in issuedAt.map { $0 - preparedAt } }
            return
                "\(timing.diagnostic), preparedTarget={\(preparedTarget)}, barVisible=\(isBarVisible), hittable=\(isHittable.map(String.init) ?? "unknown"), wakeIssued=\(didWake), sceneReadSeconds=\(sceneReadSeconds), sceneCaptureSeconds=\(sceneCaptureSeconds), sceneClassificationSeconds=\(sceneClassificationSeconds), actionableToTapSeconds=\(actionableToTapSeconds.map(String.init(describing:)) ?? "none"), tapIssuedAt=\(issuedAt.map(String.init(describing:)) ?? "none"), tapReturnedAt=\(returnedAt.map(String.init(describing:)) ?? "none")"
        }
    }

    private func hasVisibleControlBar(_ observation: SlideshowControlBarButtonObservation) -> Bool {
        ["settings", "playPause", "next"].allSatisfy { name in
            guard let button = observation.snapshots["slideshow.control.\(name).button"],
                button.elementType == .button, !button.frame.isEmpty
            else { return false }
            return observation.windowFrame.contains(button.frame)
        }
    }

    private func prepareControl(
        _ identifier: String, guardWait: TestWait.HangGuard, action: inout ControlAction
    ) -> SlideshowControlBarButtonObservation? {
        let preparation = guardWait.transaction()
        let prompt = guardWait.transaction()
        let wake = guardWait.transaction()
        var observing = preparation
        let navigation = IOSFirstBootNavigation(app: app)
        while guardWait.remainingSeconds > 0 {
            guard navigation.dismissPasswordPrompt(guardWait: guardWait, transaction: prompt) else {
                RunLoop.current.run(
                    until: Date().addingTimeInterval(
                        min(UITestSupportWaitTiming.identityPollSeconds, guardWait.remainingSeconds)))
                continue
            }
            guard let captured = observing.query({ action.observe(app: app, identifier: identifier) })
            else { return nil }
            if let observation = captured {
                action.isBarVisible = hasVisibleControlBar(observation)
                if observation.isReady, action.isBarVisible {
                    action.isHittable = observing.query { observation.windowElement.buttons[identifier].isHittable }
                    if action.isHittable == true {
                        action.preparedTarget = observation.diagnostic
                        action.preparedAt = ProcessInfo.processInfo.systemUptime
                        return observation
                    }
                }
                if !action.didWake, !observation.hasSettingsNavigationEvidence {
                    action.didWake = wake.perform("tap") {
                        FirstFailureContext.mark("reveal-controls", element: identifier)
                        let startedAt = ProcessInfo.processInfo.systemUptime
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tapForFailureEvidence()
                        let duration = ProcessInfo.processInfo.systemUptime - startedAt
                        action.timing.revealSeconds += duration
                        action.timing.revealDurationsSeconds.append(duration)
                    }
                    if action.didWake { observing = wake }
                }
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(
                    min(UITestSupportWaitTiming.identityPollSeconds, guardWait.remainingSeconds)))
        }
        return nil
    }

    private func prepareControl(
        _ identifier: String, until originalDeadline: Date, action: inout ControlAction,
        shouldDismissPasswordPrompt: Bool = false, alsoRequiring additionalIdentifiers: [String] = [],
        shouldRequireHittability: Bool = true
    ) -> SlideshowControlBarButtonObservation? {
        let deadline = originalDeadline
        FirstFailureContext.beginWait(seconds: max(.zero, deadline.timeIntervalSinceNow))
        defer { FirstFailureContext.endWait() }
        while Date() < deadline {
            if shouldDismissPasswordPrompt {
                guard IOSFirstBootNavigation(app: app).dismissPasswordPrompt(until: deadline), Date() < deadline else {
                    return nil
                }
            }
            if let observation = action.observe(app: app, identifier: identifier), Date() < deadline {
                action.isBarVisible = hasVisibleControlBar(observation)
                action.isHittable = nil
                if observation.isReady, action.isBarVisible,
                    shouldRequireHittability || !observation.hasSettingsNavigationEvidence
                {
                    // Next uses the enabled, visible snapshot frame after its sole wake, without live re-resolution.
                    if !shouldRequireHittability {
                        action.preparedTarget = observation.diagnostic
                        action.preparedAt = ProcessInfo.processInfo.systemUptime
                        return observation
                    }
                    // Snapshot attributes are fallible; XCTest exposes hittability only on the live button.
                    action.isHittable = ([identifier] + additionalIdentifiers).allSatisfy { requiredIdentifier in
                        guard Date() < deadline, let button = observation.snapshots[requiredIdentifier],
                            button.elementType == .button, button.isEnabled, !button.frame.isEmpty,
                            observation.windowFrame.contains(button.frame)
                        else { return false }
                        return observation.windowElement.buttons[requiredIdentifier].wait(
                            for: \.isHittable, toEqual: true,
                            timeout: min(
                                UITestSupportWaitTiming.identityPollSeconds, max(.zero, deadline.timeIntervalSinceNow)))
                    }
                    if action.isHittable == true, Date() < deadline {
                        action.preparedTarget = observation.diagnostic
                        action.preparedAt = ProcessInfo.processInfo.systemUptime
                        return observation
                    }
                }
                if !action.didWake, !observation.hasSettingsNavigationEvidence, Date() < deadline {
                    action.didWake = true
                    FirstFailureContext.mark("reveal-controls", element: identifier)
                    let revealStartedAt = Date()
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tapForFailureEvidence()
                    let duration = Date().timeIntervalSince(revealStartedAt)
                    action.timing.revealSeconds += duration
                    action.timing.revealDurationsSeconds.append(duration)
                }
            }
            guard Date() < deadline else { break }
            RunLoop.current.run(
                until: min(deadline, Date().addingTimeInterval(UITestSupportWaitTiming.identityPollSeconds)))
        }
        return nil
    }

    private func activateControl(_ observation: SlideshowControlBarButtonObservation, action: inout ControlAction) {
        guard let button = observation.button else { return }
        FirstFailureContext.mark("select", element: observation.identifier)
        action.timing.tapCount += 1
        action.issuedAt = ProcessInfo.processInfo.systemUptime
        // Use the observed target frame once; never fall back to a hidden receiver or re-resolve a disappearing button.
        observation.windowElement.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(
                dx: button.frame.midX - observation.windowFrame.minX,
                dy: button.frame.midY - observation.windowFrame.minY)
        ).tapForFailureEvidence()
        action.returnedAt = ProcessInfo.processInfo.systemUptime
        let duration = (action.returnedAt ?? .zero) - (action.issuedAt ?? .zero)
        action.timing.tapSeconds += duration
        action.timing.tapDurationsSeconds.append(duration)
    }

    private func playPauseValue(_ observation: SlideshowControlBarButtonObservation) -> String {
        guard let button = observation.snapshots["slideshow.control.playPause.button"] else { return "notVisible" }
        return ((button.value as? String) ?? "").lowercased()
    }

    private func visiblePhotoObservation() -> (
        mark: String?, capturedAt: Date, captureSeconds: TimeInterval, classificationSeconds: TimeInterval
    ) {
        let captureStartedAt = ProcessInfo.processInfo.systemUptime
        let screenshot = app.screenshotForFailureEvidence()
        // Classification can be slow; only the acquisition of this immutable frame belongs to the deadline.
        let capturedAt = Date()
        let png = screenshot.pngRepresentation
        let classificationStartedAt = ProcessInfo.processInfo.systemUptime
        let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
        return (
            identity.navigationMark, capturedAt,
            classificationStartedAt - captureStartedAt,
            ProcessInfo.processInfo.systemUptime - classificationStartedAt
        )
    }

    private func revealControls(until originalDeadline: Date? = nil, shouldDismissPasswordPrompt: Bool = false) {
        let deadline =
            originalDeadline ?? Date().addingTimeInterval(UITestSupportWaitTiming.shortInteractionTimeoutSeconds)
        var action = ControlAction()
        _ = prepareControl(
            "slideshow.control.settings.button", until: deadline, action: &action,
            shouldDismissPasswordPrompt: shouldDismissPasswordPrompt)
    }

    private func waitForPlaybackControls(_ departure: IOSFirstBootNavigation.ModeDeparture) -> Bool {
        let guardWait = departure.guardWait
        let hint = guardWait.transaction()
        let readiness = guardWait.transaction()
        let wake = guardWait.transaction()
        let navigation = IOSFirstBootNavigation(app: app)
        let identifier = "slideshow.control.settings.button"
        let settings = departure.observation.windowElement.buttons[identifier]
        let readSettingsHittability = {
            FirstFailureContext.mark("query-element", element: identifier)
            return settings.isHittable
        }
        FirstFailureContext.mark("query-element", element: identifier)
        FirstFailureContext.beginWait(seconds: guardWait.remainingSeconds)
        defer { FirstFailureContext.endWait() }
        guard
            readiness.until({
                navigation.dismissPasswordPrompt(guardWait: guardWait, transaction: departure.passwordPromptTransaction)
            })
        else { return false }
        let banner = app.descendants(matching: .any).matching(identifier: "slideshow.entryHint.banner").firstMatch
        if hint.probe({ banner.exists }) {
            guard let isHittable = hint.query({ banner.isHittable }),
                hint.perform(
                    "tap",
                    {
                        if isHittable {
                            banner.tapForFailureEvidence()
                        } else {
                            banner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapForFailureEvidence()
                        }
                    })
            else { return false }
            if hint.probe(readSettingsHittability) { return true }
        } else if readiness.probe(readSettingsHittability) {
            return true
        }
        guard
            readiness.until({
                navigation.dismissPasswordPrompt(guardWait: guardWait, transaction: departure.passwordPromptTransaction)
            })
        else { return false }
        if readiness.probe(readSettingsHittability) { return true }
        guard
            wake.perform(
                "tap",
                {
                    FirstFailureContext.mark("reveal-controls", element: identifier)
                    let startedAt = ProcessInfo.processInfo.systemUptime
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tapForFailureEvidence()
                    print(
                        "Playback entry wake returned: actionSeconds=\(ProcessInfo.processInfo.systemUptime - startedAt)"
                    )
                })
        else { return false }
        // A late wake can finish readiness with its one direct live observation.
        return wake.until(readSettingsHittability)
    }

    private func waitForSaveEnabled(_ save: XCUIElement) -> Bool {
        FirstFailureContext.mark("query-element", element: "firstboot.saveConfig.button")
        return Wait.until(timeout: UITestSupportWaitTiming.sceneReadyTimeoutSeconds) {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            // ui-label-lookup: The local-network permission alert belongs to iOS.
            for label in ["允许", "Allow"] where springboard.alerts.buttons[label].exists {
                // ui-label-lookup: The permission action belongs to SpringBoard.
                springboard.alerts.buttons[label].tapForFailureEvidence()
            }
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let alert = app.alerts.firstMatch
            if alert.exists {
                XCTFail("Connection test showed a failure alert: \(alert.label)")
                return true
            }
            return save.exists && save.isEnabled
        }
    }

    private func replaceText(in field: XCUIElement, with value: String) {
        field.tapForFailureEvidence()
        let existing = field.value as? String ?? ""
        let isPlaceholder = existing.contains("请输入") || existing.localizedCaseInsensitiveContains("enter")
        if !existing.isEmpty && !isPlaceholder {
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        }
        field.typeForFailureEvidence(value)
    }

    private func secureFieldHasValue(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return !value.isEmpty && !value.contains("请输入") && !value.localizedCaseInsensitiveContains("api key")
    }

    private func commitFocusedInput() {
        let done = app.buttons["server.keyboard.done.button"]
        if done.exists && done.isHittable {
            done.tapForFailureEvidence()
            return
        }
        // ui-label-lookup: System keyboard submit keys follow the simulator language.
        for label in ["完成", "Done", "next", "Next"] {
            // ui-label-lookup: System keyboard submit keys follow the simulator language.
            let button = app.keyboards.buttons[label]
            if button.exists && button.isHittable {
                button.tapForFailureEvidence()
                return
            }
        }
    }

    private func control(_ identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        let identified = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if identified.exists { return identified }
        return identified
    }

    private func tap(_ element: XCUIElement) {
        if element.isHittable {
            element.tapForFailureEvidence()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapForFailureEvidence()
        }
    }

    private func isToggleOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }

}
#endif
