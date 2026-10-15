import XCTest

#if os(tvOS)
final class StrictE2ELateImageTVOSUITests: XCTestCase {
    private enum Timing {
        static let focusMovementSettleSeconds: TimeInterval = TestWait.seconds(.product(0.08))
        static let focusPollingSeconds: TimeInterval = TestWait.seconds(.product(0.05))
        // Preserve the post-delivery observation window; the fixture now confirms delivery first.
        static let lateRequestWaitSeconds: TimeInterval = TestWait.seconds(.product(2.5))
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTVOSLateImageDoesNotFlashBack() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The tvOS out-of-order visible identity test must run on a tvOS Simulator.")
            return
        }

        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp(recordSceneSequence: true)
        defer { app.terminate() }

        try configureServerThroughFirstBoot(app: app, input: input)
        _ = try lateImageControl(input: input, action: "arm")
        try enterRandomPlayback(app: app)

        let settingsButton = app.buttons["slideshow.control.settings.button"]
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        let nextButton = app.buttons["slideshow.control.next.button"]
        try enterPlaybackThenAdvanceTwice(app: app, nextButton: nextButton)
        let secondNextAt = Date()
        try writeRequiredPNG(app: app, name: "ooo-current-scene")
        attachScreenshot(app: app, name: "tvos-late-image-ooo-current-scene")

