import ImageIO
import UIKit
import XCTest

#if os(tvOS)
@MainActor
struct TVDriver: PlaybackDriver {
    let app: XCUIApplication

    func launchToPlayback(input: StrictE2EInput) {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForExistence(timeout: UITestSupportWaitTiming.screenTransitionTimeoutSeconds),
            "A clean install must open the first-boot form.")
        replaceFocusedText(in: serverField, with: input.serverURL)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForExistence(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "First-boot form must show the API Key field.")
        focus(
            apiKeyField, trying: [.down], maxPresses: 2,
            "After submitting the URL, focus must be able to move down to the API Key.")
        replaceFocusedText(in: apiKeyField, with: input.publicKey)

        let testConnection = firstBootControl("firstboot.testConnection.button")
        XCTAssertTrue(
            testConnection.waitForExistence(timeout: UITestSupportWaitTiming.elementAppearanceTimeoutSeconds),
            "First-boot form must show the Test Connection button.")
        press(.down)
        press(.right)
        press(.select)
        XCTAssertTrue(
            app.staticTexts["firstboot.connection.success"].waitForExistence(
                timeout: UITestSupportWaitTiming.sceneReadyTimeoutSeconds),
            "Once the real controlled server is reachable, it must show that the connection test passed.")
        let save = firstBootControl("firstboot.saveConfig.button")
        XCTAssertTrue(
            save.waitForExistence(timeout: UITestSupportWaitTiming.elementAppearanceTimeoutSeconds),
            "Once connected, the Save Settings button must show.")
        XCTAssertTrue(save.isEnabled, "After a successful connection, Save Settings must be enabled.")
        press(.select)

