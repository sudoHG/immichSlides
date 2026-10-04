import XCTest

#if os(tvOS)
final class StrictE2ELateImageTVOSUITests: XCTestCase {
    private enum Timing {
        static let focusMovementSettleSeconds: TimeInterval = 0.08
        static let focusPollingSeconds: TimeInterval = 0.05
        // The right-move settle must be far shorter than the 1600ms delay so both nexts land inside the window.
        static let immediateFocusSettleSeconds: TimeInterval = 0.04
        // Preview and fullsize for asset-*-1 are each delayed 1600ms; 2.5s covers the late completion.
        static let lateRequestWaitSeconds: TimeInterval = 2.5
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
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try configureServerThroughFirstBoot(app: app, input: input)
        try enterRandomPlayback(app: app)

        let settingsButton = app.buttons["slideshow.control.settings.button"]
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        let nextButton = app.buttons["slideshow.control.next.button"]
        // Press next twice first: running the focus/Select checks earlier would wait out the old requests.
        enterPlaybackThenAdvanceTwice(nextButton: nextButton)
        let secondNextAt = Date()
        try writeRequiredPNG(app: app, name: "ooo-current-scene")
        attachScreenshot(app: app, name: "tvos-late-image-ooo-current-scene")

        RunLoop.current.run(until: Date().addingTimeInterval(Timing.lateRequestWaitSeconds))
        let afterLateAt = Date()
        try writeRequiredPNG(app: app, name: "ooo-after-late")
        attachScreenshot(app: app, name: "tvos-late-image-ooo-after-late")

        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: 5),
            "After the late completion, Play/Pause must still be reachable.")
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 5), "After the late completion, Settings must still be reachable.")
        if nextButton.hasFocus {
            attachScreenshot(app: app, name: "tvos-late-image-default-focus-next")
        } else if settingsButton.hasFocus {
            attachScreenshot(app: app, name: "tvos-late-image-default-focus-settings")
        } else {
            XCTAssertTrue(
                waitForFocus(on: playPauseButton, timeout: 6), "After the late completion, focus must be identifiable.")
            attachScreenshot(app: app, name: "tvos-late-image-default-focus-playpause")
        }
        attachFocusAudit(app: app, name: "tvos-late-image-default-focus")

        moveFocus(
            .left, to: playPauseButton, maximumPresses: 2,
            message: "After the late completion, focus must be able to return to Play/Pause.")
        XCTAssertTrue(
            waitForFocus(on: playPauseButton, timeout: 4),
            "After the late completion, the default action must stay focusable.")
        let pausedValue = String(describing: playPauseButton.value ?? "")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: 4) { String(describing: playPauseButton.value ?? "") != pausedValue },
            "After the late completion, Select must still toggle Play/Pause."
        )
        attachScreenshot(app: app, name: "tvos-late-image-select-after-late")

        moveFocus(
            .right, to: nextButton, maximumPresses: 2,
            message: "After the late completion, focus must be able to move to Next.")
        XCTAssertTrue(waitForFocus(on: nextButton, timeout: 4), "Next must be focusable.")
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
            randomButton.waitForExistence(timeout: 15), "After saving the settings, the mode selection page must open.")
        XCTAssertTrue(
            waitForFocus(on: randomButton, timeout: 5),
            "Default focus on the mode selection page must land on Random Playback.")
        XCUIRemote.shared.press(.select)
        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 5),
            "After choosing Random Playback, the Continue button must be shown.")
        XCTAssertTrue(continueButton.isEnabled, "After choosing Random Playback, the Continue button must be enabled.")
        moveFocus(
            .down, to: continueButton, maximumPresses: 2,
            message: "After choosing Random Playback, focus must be able to move down to the Continue button.")
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    private func enterPlaybackThenAdvanceTwice(nextButton: XCUIElement) {
        XCTAssertTrue(
            waitUntil(timeout: 30) { nextButton.exists },
            "Random mode must quickly reach a slideshow where Next works, without waiting for old image requests."
        )
        // Default focus is on Settings: only move right to Next and press it twice, without the 4s focus polling.
        focusImmediately(on: nextButton, direction: .right, maximumPresses: 3)
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    private func focusImmediately(
        on element: XCUIElement,
        direction: XCUIRemote.Button,
        maximumPresses: Int
    ) {
        for _ in 0..<maximumPresses {
            if element.exists && element.hasFocus { return }
            XCUIRemote.shared.press(direction)
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.immediateFocusSettleSeconds))
        }
        XCTAssertTrue(element.exists && element.hasFocus, "Focus must land on Next before the old requests complete.")
    }

    @MainActor
    private func configureServerThroughFirstBoot(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 12), "A clean install must open the first-launch form.")
        replaceFocusedText(in: serverField, app: app, with: input.serverURL)

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 8), "The first-launch form must show the API Key field.")
        moveFocus(
            .down, to: apiKeyField, maximumPresses: 2,
            message: "After the URL is submitted, focus must be able to move down to the API Key.")
        replaceFocusedText(in: apiKeyField, app: app, with: input.publicKey)

        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(
            testConnectionButton.waitForExistence(timeout: 5),
            "The first-launch form must show the Test Connection button.")
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.right)
        attachFocusAudit(app: app, name: "tvos-late-image-firstboot-before-test-connection")
        XCUIRemote.shared.press(.select)

        let success = app.staticTexts["firstboot.connection.success"]
        XCTAssertTrue(
            success.waitForExistence(timeout: 45),
            "Once the real controlled server is reachable, the connection test must show as passed.")

        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 5),
            "After a successful connection, the Save Settings button must be shown.")
        XCTAssertTrue(saveButton.isEnabled, "After a successful connection, Save Settings must be enabled.")
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
        XCTAssertTrue(submit.hasFocus, "The system keyboard submit button must be focused before submitting text.")
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.menu)

        if field.identifier == "firstboot.serverURL.field" {
            XCTAssertEqual(field.value as? String, value, "The server address must be submitted unchanged.")
        }
        XCTAssertTrue(
            waitForFocus(on: field, timeout: 4), "After submitting text, focus must return to the original field.")
    }

    // Arrow-key settle is shorter than polling: it only proves system focus and does not trust @FocusState.
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
    private func ensureControlBarVisible(app: XCUIApplication, playPauseButton: XCUIElement) {
        if !playPauseButton.exists {
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: 5), "An arrow key must be able to wake the playback control bar.")
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
        let png = app.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
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
        if focused.waitForExistence(timeout: 0) {
            focusedLines.append(StrictE2ELateImageFocusAudit.auditLine(for: focused))
        } else {
            for identifier in StrictE2ELateImageFocusAudit.knownIdentifiers {
                let element = app.descendants(matching: .any)[identifier]
                guard element.waitForExistence(timeout: 0), element.hasFocus else { continue }
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
        let identifiedElement = app.descendants(matching: .any)[identifier]
        if identifiedElement.exists { return identifiedElement }
        return identifiedElement
    }
}
#endif