        try releaseLateImageAndWaitForDelivery(input: input)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.lateRequestWaitSeconds))
        let afterLateAt = Date()
        try writeRequiredPNG(app: app, name: "ooo-after-late")
        attachScreenshot(app: app, name: "tvos-late-image-ooo-after-late")

        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: TestWait.seconds(.product(5))),
            "After the late completion, Play/Pause must still be reachable.")
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: TestWait.seconds(.product(5))),
            "After the late completion, Settings must still be reachable.")
        if nextButton.hasFocus {
            attachScreenshot(app: app, name: "tvos-late-image-default-focus-next")
        } else if settingsButton.hasFocus {
            attachScreenshot(app: app, name: "tvos-late-image-default-focus-settings")
        } else {
            XCTAssertTrue(
                waitForFocus(on: playPauseButton, timeout: TestWait.seconds(.product(6))),
                "After the late completion, focus must be identifiable.")
            attachScreenshot(app: app, name: "tvos-late-image-default-focus-playpause")
        }
        attachFocusAudit(app: app, name: "tvos-late-image-default-focus")

        moveFocus(
            .left, to: playPauseButton, maximumPresses: 2,
            message: "After the late completion, focus must be able to return to Play/Pause.")
        XCTAssertTrue(
            waitForFocus(on: playPauseButton, timeout: TestWait.seconds(.product(4))),
            "After the late completion, the default action must stay focusable.")
        let pausedValue = (try? playPauseButton.snapshot()).map { String(describing: $0.value ?? "") }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(4))) {
                guard let snapshot = try? playPauseButton.snapshot() else { return false }
                return String(describing: snapshot.value ?? "") != pausedValue
            },
            "After the late completion, Select must still toggle Play/Pause."
        )
        attachScreenshot(app: app, name: "tvos-late-image-select-after-late")

        moveFocus(
            .right, to: nextButton, maximumPresses: 2,
            message: "After the late completion, focus must be able to move to Next.")
        XCTAssertTrue(waitForFocus(on: nextButton, timeout: TestWait.seconds(.product(4))), "Next must be focusable.")
        assertNoFocusCollision(focused: nextButton, neighbor: playPauseButton)
        attachScreenshot(app: app, name: "tvos-late-image-next-focused")
        attachFocusAudit(app: app, name: "tvos-late-image-after-late-focus")

        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "suite": "late-image",
                "environment": "simulator",
                "identity_source": "public_fixture_photo_mark",
                "request_log_is_not_identity": true,
                "second_next_unix": secondNextAt.timeIntervalSince1970,
                "after_late_unix": afterLateAt.timeIntervalSince1970,
                "late_wait_seconds": Timing.lateRequestWaitSeconds
            ],
            name: "operation-timeline.json"
        )
    }

    @MainActor
    private func enterRandomPlayback(app: XCUIApplication) throws {
        let randomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(
            randomButton.waitForExistence(timeout: TestWait.seconds(.product(15))),
            "After saving the settings, the mode selection page must open.")
        XCTAssertTrue(
            waitForFocus(on: randomButton, timeout: TestWait.seconds(.product(5))),
            "Default focus on the mode selection page must land on Random Playback.")
        XCUIRemote.shared.press(.select)
        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: TestWait.seconds(.product(5))),
            "After choosing Random Playback, the Continue button must be shown.")
        XCTAssertTrue(continueButton.isEnabled, "After choosing Random Playback, the Continue button must be enabled.")
        moveFocus(
            .down, to: continueButton, maximumPresses: 2,
            message: "After choosing Random Playback, focus must be able to move down to the Continue button.")
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    private func enterPlaybackThenAdvanceTwice(app: XCUIApplication, nextButton: XCUIElement) throws {
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(30))) { (try? nextButton.snapshot())?.isEnabled == true },
            "Random mode must quickly reach a slideshow where Next works, without waiting for old image requests."
        )
        let playPause = app.buttons["slideshow.control.playPause.button"]
        ensureControlBarVisible(app: app, playPauseButton: playPause)
        moveFocus(
            .left, to: playPause, maximumPresses: 3,
            message: "Focus must land on Next before the old requests complete.")
        let render = SharedSceneEvidenceManifest.parseKeyValueFields(
            strictSceneFrameObservation(app: app)["render"] ?? "")
        if render["playbackPaused"] != "true" { XCUIRemote.shared.press(.select) }
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(4))) {
                SharedSceneEvidenceManifest.parseKeyValueFields(
                    self.strictSceneFrameObservation(app: app)["render"] ?? "")["playbackPaused"] == "true"
            }, "Random mode must quickly reach a slideshow where Next works, without waiting for old image requests.")
        let initialHistory = try XCTUnwrap(lateImageHistoryCount(app: app))
        moveFocus(
            .right, to: nextButton, maximumPresses: 3,
            message: "Focus must land on Next before the old requests complete.")
        let deadline = ProcessInfo.processInfo.systemUptime + TestWait.seconds(.product(30))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForLateImageScene(app: app, historyCount: initialHistory + 1, deadline: deadline),
            "Random mode must quickly reach a slideshow where Next works, without waiting for old image requests.")
        ensureControlBarVisible(app: app, playPauseButton: playPause)
        moveFocus(
            .right, to: nextButton, maximumPresses: 3,
            message: "Focus must land on Next before the old requests complete.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForLateImageScene(app: app, historyCount: initialHistory + 2, deadline: deadline),
            "Random mode must quickly reach a slideshow where Next works, without waiting for old image requests.")
    }

    @MainActor
    private func configureServerThroughFirstBoot(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForExistence(timeout: TestWait.seconds(.infrastructure(12))),
            "A clean install must open the first-launch form.")
        replaceFocusedText(in: serverField, app: app, with: input.serverURL)

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "The first-launch form must show the API Key field.")
        moveFocus(
            .down, to: apiKeyField, maximumPresses: 2,
            message: "After the URL is submitted, focus must be able to move down to the API Key.")
        replaceFocusedText(in: apiKeyField, app: app, with: input.publicKey)

        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(
            testConnectionButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(5))),
            "The first-launch form must show the Test Connection button.")
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.right)
        attachFocusAudit(app: app, name: "tvos-late-image-firstboot-before-test-connection")
        XCUIRemote.shared.press(.select)

        let success = app.staticTexts["firstboot.connection.success"]
        XCTAssertTrue(
            success.waitForExistence(timeout: TestWait.seconds(.infrastructure(45))),
            "Once the real controlled server is reachable, the connection test must show as passed.")

        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(5))),
            "After a successful connection, the Save Settings button must be shown.")
        XCTAssertTrue(saveButton.isEnabled, "After a successful connection, Save Settings must be enabled.")
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    private func replaceFocusedText(in field: XCUIElement, app: XCUIApplication, with value: String) {
        XCTAssertTrue(
            waitForFocus(on: field, timeout: TestWait.seconds(.product(4))), "The field must be focused before typing.")
        XCUIRemote.shared.press(.select)
        app.typeText(value)

        let submit = app.buttons.matching(
            // ui-label-lookup: Match the simulator-localized system keyboard submit key.
            NSPredicate(format: "label IN %@", ["下一项", "Next", "完成", "Done"])
        ).firstMatch
        XCTAssertTrue(
            submit.waitForExistence(timeout: TestWait.seconds(.product(4))),
            "The system keyboard must show Next or Done.")
        for _ in 0..<6 where !submit.hasFocus {
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(submit.hasFocus, "The system keyboard submit button must be focused before submitting text.")
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.menu)

        if field.identifier == "firstboot.serverURL.field" {
            XCTAssertEqual(field.value as? String, value, "The server address must be submitted unchanged.")
        }
        XCTAssertTrue(
            waitForFocus(on: field, timeout: TestWait.seconds(.product(4))),
            "After submitting text, focus must return to the original field.")
    }

    // Each direction observes system focus before the next direction; missing snapshots cannot fail a poll.
    @MainActor
    private func moveFocus(
        _ direction: XCUIRemote.Button,
        to element: XCUIElement,
        maximumPresses: Int,
        message: String
    ) {
        let deadline = ProcessInfo.processInfo.systemUptime + TestWait.seconds(.product(4))
        let focused = XCUIApplication().descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == %@", NSNumber(value: true))).firstMatch
        for _ in 0..<maximumPresses where ProcessInfo.processInfo.systemUptime < deadline {
            if (try? element.snapshot())?.hasFocus == true { return }
            let previous = (try? focused.snapshot())?.identifier
            XCUIRemote.shared.press(direction)
            while ProcessInfo.processInfo.systemUptime < deadline {
                if (try? element.snapshot())?.hasFocus == true { return }
                if let current = try? focused.snapshot(), current.hasFocus,
                    !current.identifier.isEmpty, current.identifier != previous
                {
                    break
                }
                RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPollingSeconds))
            }
        }
        XCTAssertTrue((try? element.snapshot())?.hasFocus == true, message)
    }

    @MainActor
    private func waitForFocus(on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? element.snapshot())?.hasFocus == true { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPollingSeconds))
        }
        return (try? element.snapshot())?.hasFocus == true
    }

    @MainActor
    private func ensureControlBarVisible(app: XCUIApplication, playPauseButton: XCUIElement) {
        let deadline = ProcessInfo.processInfo.systemUptime + TestWait.seconds(.product(5))
        let receiver = app.descendants(matching: .any)["slideshow.hiddenWakeReceiver"]
        for _ in 0..<2 {
            while ProcessInfo.processInfo.systemUptime < deadline {
                if (try? playPauseButton.snapshot()) != nil { return }
                if (try? receiver.snapshot())?.hasFocus == true { break }
                RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPollingSeconds))
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(
            (try? playPauseButton.snapshot()) != nil,
            "An arrow key must be able to wake the playback control bar.")
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

    @MainActor
    private func writeRequiredPNG(app: XCUIApplication, name: String) throws {
        let before = strictSceneFrameObservation(app: app)
        let png = app.screenshot().pngRepresentation
        let after = strictSceneFrameObservation(app: app)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
        attachStrictSceneObservation(before: before, after: after, name: "\(name)-scene")
        XCTAssertTrue(
            [before, after].allSatisfy(StrictE2ESceneCapture.isStableWindow),
            "After late completion the current public mark must stay: no flash back, all black or unreadable: unstable capture"
        )
    }

    private func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // The live tree can shrink, so stale allElementsBoundByIndex indexes are not allowed. Unidentifiable focus fails.
    private func attachFocusAudit(app: XCUIApplication, name: String) {
        var focusedLines: [String] = []
        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == %@", NSNumber(value: true)))
            .firstMatch
        if focused.waitForExistence(timeout: TestWait.seconds(.product(0))) {
            focusedLines.append(StrictE2ELateImageFocusAudit.auditLine(for: focused))
        } else {
            for identifier in StrictE2ELateImageFocusAudit.knownIdentifiers {
                let element = app.descendants(matching: .any)[identifier]
                guard element.waitForExistence(timeout: TestWait.seconds(.product(0))), element.hasFocus else {
                    continue
                }
                focusedLines.append(StrictE2ELateImageFocusAudit.auditLine(for: element))
            }
        }
        if let body = StrictE2ELateImageFocusAudit.attachmentBody(fromFocusedLines: focusedLines) {
            let attachment = XCTAttachment(string: body)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return
        }
        let attachment = XCTAttachment(string: "no-focused-element")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("Focus is not identifiable: \(name)")
    }

    private func assertNoFocusCollision(focused: XCUIElement, neighbor: XCUIElement) {
        XCTAssertTrue(focused.exists, "The focused element must exist to check for collisions.")
        XCTAssertTrue(
            neighbor.exists,
            "If the neighbor element is missing, the focus scale-up collision is unverified and cannot pass.")
        let intersection = focused.frame.intersection(neighbor.frame)
        XCTAssertTrue(
            intersection.isNull || intersection.width < 1 || intersection.height < 1,
            "Focus scale-up must not collide with the neighbor: \(focused.identifier) vs \(neighbor.identifier)"
        )
    }

    private func firstBootControl(
        in app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        return app.descendants(matching: .any)[identifier]
    }
}
#endif
