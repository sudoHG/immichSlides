import XCTest

#if os(tvOS)
extension FilterSummaryTVOSVisualUITests {
    @MainActor
    func waitForSettingsHomeItem(
        app: XCUIApplication,
        identifier: String,
        downStepsFromPlayback: Int,
        failureMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {

        let playbackItem = waitForSettingsControl(
            app: app,
            identifier: "settings.item.playback",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Settings home should show the 'Playback Settings' entry",
            file: file,
            line: line
        )

        for _ in 0..<8 {
            if isSettingsControlFocused(playbackItem) {
                break
            }
            XCUIRemote.shared.press(.up)
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.remotePressSettleSeconds))
        }

        waitForButtonToGainFocus(
            playbackItem,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "Settings home should be able to bring focus back to the 'Playback Settings' entry",
            file: file,
            line: line
        )

        // Normalize focus, then take a fixed number of steps, so we never start from a random spot.

        for _ in 0..<downStepsFromPlayback {
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.remotePressSettleSeconds))
        }

        let target = waitForSettingsControl(
            app: app,
            identifier: identifier,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: failureMessage,
            file: file,
            line: line
        )

        waitForButtonToGainFocus(
            target,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: failureMessage,
            file: file,
            line: line
        )
        return target
    }

    func isSettingsControlFocused(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        return element.hasFocus || accessibilityValueString(for: element).contains("focused")
    }

    @MainActor
    func moveFocusToFilteredModeCard() {
        XCUIRemote.shared.press(.right)
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.selectionPollSeconds))
    }

    @MainActor
    func moveFocusToModeContinueButton() {
        XCUIRemote.shared.press(.down)
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.selectionPollSeconds))
    }

    @MainActor
    func moveFocusToPeopleCard() {
        XCUIRemote.shared.press(.right)
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.snapshotPollSeconds))
    }

    @MainActor
    func moveFocusToBackButton() {
        XCUIRemote.shared.press(.right)
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.selectionPollSeconds))
        XCUIRemote.shared.press(.right)
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.selectionPollSeconds))
        XCUIRemote.shared.press(.down)
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.selectionPollSeconds))
    }

    @MainActor
    func moveFocusToStartButton() {

        moveFocusToBackButton()
        XCUIRemote.shared.press(.up)
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.selectionPollSeconds))
    }

    @MainActor
    func openAlbumFilter(from app: XCUIApplication) {
        let albumButton = app.buttons["filterSummary.album.button"]
        XCTAssertTrue(
            albumButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    func openPersonFilter(from app: XCUIApplication) {
        let peopleButton = app.buttons["filterSummary.person.button"]
        XCTAssertTrue(
            peopleButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        XCUIRemote.shared.press(.right)
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.transitionPollSeconds))
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    func waitForAlbumFilterReady(app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let backButton = app.buttons["albumFilter.back.button"]
        XCTAssertTrue(
            backButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.screenTransitionTimeoutSeconds),
            "Album filter page should show the back button", file: file,
            line: line)
        let firstAlbumCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "albumFilter.album.")
        ).firstMatch
        XCTAssertTrue(
            firstAlbumCard.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.screenTransitionTimeoutSeconds),
            "Album filter page should render at least one focusable card",
            file: file, line: line)
    }

    @MainActor
    func waitForPersonFilterReady(app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let backButton = app.buttons["personFilter.back.button"]
        XCTAssertTrue(
            backButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.screenTransitionTimeoutSeconds),
            "Person filter page should show the back button", file: file,
            line: line)
        let firstPersonCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "personFilter.person.")
        ).firstMatch
        XCTAssertTrue(
            firstPersonCard.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.screenTransitionTimeoutSeconds),
            "Person filter page should render at least one focusable card", file: file, line: line)
    }

    func personPrimaryCardButtons(in app: XCUIApplication) -> XCUIElementQuery {

        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "personFilter.person.",
                ".button"
            )
        )
    }

    func albumPrimaryCardButtons(in app: XCUIApplication) -> XCUIElementQuery {

        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "albumFilter.album.",
                ".button"
            )
        )
    }

    // Cards are found by album ID in the order the server lists them, which is the order the page shows, so the
    // lookup does not depend on how the accessibility order sorts the card frames.
    func albumCardInServerOrder(at index: Int, in app: XCUIApplication) throws -> XCUIElement {
        let albumIDs = try serverAlbumIDs(atLeast: index + 1)
        return app.buttons["albumFilter.album.\(albumIDs[index]).button"]
    }

    @MainActor
    func moveFocusToAlbumGridBottom(app: XCUIApplication, maxSteps: Int = 40) throws {

        let firstCard = try albumCardInServerOrder(at: 0, in: app)
        waitForElementToGainFocus(
            firstCard,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage:
                "Album filter page should focus the first card by default before the scroll-to-bottom screenshot"
        )

        var lastFocusedIndex = focusedAlbumCardIndex(in: app) ?? 0
        var stableMoveCount = 0

        for _ in 0..<maxSteps {
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.albumFocusSettleSeconds))

            guard let currentFocusedIndex = focusedAlbumCardIndex(in: app) else {
                continue
            }

            if currentFocusedIndex == lastFocusedIndex {
                stableMoveCount += 1
            } else {
                lastFocusedIndex = currentFocusedIndex
                stableMoveCount = 0
            }

            if stableMoveCount >= 2 {
                break
            }
        }
    }

    func focusedAlbumCardIndex(in app: XCUIApplication) -> Int? {
        let cards = albumPrimaryCardButtons(in: app).allElementsBoundByIndex
        for (index, card) in cards.enumerated() {
            guard card.exists else { continue }
            if let value = card.value as? String, value.contains("已聚焦") {
                return index
            }
        }
        return nil
    }

    @MainActor
    func waitForAnyAlbumTopBarButtonToGainFocus(
        app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {

        let candidates = [
            app.buttons["albumFilter.back.button"],
            app.buttons["albumFilter.selectAll.button"],
            app.buttons["albumFilter.clear.button"]
        ]

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if candidates.contains(where: { $0.exists && $0.hasFocus }) {
                return
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.pollIntervalSeconds))
        }

        let focusDump = candidates.map { button in
            "\(button.identifier):exists=\(button.exists),hasFocus=\(button.hasFocus)"
        }.joined(separator: " | ")

        XCTFail("Moving up did not reach the top bar focus area: \(focusDump)", file: file, line: line)
    }

    @MainActor
    func waitForReadinessMarker(
        app: XCUIApplication, identifier: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let readinessLabel = app.staticTexts[identifier]
        XCTAssertTrue(
            readinessLabel.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.screenTransitionTimeoutSeconds),
            "A readable UI test readiness marker should be exposed: \(identifier)", file: file, line: line)

        waitForFocusVisualSettle(seconds: TestWait.seconds(.product(1.2)))
    }

    @MainActor
    func waitForElementToGainFocus(
        _ element: XCUIElement,
        timeout: TimeInterval,
        failureMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {

        // ui-label-lookup: This predicate checks the localized accessibility value used to prove tvOS focus.
        let predicate = NSPredicate(format: "value CONTAINS %@ OR value CONTAINS %@", "已聚焦", "Focused")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, failureMessage, file: file, line: line)
    }

    @MainActor
    func waitForElementValue(
        _ element: XCUIElement,
        expectedValue: String,
        timeout: TimeInterval,
        failureMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // ui-label-lookup: This checks the expected accessibility value on an already identified card.
        let predicate = NSPredicate(format: "value == %@", expectedValue)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, failureMessage, file: file, line: line)
    }

    @MainActor
    func waitForElementToDisappear(
        _ element: XCUIElement,
        timeout: TimeInterval,
        failureMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, failureMessage, file: file, line: line)
    }

    @MainActor
    func waitForButtonToGainFocus(
        _ button: XCUIElement,
        timeout: TimeInterval,
        failureMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if button.exists && (button.hasFocus || accessibilityValueString(for: button).contains("focused")) {
                return
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.pollIntervalSeconds))
        }
        XCTFail(failureMessage, file: file, line: line)
    }

    @MainActor
    func waitForSettingsHomeItemFocus(
        button: XCUIElement,
        timeout: TimeInterval,
        failureMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {

        waitForButtonToGainFocus(
            button,
            timeout: timeout,
            failureMessage: failureMessage,
            file: file,
            line: line
        )
    }

    func accessibilityValueString(for element: XCUIElement) -> String {
        guard let rawValue = element.value else { return "" }
        return String(describing: rawValue)
    }

    func currentTVOSSceneSignatureValue(app: XCUIApplication) -> String? {
        let probe = app.descendants(matching: .any)["slideshow.smartfill.currentManifest.flag"]
        guard probe.exists else { return nil }
        return manifestField("ledgerSceneAssets", in: probe.label)
            ?? manifestField("slotRefs", in: probe.label)
    }

    func currentTVOSSceneSignature(app: XCUIApplication) throws -> String {
        _ = waitUntil(
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.screenTransitionTimeoutSeconds,
            condition: { self.currentTVOSSceneSignatureValue(app: app) != nil })
        return try XCTUnwrap(
            currentTVOSSceneSignatureValue(app: app),
            "The tvOS slideshow manifest probe stayed empty, so retained history cannot be verified"
        )
    }

    func waitForTVOSSceneSignatureChange(
        app: XCUIApplication,
        from oldValue: String,
        timeout: TimeInterval
    ) throws -> String {
        XCTAssertTrue(
            waitUntil(timeout: timeout) {
                guard let value = self.currentTVOSSceneSignatureValue(app: app) else { return false }
                return value != oldValue
            },
            "The playback scene signature should change after the remote input"
        )
        return try currentTVOSSceneSignature(app: app)
    }

    func manifestField(_ key: String, in manifest: String) -> String? {
        let prefix = "\(key)="
        return
            manifest
            .split(separator: ";")
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.pollIntervalSeconds))
        }
        return condition()
    }

    func waitForAnySettingsSurface(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.descendants(matching: .any)["settings.item.playback"].exists
                || app.descendants(matching: .any)["settings.item.accessProtection"].exists
                || app.buttons["pinEntry.close.button"].exists
            {
                return true
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.shortFocusSettleSeconds))
        }
        return false
    }

    @MainActor
    func enterSixDigitsInPinSheetUsingDigitOne(
        app: XCUIApplication,
        operationName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {

        let digitOneButton = app.buttons["pinEntry.digit.1.button"]
        let closeButton = app.buttons["pinEntry.close.button"]

        XCTAssertTrue(
            digitOneButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "\(operationName): the opened PIN sheet should show the number pad",
            file: file,
            line: line
        )

        waitForButtonToGainFocus(
            digitOneButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "\(operationName): when the PIN sheet opens, default focus should be on digit 1",
            file: file,
            line: line
        )

        for _ in 0..<FilterSummaryTVOSVisualUITestsAccessProtection.pinDigitCount {
            XCUIRemote.shared.press(.select)
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryTVOSVisualUITestsWaitTiming.focusPollSeconds))
        }

        waitForElementToDisappear(
            closeButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "\(operationName): after 6 digits are entered, the PIN sheet should close on its own",
            file: file,
            line: line
        )
    }
}
#endif