        let random = app.buttons["mode.random.button"]
        XCTAssertTrue(
            random.waitForExistence(timeout: UITestSupportWaitTiming.connectionTimeoutSeconds),
            "Saving the settings must open the mode selection page.")
        XCTAssertTrue(
            waitForFocus(random, timeout: UITestSupportWaitTiming.elementAppearanceTimeoutSeconds),
            "Mode selection default focus must be on Random playback.")
        press(.select)
        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: UITestSupportWaitTiming.elementAppearanceTimeoutSeconds),
            "After choosing Random playback, the Continue button must show.")
        focus(
            continueButton, trying: [.down], maxPresses: 2,
            "After choosing Random playback, focus must be able to move down to Continue.")
        press(.select)
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: UITestSupportWaitTiming.playbackStartupTimeoutSeconds),
            "The control bar must appear after starting random playback.")
    }

    func applyPlaybackSettings(_ settings: [PlaybackSetting]) {
        openSettings()
        focus(
            app.buttons["settings.item.playback"], trying: [.up], maxPresses: 4,
            "Settings home must be able to focus playback settings.")
        press(.select)
        XCTAssertTrue(
            app.buttons["settings.playback.autoPlay.link"].waitForExistence(
                timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "Must open the playback settings subpage.")
        for setting in settings {
            switch setting {
            case .interval30Seconds:
                choose(link: "settings.playback.interval.link", option: "settings.playback.interval.30.button")
            case .interval15Seconds:
                choose(link: "settings.playback.interval.link", option: "settings.playback.interval.15.button")
            case .displayMode(let isSinglePhoto):
                choose(
                    link: "settings.playback.displayMode.link",
                    option: isSinglePhoto
                        ? "settings.playback.displayMode.singlePhoto.button"
                        : "settings.playback.displayMode.smartFill.button"
                )
            case .showExif(let isOn):
                focusSettingsControl("settings.playback.display.link")
                press(.select)
                choose(
                    link: "settings.playback.showExif.link",
                    option: isOn ? "settings.playback.showExif.on.button" : "settings.playback.showExif.off.button"
                )
                press(.menu)
                XCTAssertTrue(
                    app.buttons["settings.playback.display.link"].waitForExistence(
                        timeout: UITestSupportWaitTiming.settingsChangeTimeoutSeconds),
                    "After Menu, must return to playback settings.")
            }
        }
        returnToPlayback()
    }

    func pause() {
        revealControls()
        let playPause = app.buttons["slideshow.control.playPause.button"]
        focus(playPause, trying: [.right, .left], maxPresses: 3, "Focus must be able to reach play/pause.")
        if playPauseValue(playPause) != "play" { press(.select) }
        XCTAssertTrue(
            Wait.until(timeout: UITestSupportWaitTiming.stateChangeTimeoutSeconds) {
                playPauseValue(playPause) == "play"
            },
            "After pausing, the control value must be play.")
    }

    func next() {
        // Wait until the control bar is actually hidden and the receiver layer has focus, then act within a fresh
        // 8-second visible window.
        let receiver = app.descendants(matching: .any).matching(identifier: "slideshow.hiddenWakeReceiver").firstMatch
        XCTAssertTrue(
            Wait.until(timeout: UITestSupportWaitTiming.screenTransitionTimeoutSeconds) {
                receiver.exists && receiver.hasFocus
            },
            "Before Next, the control bar must be hidden and the hidden receiver layer must have focus."
        )
        press(.up)
        let nextButton = app.buttons["slideshow.control.next.button"]
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: UITestSupportWaitTiming.stateChangeTimeoutSeconds),
            "After a direction key wakes the controls, Next must show.")
        focus(nextButton, trying: [.right, .left], maxPresses: 3, "Focus must be able to reach Next.")
        press(.select)
    }

    // Before each Menu press, confirm we are not back on the playback layer yet; one press too many sends the app
    // to the Home screen.
    func returnToPlayback() {
        for _ in 0..<8 {
            if Wait.until(timeout: 1.5, { isOnPlaybackLayer() }) { break }
            press(.menu)
        }
        XCTAssertTrue(
            Wait.held(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds, hold: 1.2) {
                isOnPlaybackLayer()
            },
            "Must be able to return from settings to playback."
        )
    }

    func clearDiskCache(onCachePage: () throws -> Void) throws {
        openSettings()
        focusSettingsControl("settings.item.cache")
        press(.select)
        XCTAssertTrue(
            app.buttons["settings.cache.clearDisk.button"].waitForExistence(
                timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "Cache page must provide the Clear Disk Cache button.")
        focusSettingsControl("settings.cache.clearDisk.button")
        try onCachePage()
        press(.select)
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: UITestSupportWaitTiming.elementAppearanceTimeoutSeconds),
            "Selecting Clear must show the confirmation alert.")
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let confirmButtons = alert.buttons.matching(NSPredicate(format: "label == %@", "清理"))
        XCTAssertTrue(
            confirmButtons.firstMatch.waitForExistence(timeout: UITestSupportWaitTiming.shortInteractionTimeoutSeconds),
            "Confirmation alert must offer Clear.")
        let hasFocusedConfirm = {
            confirmButtons.allElementsBoundByIndex.contains { $0.exists && $0.hasFocus }
        }
        try Evidence().capture("cache-confirm-alert", from: app)
        if !hasFocusedConfirm() {
            press(.right)
            try Evidence().capture("cache-confirm-right", from: app)
        }
        if !hasFocusedConfirm() {
            press(.left)
            try Evidence().capture("cache-confirm-left", from: app)
        }
        XCTAssertTrue(
            Wait.until(timeout: UITestSupportWaitTiming.shortInteractionTimeoutSeconds) { hasFocusedConfirm() },
            "Alert focus must be able to reach Clear.")
        XCUIRemote.shared.press(.select)
        waitForClearCompletion()
    }

    private func openSettings() {
        revealControls()
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        focus(
            settingsButton, trying: [.left], maxPresses: 6,
            "Before opening settings, focus must be on the settings button.")
        press(.select)
        XCTAssertTrue(
            app.buttons["settings.item.playback"].waitForExistence(
                timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "Selecting settings must open the settings home.")
    }

    // After Menu, the settings page that owns the link must be visible again.
    private func choose(link: String, option: String) {
        focusSettingsControl(link)
        press(.select)
        let optionButton = app.buttons[option]
        focusSettingsControl(option)
        press(.select)
        XCTAssertTrue(
            Wait.until(timeout: UITestSupportWaitTiming.shortInteractionTimeoutSeconds) { isSelected(optionButton) },
            "After choosing \(option), it must be selected.")
        press(.menu)
        XCTAssertTrue(
            app.buttons[link].waitForExistence(timeout: UITestSupportWaitTiming.settingsChangeTimeoutSeconds),
            "Menu must return to the page with \(link).")
    }

    // The settings page is a single column: search down first, then up if nothing is found at the bottom.
    private func focusSettingsControl(_ identifier: String) {
        focus(app.buttons[identifier], trying: [.down, .up], maxPresses: 7, "Must be able to focus \(identifier).")
    }

    // While the control bar is hidden, the first direction key only wakes it. Wait for the hidden receiver layer
    // to get focus before pressing, and press again at most once.
    private func revealControls() {
        let playPause = app.buttons["slideshow.control.playPause.button"]
        let receiver = app.descendants(matching: .any).matching(identifier: "slideshow.hiddenWakeReceiver").firstMatch
        for _ in 0..<2 where !playPause.exists {
            _ = Wait.until(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds) {
                playPause.exists || (receiver.exists && receiver.hasFocus)
            }
            if playPause.exists { break }
            press(.up)
            _ = playPause.waitForExistence(timeout: UITestSupportWaitTiming.stateChangeTimeoutSeconds)
        }
        XCTAssertTrue(playPause.exists, "A direction key must wake the playback control bar.")
    }

    private func isOnPlaybackLayer() -> Bool {
        let settingsLayer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.")).firstMatch
        guard !settingsLayer.exists else { return false }
        return app.buttons["slideshow.control.playPause.button"].exists
            || app.descendants(matching: .any).matching(identifier: "slideshow.hiddenWakeReceiver").firstMatch.exists
    }

    private func replaceFocusedText(in field: XCUIElement, with value: String) {
        XCTAssertTrue(
            waitForFocus(field, timeout: UITestSupportWaitTiming.stateChangeTimeoutSeconds),
            "The field must be focused before input.")
        press(.select)
        app.typeText(value)
        // ui-label-lookup: tvOS owns the on-screen keyboard submit buttons.
        let submit = app.buttons.matching(NSPredicate(format: "label IN %@", ["下一项", "Next", "完成", "Done"])).firstMatch
        XCTAssertTrue(
            submit.waitForExistence(timeout: UITestSupportWaitTiming.stateChangeTimeoutSeconds),
            "The system keyboard must show Next or Done.")
        for _ in 0..<6 where !submit.hasFocus {
            press(.down)
        }
        XCTAssertTrue(submit.hasFocus, "The system keyboard submit button must be focused before submitting text.")
        press(.select)
        press(.menu)
        XCTAssertTrue(
            waitForFocus(field, timeout: UITestSupportWaitTiming.stateChangeTimeoutSeconds),
            "After submitting, focus must return to the original field.")
    }

    private func focus(
        _ element: XCUIElement, trying directions: [XCUIRemote.Button], maxPresses: Int, _ message: String
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds), message)
        for direction in directions {
            for _ in 0..<maxPresses {
                if element.exists && element.hasFocus { return }
                press(direction)
            }
        }
        XCTAssertTrue(waitForFocus(element, timeout: UITestSupportWaitTiming.shortInteractionTimeoutSeconds), message)
    }

    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        Wait.until(timeout: timeout) { element.exists && element.hasFocus }
    }

    private func press(_ button: XCUIRemote.Button) {
        XCUIRemote.shared.press(button)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusSettle))
    }

    private func firstBootControl(_ identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        let identified = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if identified.exists { return identified }
        return identified
    }

    private func isSelected(_ element: XCUIElement) -> Bool {
        let value = String(describing: element.value ?? "")
        return value.contains("已选中") || value.contains("selected")
    }

    private func playPauseValue(_ button: XCUIElement) -> String {
        String(describing: button.value ?? "").lowercased()
    }
}
#endif
