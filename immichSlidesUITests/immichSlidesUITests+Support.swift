import XCTest

#if os(iOS)
extension immichSlidesUITests {
    func requireIPhoneDestination() throws {
        let model = UIDevice.current.model.lowercased()
        let userInterfaceIdiom = UIDevice.current.userInterfaceIdiom
        guard userInterfaceIdiom == .phone || model.contains("iphone") else {
            throw XCTSkip("Not on an iPhone (detected: \(UIDevice.current.model)); skipping iPhone-only UI tests.")
        }
    }

    func launchApp(shouldResetState: Bool, shouldSeedFilterSelection: Bool = false, colorScheme: String? = nil)
        -> XCUIApplication
    {
        let app = XCUIApplication()
        if shouldResetState {
            app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        }
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        if shouldSeedFilterSelection {
            app.launchEnvironment["UI_TEST_SEED_FILTER_SELECTION"] = "1"
        }
        if let colorScheme {
            app.launchEnvironment["UI_TEST_COLOR_SCHEME"] = colorScheme
        }
        // Turn off one-time hints; inject the expected connection-test values instead of UI_TEST_SERVER_URL, so
        // the full first-boot page still runs.
        if let config = TestServerConfiguration.current {
            app.launchEnvironment["UI_TEST_ASSUME_CONNECTION_TEST_SUCCESS"] = "1"
            app.launchEnvironment["UI_TEST_EXPECTED_CONNECTION_SERVER_URL"] = config.serverURL
            app.launchEnvironment["UI_TEST_EXPECTED_CONNECTION_API_KEY"] = config.apiKey
        }
        app.launch()
        return app
    }

    // Tests with an existing config start from the mode page, skipping the unrelated first-boot networking.

    func launchConfiguredAppAtModeSelection(
        shouldResetState: Bool,
        shouldSeedFilterSelection: Bool = false,
        colorScheme: String? = nil
    ) throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = XCUIApplication()

