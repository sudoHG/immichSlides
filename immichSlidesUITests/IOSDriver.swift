import ImageIO
import UIKit
import XCTest

#if os(iOS)
private enum SliderGeometry {
    // Drag beyond the track to reach the maximum after accessibility adjustment stops short.
    static let maximumThumbFraction: CGFloat = 0.93
    static let dragBeyondMaximumFraction: CGFloat = 1.05
}

@MainActor
struct IOSDriver: PlaybackDriver {
    // The interval slider maps 5-30 seconds linearly: (15 - 5) / (30 - 5).
    private static let interval15SliderPosition = 0.4
    // The slider steps by 1 second and a drag often lands one step off: try the target first, then nudge to both
    // sides from near to far.
    private static let sliderNudgeOffsets = [0, -0.04, 0.04, -0.08, 0.08]

    let app: XCUIApplication

    func launchToPlayback(input: StrictE2EInput) {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 20), "Fresh install must open the normal first-boot page.")
        replaceText(in: serverField, with: input.serverURL)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForExistence(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
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
            testConnection.waitForExistence(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "First-boot page must show Test Connection.")
        tap(testConnection)
        let save = control("firstboot.saveConfig.button")
        XCTAssertTrue(
            save.waitForExistence(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "First-boot page must show the Save Settings button.")
        XCTAssertTrue(waitForSaveEnabled(save), "Save must become enabled after a real connection test succeeds.")
        tap(save)

        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(
                timeout: UITestSupportWaitTiming.connectionTimeoutSeconds),
            "A successful save must lead to mode selection.")
        let random = control("mode.random.button")
        let continueButton = control("mode.continue.button")
        if !(continueButton.exists && continueButton.isEnabled && random.isSelected) {
            tap(random)
            XCTAssertTrue(
                Wait.until(timeout: UITestSupportWaitTiming.readbackTimeoutSeconds) {
                    continueButton.exists && continueButton.isEnabled
                },
                "Continue must be enabled after selecting Random.")
        }
        tap(continueButton)
        dismissSavePasswordPrompt(timeout: UITestSupportWaitTiming.elementAppearanceTimeoutSeconds)
        if continueButton.exists && continueButton.isHittable && continueButton.isEnabled {
            tap(continueButton)
        }
        XCTAssertTrue(
            waitForPlaybackControls(timeout: UITestSupportWaitTiming.playbackStartupTimeoutSeconds),
            "Random mode must reach the playback page.")
    }

    func applyPlaybackSettings(_ settings: [PlaybackSetting]) {
        openSettings()
        openPlaybackSection()
        for setting in settings {
            switch setting {
            case .interval30Seconds:
                let slider = app.sliders["settings.playback.interval.slider"]
                XCTAssertTrue(
                    slider.waitForExistence(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
                    "Playback settings must have the interval slider.")
                XCTAssertTrue(slider.isEnabled, "With auto-play on, the interval slider must be adjustable.")
                slider.adjust(toNormalizedSliderPosition: 1)
                let interval30 = app.staticTexts["settings.playback.interval.value"]
                if UIDevice.current.userInterfaceIdiom == .pad
                    && !Wait.until(
                        timeout: UITestSupportWaitTiming.briefElementTimeoutSeconds,
                        { interval30.exists && interval30.label == "30 秒" })
                {
                    let thumb = slider.coordinate(
                        withNormalizedOffset: CGVector(dx: SliderGeometry.maximumThumbFraction, dy: 0.5))
                    let beyondRightEnd = slider.coordinate(
                        withNormalizedOffset: CGVector(dx: SliderGeometry.dragBeyondMaximumFraction, dy: 0.5))
                    thumb.press(forDuration: 0.1, thenDragTo: beyondRightEnd)
                }
                let reached30 = Wait.until(timeout: UITestSupportWaitTiming.shortInteractionTimeoutSeconds) {
                    interval30.exists && interval30.label == "30 秒"
                }
                if !reached30 {
                    try? Evidence().reject("interval30-setting", png: app.screenshot().pngRepresentation)
                }
                XCTAssertTrue(reached30, "The interval must be set to 30 seconds with the real slider.")
            case .interval15Seconds:
                let slider = app.sliders["settings.playback.interval.slider"]
                XCTAssertTrue(
                    slider.waitForExistence(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
                    "Playback settings must have the interval slider.")
                XCTAssertTrue(slider.isEnabled, "With auto-play on, the interval slider must be adjustable.")
                XCTAssertTrue(
                    adjustInterval(slider, toNormalized: Self.interval15SliderPosition, label: "15 秒"),
                    "The interval must be set to 15 seconds with the real slider."
                )
            case .displayMode(let isSinglePhoto):
                let picker = app.segmentedControls["settings.playback.displayMode.picker"]
                XCTAssertTrue(
                    picker.waitForExistence(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
                    "Playback settings must have display mode segments.")
                let option = picker.buttons[
                    isSinglePhoto
                        ? "settings.playback.displayMode.singlePhoto.option"
                        : "settings.playback.displayMode.smartFill.option"]
                XCTAssertTrue(
                    option.waitForExistence(timeout: UITestSupportWaitTiming.shortInteractionTimeoutSeconds),
                    "Display mode must offer the target option.")
                tap(option)
                XCTAssertTrue(
                    Wait.until(timeout: UITestSupportWaitTiming.shortInteractionTimeoutSeconds) { option.isSelected },
                    "Display mode must switch to the target option.")
            case .showExif(let isOn):
                let toggle = app.switches["settings.playback.showExif.toggle"]
                XCTAssertTrue(
                    toggle.waitForExistence(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
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
        revealControls()
        let playPause = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPause.waitForExistence(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "Playback page must provide play/pause.")
        if playPauseValue(playPause) != "play" { tap(playPause) }
        XCTAssertTrue(
            Wait.until(timeout: UITestSupportWaitTiming.stateChangeTimeoutSeconds) {
                playPauseValue(playPause) == "play"
            },
            "After pausing, the control value must be play.")
    }

    func next() {
        revealControls()
        let nextButton = app.buttons["slideshow.control.next.button"]
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: UITestSupportWaitTiming.stateChangeTimeoutSeconds),
            "Playback page must provide Next.")
        tap(nextButton)
    }

    func returnToPlayback() {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        for _ in 0..<12 {
            if settingsButton.exists && settingsButton.isHittable { return }
            if !isOnSettingsSurface() {
                revealControls()
                if settingsButton.waitForExistence(timeout: UITestSupportWaitTiming.readbackTimeoutSeconds) { return }
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
            app.swipeDown()
        }
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "Must be able to return from settings to playback.")
    }

    func clearDiskCache(onCachePage: () throws -> Void) throws {
        openSettings()
        openCacheSection()
        let clearButton = app.buttons["settings.cache.clearDisk.button"]
        XCTAssertTrue(
            clearButton.waitForExistence(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "Cache page must provide the Clear Disk Cache button.")
        if !clearButton.isHittable { app.swipeUp() }
        try onCachePage()
        tap(clearButton)
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let alert = app.alerts["确认清理磁盘缓存"]
        XCTAssertTrue(
            alert.waitForExistence(timeout: UITestSupportWaitTiming.elementAppearanceTimeoutSeconds),
            "Tapping Clear must show the confirmation alert.")
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let confirm = alert.buttons.matching(NSPredicate(format: "label == %@", "清理")).firstMatch
        XCTAssertTrue(
            confirm.waitForExistence(timeout: UITestSupportWaitTiming.shortInteractionTimeoutSeconds),
            "Confirmation alert must offer Clear.")
        confirm.tap()
        waitForClearCompletion()
    }

    private func openSettings() {
        revealControls()
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: UITestSupportWaitTiming.connectionTimeoutSeconds),
            "Playback page must provide the settings entry.")
        tap(settingsButton)
        XCTAssertTrue(
            Wait.until(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds) { isOnSettingsSurface() },
            "Tapping settings must open the settings page.")
    }

    // On iPad the split view shows playback settings on the right by default; iPhone goes through the list.
    private func openPlaybackSection() {
        let autoPlay = app.switches["settings.playback.autoPlay.toggle"]
        if autoPlay.waitForExistence(timeout: UITestSupportWaitTiming.readbackTimeoutSeconds) { return }
        showSidebarIfCollapsed()
        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForExistence(timeout: UITestSupportWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings list must have the playback settings entry.")
        playbackItem.tap()
        if !Wait.until(
            timeout: UITestSupportWaitTiming.readbackTimeoutSeconds,
            { autoPlay.exists || app.staticTexts["settings.playback.title"].exists })
        {
            app.cells.element(boundBy: 0).tap()
        }
        XCTAssertTrue(
            Wait.until(timeout: 10) { autoPlay.exists || app.staticTexts["settings.playback.title"].exists },
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
                $0.waitForExistence(timeout: UITestSupportWaitTiming.briefElementTimeoutSeconds)
            }) {
                tap(entry)
                if clearButton.waitForExistence(timeout: UITestSupportWaitTiming.stateChangeTimeoutSeconds) { return }
            }
            if attempt % 2 == 0 { app.swipeUp() } else { app.swipeDown() }
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
    func revealUsableControls() -> Bool {
        revealControls()
        return [
            "slideshow.control.playPause.button", "slideshow.control.next.button", "slideshow.control.settings.button"
        ]
        .allSatisfy { app.buttons[$0].isHittable }
    }

    private func revealControls() {
        if app.buttons["slideshow.control.settings.button"].exists { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        _ = app.buttons["slideshow.control.settings.button"].waitForExistence(
            timeout: UITestSupportWaitTiming.shortInteractionTimeoutSeconds)
    }

    private func adjustInterval(_ slider: XCUIElement, toNormalized target: Double, label: String) -> Bool {
        for offset in Self.sliderNudgeOffsets {
            slider.adjust(toNormalizedSliderPosition: min(max(target + offset, 0), 1))
            let interval = app.staticTexts["settings.playback.interval.value"]
            if Wait.until(
                timeout: UITestSupportWaitTiming.briefElementTimeoutSeconds,
                { interval.exists && interval.label == label })
            {
                return true
            }
        }
        return false
    }

    private func waitForPlaybackControls(timeout: TimeInterval) -> Bool {
        Wait.until(timeout: timeout) {
            dismissSavePasswordPrompt(timeout: 0)
            let banner = app.descendants(matching: .any).matching(identifier: "slideshow.entryHint.banner").firstMatch
            if banner.exists { tap(banner) }
            if app.buttons["slideshow.control.settings.button"].isHittable { return true }
            revealControls()
            return app.buttons["slideshow.control.settings.button"].isHittable
        }
    }

    private func waitForSaveEnabled(_ save: XCUIElement) -> Bool {
        Wait.until(timeout: UITestSupportWaitTiming.sceneReadyTimeoutSeconds) {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            // ui-label-lookup: The local-network permission alert belongs to iOS.
            for label in ["允许", "Allow"] where springboard.alerts.buttons[label].exists {
                // ui-label-lookup: The permission action belongs to SpringBoard.
                springboard.alerts.buttons[label].tap()
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

    private func dismissSavePasswordPrompt(timeout: TimeInterval) {
        _ = Wait.until(timeout: timeout) {
            // ui-label-lookup: Dismiss the iOS Save Password sheet without saving credentials.
            for label in ["以后", "Not Now"] where app.buttons[label].exists {
                // ui-label-lookup: The Save Password action belongs to iOS.
                app.buttons[label].tap()
                return true
            }
            return false
        }
    }

    private func replaceText(in field: XCUIElement, with value: String) {
        field.tap()
        let existing = field.value as? String ?? ""
        let isPlaceholder = existing.contains("请输入") || existing.localizedCaseInsensitiveContains("enter")
        if !existing.isEmpty && !isPlaceholder {
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        }
        field.typeText(value)
    }

    private func secureFieldHasValue(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return !value.isEmpty && !value.contains("请输入") && !value.localizedCaseInsensitiveContains("api key")
    }

    private func commitFocusedInput() {
        let done = app.buttons["server.keyboard.done.button"]
        if done.exists && done.isHittable {
            done.tap()
            return
        }
        // ui-label-lookup: System keyboard submit keys follow the simulator language.
        for label in ["完成", "Done", "next", "Next"] {
            // ui-label-lookup: System keyboard submit keys follow the simulator language.
            let button = app.keyboards.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
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
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func isToggleOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }

    private func playPauseValue(_ button: XCUIElement) -> String {
        ((button.value as? String) ?? "").lowercased()
    }
}
#endif