        if shouldResetState {
            app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        }

        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        if shouldSeedFilterSelection {
            app.launchEnvironment["UI_TEST_SEED_FILTER_SELECTION"] = "1"
        }
        if let colorScheme {
            app.launchEnvironment["UI_TEST_COLOR_SCHEME"] = colorScheme
        }
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        app.launch()

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.navigationTimeoutSeconds),
            "After injecting the test server at launch, the app should go straight to mode selection"
        )
        return app
    }

    func assertModeSelectionCoreElements(app: XCUIApplication) {
        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(app.buttons["mode.filtered.button"].exists)
        XCTAssertTrue(app.buttons["mode.continue.button"].exists)
    }

    func completeFirstBootToModeSelection(app: XCUIApplication, serverURL: String, apiKey: String) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        guard serverField.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds)
        else {
            throw XCTSkip("Not in first-boot state; skipping first-boot flow assertions.")
        }
        serverField.tap()
        serverField.immichSlidesUITestsClearAndType(text: serverURL)

        let apiField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiField.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        apiField.tap()
        apiField.immichSlidesUITestsClearAndType(text: apiKey)

        let testConnectionButton = app.buttons["firstboot.testConnection.button"]
        XCTAssertTrue(
            testConnectionButton.waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        // Do not tap empty space to dismiss the keyboard first; on small screens that may hit the keyboard. Use
        // XCUIElement.tap instead, which scrolls the element into view.

        testConnectionButton.tap()

        let saveButton = app.buttons["firstboot.saveConfig.button"]
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        let saveEnabledExpectation = NSPredicate(format: "isEnabled == true")
        let saveEnabledWait = expectation(for: saveEnabledExpectation, evaluatedWith: saveButton)
        wait(for: [saveEnabledWait], timeout: TestWait.seconds(.infrastructure(45)))
        tapElement(saveButton)

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.navigationTimeoutSeconds))
    }

    func startRandomPlaybackFromModeSelection(app: XCUIApplication) {
        let modeRandomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(
            modeRandomButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        tapElement(modeRandomButton)

        let modeContinueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            modeContinueButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(modeContinueButton.isEnabled)
        tapElement(modeContinueButton)

        XCTAssertTrue(waitForSlideshowSettingsButton(app: app, timeout: TestWait.seconds(.product(25))))
    }

    func startFilteredFlowFromModeSelection(app: XCUIApplication) {
        let modeFilteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(
            modeFilteredButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        tapElement(modeFilteredButton)

        let modeContinueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            modeContinueButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(modeContinueButton.isEnabled)
        tapElement(modeContinueButton)

        XCTAssertTrue(
            app.buttons["filterSummary.startPlayback.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.navigationTimeoutSeconds))
    }

    func openSettingsFromSlideshow(app: XCUIApplication) {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            waitForSlideshowSettingsButton(app: app, timeout: immichSlidesUITestsWaitTiming.connectionTimeoutSeconds))
        tapElement(settingsButton)
    }

    func openAccessProtectionSectionIfNeeded(app: XCUIApplication) {
        openSettingsSection(app: app, sectionID: "settings.item.accessProtection")
        XCTAssertTrue(
            app.buttons["settings.pin.enable.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds)
                || app.buttons["settings.pin.disable.button"].waitForExistence(
                    timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds)
        )
    }

    func openSettingsSection(app: XCUIApplication, sectionID: String) {
        let sidebar = app.buttons["ToggleSidebar"]
        // ui-label-lookup: System navigation supplies the sidebar button label.
        if sidebar.exists && (sidebar.label == "显示边栏" || sidebar.label == "Show Sidebar") {
            sidebar.tap()
        }
        // A detail page hides the list, so pop back before retrying the section identifier.
        for attempt in 0..<6 {
            let typedCandidates: [XCUIElement] = [
                app.buttons[sectionID],
                app.staticTexts[sectionID],
                app.otherElements[sectionID]
            ]
            for candidate in typedCandidates {
                if candidate.waitForExistence(timeout: immichSlidesUITestsWaitTiming.briefElementTimeoutSeconds) {
                    if candidate.isHittable {
                        candidate.tap()
                        return
                    }
                    tapElement(candidate)
                    return
                }
            }

            let identifiedEntry = app.descendants(matching: .any)[sectionID].firstMatch
            if identifiedEntry.waitForExistence(timeout: immichSlidesUITestsWaitTiming.briefElementTimeoutSeconds) {
                tapElement(identifiedEntry)
                return
            }

            let navBack = app.navigationBars.buttons.firstMatch
            if navBack.exists && navBack.isHittable {
                navBack.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(immichSlidesUITestsWaitTiming.readbackPollSeconds))
            }

            if attempt % 2 == 0 {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
        }
    }

    func tapSettingsPinInput(app: XCUIApplication, id: String) {
        let pinInputButton = app.buttons[id]
        XCTAssertTrue(
            pinInputButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "PIN input entry not found: \(id)")
        pinInputButton.tap()
    }

    func inputPinOnSheet(app: XCUIApplication, pin: String) {
        for digit in pin {
            let key = app.buttons["pinEntry.digit.\(digit).button"]
            XCTAssertTrue(
                key.waitForExistence(timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds),
                "PIN digit key does not exist: \(digit)")
            key.tap()
        }
    }

    func returnToSlideshowFromSettings(app: XCUIApplication) {
        // Playback hides the control bar after settings dismiss; close any PIN sheet first, then pop back and wake it.
        for _ in 0..<8 {
            if app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.readbackTimeoutSeconds)
            {
                return
            }
            let closePinEntry = app.buttons["pinEntry.close.button"]
            if closePinEntry.exists {
                closePinEntry.tap()
                continue
            }

            let backButton =
                app.navigationBars.buttons.allElementsBoundByIndex
                .filter { button in
                    button.exists && button.isHittable && button.identifier == "BackButton"
                }
                .last
                ?? app.navigationBars.buttons.allElementsBoundByIndex
                .filter { button in
                    button.exists && button.isHittable
                }
                .last

            if let backButton {
                backButton.tap()
                RunLoop.current.run(
                    until: Date().addingTimeInterval(immichSlidesUITestsWaitTiming.selectionPollSeconds))
                continue
            }

            if waitForSlideshowSettingsButton(app: app, timeout: immichSlidesUITestsWaitTiming.readbackTimeoutSeconds) {
                return
            }
        }
        XCTAssertTrue(
            waitForSlideshowSettingsButton(
                app: app, timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "Failed to return from settings to playback")
    }

    func waitForAnySettingsSurface(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.otherElements["settings.item.playback"].exists || app.buttons["settings.item.playback"].exists
                || app.staticTexts["settings.item.playback"].exists
                || app.otherElements["settings.item.accessProtection"].exists
                || app.buttons["settings.item.accessProtection"].exists
                || app.staticTexts["settings.item.accessProtection"].exists
                || app.descendants(matching: .any)["settings.item.playback"].exists
                || app.buttons["settings.pin.enable.button"].exists || app.buttons["settings.pin.disable.button"].exists
                || app.switches["settings.playback.autoPlay.toggle"].exists
            {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(immichSlidesUITestsWaitTiming.shortFocusSettleSeconds))
        }
        return false
    }

    func waitForSlideshowSettingsButton(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let button = app.buttons["slideshow.control.settings.button"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if button.exists && button.isHittable {
                return true
            }
            app.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(immichSlidesUITestsWaitTiming.readbackPollSeconds))
        }
        return button.exists
    }

    func tapChevronBackIfNeeded(app: XCUIApplication) {
        // Prefer the pages' stable back identifiers; the system nav-bar label changes with language.
        for identifier in ["albumFilter.back.button", "personFilter.back.button"] {
            let stableBackButton = app.buttons[identifier]
            if stableBackButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.briefElementTimeoutSeconds),
                stableBackButton.isHittable
            {
                stableBackButton.tap()
                return
            }
        }

        let explicitBack = app.buttons["global.back.button"]
        if explicitBack.waitForExistence(timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds),
            explicitBack.isHittable
        {
            explicitBack.tap()
            return
        }
        let navBack = app.navigationBars.buttons.firstMatch
        if navBack.exists && navBack.isHittable {
            navBack.tap()
        }
    }

    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
            return
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    // Non-alert text such as the PIN retry hint retains its stable identifier.

    func findFirstExistingIdentifiedText(
        in app: XCUIApplication,
        identifiers: [String],
        timeout: TimeInterval
    ) -> XCUIElement? {
        _ = waitUntil(timeout: timeout) {
            identifiers.contains { app.staticTexts[$0].exists }
        }

        for identifier in identifiers {
            let text = app.staticTexts[identifier]
            if text.exists {
                return text
            }
        }

        return nil
    }

    // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
    func findFirstExistingStaticText(
        in app: XCUIApplication,
        labels: [String],
        timeout: TimeInterval
    ) -> XCUIElement? {
        _ = waitUntil(timeout: timeout) {
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            labels.contains { app.staticTexts[$0].exists }
        }

        for label in labels {
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let text = app.staticTexts[label]
            if text.exists {
                return text
            }
        }

        return nil
    }

    // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
    func tapFirstExistingButton(in app: XCUIApplication, labels: [String]) {
        for label in labels {
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let button = app.buttons[label].firstMatch
            if button.exists {
                tapElement(button)
                return
            }
        }

        let availableLabels = labels.joined(separator: ", ")
        XCTFail("No tappable button found among: \(availableLabels)")
    }

    func dismissKeyboardIfNeeded(app: XCUIApplication) {
        if app.keyboards.count == 0 { return }

        // ui-label-lookup: System keyboard submit keys follow the simulator language.
        let keyboardDismissButtonLabels = ["Return", "Done", "完成", "确定", "Next", "Go"]
        for label in keyboardDismissButtonLabels {
            // ui-label-lookup: System keyboard submit keys follow the simulator language.
            let keyboardButton = app.keyboards.buttons[label]
            if keyboardButton.exists && keyboardButton.isHittable {
                keyboardButton.tap()
                return
            }

            // The keyboard toolbar follows the same user interaction path as the visual tests.

            let appButton = app.buttons["server.keyboard.done.button"].firstMatch
            if appButton.exists && appButton.isHittable {
                appButton.tap()
                return
            }
        }

        app.tap()
    }

    func assertInAlbumFilterPage(app: XCUIApplication) {
        XCTAssertTrue(
            waitForFilterPageMarker(
                app: app,
                stableButtonIDs: [
                    "albumFilter.back.button",
                    "albumFilter.selectAll.button",
                    "albumFilter.clear.button"
                ],
                pageIdentifier: "albumFilter.back.button",
                loadingIdentifier: "albumFilter.loading.indicator",
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "Did not reach the album filter page"
        )
    }

    func assertInPersonFilterPage(app: XCUIApplication) {
        XCTAssertTrue(
            waitForFilterPageMarker(
                app: app,
                stableButtonIDs: [
                    "personFilter.back.button",
                    "personFilter.selectAll.button",
                    "personFilter.clear.button"
                ],
                pageIdentifier: "personFilter.back.button",
                loadingIdentifier: "personFilter.loading.indicator",
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "Did not reach the people filter page"
        )
    }

    func waitForFilterPageMarker(
        app: XCUIApplication,
        stableButtonIDs: [String],
        pageIdentifier: String,
        loadingIdentifier: String,
        timeout: TimeInterval
    ) -> Bool {
        // Loading means the filter page pushed even if its list controls have not appeared yet.
        waitUntil(timeout: timeout) {
            stableButtonIDs.contains { app.buttons[$0].exists }
                || app.descendants(matching: .any)[pageIdentifier].exists
                || app.descendants(matching: .any)[loadingIdentifier].exists
        }
    }

    func isToggleOn(_ toggle: XCUIElement) -> Bool {
        let raw = ((toggle.value as? String) ?? "").lowercased()
        return raw == "1" || raw == "true"
    }

    func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(immichSlidesUITestsWaitTiming.pollIntervalSeconds))
        }
        return condition()
    }

    func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func currentDeviceTag() -> String {
        // Consistent screenshot names make it easy to filter audit images from different devices in one pass.
        UIDevice.current.model.replacingOccurrences(of: " ", with: "_").lowercased()
    }
}
#endif
