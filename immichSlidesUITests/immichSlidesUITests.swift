//
//  immichSlidesUITests.swift
//  immichSlidesUITests
//
//  Created by sudoHG on 2026/3/18.
//

import XCTest

private enum WaitTiming {
    static let briefElementTimeoutSeconds: TimeInterval = 1
    static let connectionTimeoutSeconds: TimeInterval = 15
    static let controlAppearanceTimeoutSeconds: TimeInterval = 8
    static let elementAppearanceTimeoutSeconds: TimeInterval = 5
    static let navigationTimeoutSeconds: TimeInterval = 10
    static let playbackControlTimeoutSeconds: TimeInterval = 20
    static let pollIntervalSeconds: TimeInterval = 0.1
    static let readbackPollSeconds: TimeInterval = 0.2
    static let readbackTimeoutSeconds: TimeInterval = 2
    static let selectionPollSeconds: TimeInterval = 0.25
    static let settingsChangeTimeoutSeconds: TimeInterval = 6
    static let shortFocusSettleSeconds: TimeInterval = 0.15
    static let shortInteractionTimeoutSeconds: TimeInterval = 3
    static let stateChangeTimeoutSeconds: TimeInterval = 4
}

#if os(iOS)
final class immichSlidesUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        if !name.contains("testCacheClearShowsSuccessMessageAfterConfirm") {
            try requireIPhoneDestination()
        }
        // Reset to portrait at the start of each test so a previous landscape test does not carry over.

        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testFirstBootValidationAndDisabledSaveButton() throws {
        let app = launchApp(shouldResetState: true)

        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(serverField.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))

        let apiField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiField.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))

        let saveButton = app.buttons["firstboot.saveConfig.button"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds))
        XCTAssertFalse(saveButton.isEnabled, "Save button should stay disabled before the connection is verified")

        serverField.tap()
        serverField.clearAndType(text: "foo://invalid-host")
        apiField.tap()
        apiField.clearAndType(text: "dummy-key")
        app.typeText("\n")

        let testConnectionButton = app.buttons["firstboot.testConnection.button"]
        XCTAssertTrue(testConnectionButton.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds))
        dismissKeyboardIfNeeded(app: app)
        tapElement(testConnectionButton)

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let errorAlert = app.alerts.firstMatch
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let errorAlertTitle = findFirstExistingStaticText(
            in: app,
            labels: ["连接测试失败", "Connection test failed", "Connection Test Failed"],
            timeout: WaitTiming.shortInteractionTimeoutSeconds
        )
        XCTAssertTrue(
            errorAlert.exists || errorAlertTitle != nil,
            "An invalid URL should trigger an error message"
        )
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        tapFirstExistingButton(in: app, labels: ["确定", "OK"])
        XCTAssertFalse(saveButton.isEnabled, "Save button should stay disabled after connection verification fails")
    }

    @MainActor
    func testFirstBootAPIKeyHelpSheet() throws {
        let app = launchApp(shouldResetState: true)

        let helpButton = app.buttons["server.apiKey.help.button"]
        XCTAssertTrue(
            helpButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "First-boot page should show the help entry next to the API Key title")
        tapElement(helpButton)

        let sheet = app.descendants(matching: .any)["server.apiKey.help.sheet"]
        XCTAssertTrue(
            sheet.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "Tapping the help entry should show the API Key help sheet")
        XCTAssertTrue(
            app.staticTexts["server.apiKey.help.sheet"].waitForExistence(
                timeout: WaitTiming.shortInteractionTimeoutSeconds))
        XCTAssertTrue(app.staticTexts["server.apiKey.help.section.list.number.title"].exists)
        XCTAssertTrue(app.staticTexts["server.apiKey.help.section.checklist.title"].exists)

        if !app.staticTexts["server.apiKey.help.section.key.fill.title"].exists {
            sheet.swipeUp()
        }
        XCTAssertTrue(
            app.staticTexts["server.apiKey.help.section.key.fill.title"].waitForExistence(
                timeout: WaitTiming.readbackTimeoutSeconds))
        attachScreenshot(app: app, name: "firstboot-api-key-help-sheet")

        let closeButton = app.buttons["server.apiKey.help.close.button"]
        XCTAssertTrue(
            closeButton.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "Help sheet should provide a tappable close button")
        tapElement(closeButton)
        XCTAssertFalse(
            sheet.waitForExistence(timeout: WaitTiming.briefElementTimeoutSeconds),
            "The help sheet should be gone after closing it")
        XCTAssertTrue(
            app.secureTextFields["firstboot.apiKey.field"].waitForExistence(
                timeout: WaitTiming.shortInteractionTimeoutSeconds))
    }

    @MainActor
    func testDarkModeSnapshotModeSelection() throws {
        // Inject the server directly and stop on the mode page, so first boot interferes less with the screenshot.
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true, colorScheme: "dark")
        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(app.buttons["mode.filtered.button"].exists)

        attachScreenshot(app: app, name: "dark-mode-mode-selection")
    }

    @MainActor
    func testDarkModeSnapshotFilterSummary() throws {
        // Use test environment variables to land on the mode page and check only the filter summary visuals,
        // so the runner does not get killed.

        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true, colorScheme: "dark")
        startFilteredFlowFromModeSelection(app: app)

        XCTAssertTrue(
            app.buttons["filterSummary.album.button"].waitForExistence(
                timeout: WaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(app.buttons["filterSummary.person.button"].exists)

        attachScreenshot(app: app, name: "dark-mode-filter-summary")
    }

    @MainActor
    func testIPhonePortraitAndLandscapeModeSelectionFlow() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        assertModeSelectionCoreElements(app: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.elementAppearanceTimeoutSeconds) { app.buttons["mode.random.button"].exists })
        assertModeSelectionCoreElements(app: app)

        tapElement(app.buttons["mode.random.button"])
        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(continueButton.isEnabled)
        tapElement(continueButton)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: WaitTiming.playbackControlTimeoutSeconds))

        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testIPhonePortraitAndLandscapeSlideshowControls() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        let settingsButton = app.buttons["slideshow.control.settings.button"]
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds))
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds))

        playPauseButton.tap()
        playPauseButton.tap()

        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(settingsButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
        app.tap()
        settingsButton.tap()

        XCTAssertTrue(
            waitForAnySettingsSurface(app: app, timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Should be able to open settings in landscape")
        returnToSlideshowFromSettings(app: app)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(settingsButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))
    }

    @MainActor
    func testIPhonePortraitAndLandscapeFirstBootElements() throws {
        let app = launchApp(shouldResetState: true)

        XCTAssertTrue(
            app.textFields["firstboot.serverURL.field"].waitForExistence(
                timeout: WaitTiming.settingsChangeTimeoutSeconds))
        XCTAssertTrue(app.secureTextFields["firstboot.apiKey.field"].exists)
        XCTAssertTrue(app.buttons["firstboot.testConnection.button"].exists)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            app.textFields["firstboot.serverURL.field"].waitForExistence(
                timeout: WaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(app.secureTextFields["firstboot.apiKey.field"].exists)
        XCTAssertTrue(app.buttons["firstboot.saveConfig.button"].exists)

        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testIPhonePortraitAndLandscapeFilterSummaryToAlbum() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true, shouldSeedFilterSelection: true)
        startFilteredFlowFromModeSelection(app: app)

        let albumButton = app.buttons["filterSummary.album.button"]
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(albumButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))

        tapElement(albumButton)
        assertInAlbumFilterPage(app: app)
        tapChevronBackIfNeeded(app: app)
        XCTAssertTrue(
            app.buttons["filterSummary.startPlayback.button"].waitForExistence(
                timeout: WaitTiming.controlAppearanceTimeoutSeconds))
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testIPhonePortraitAndLandscapeFilterSummaryToPerson() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true, shouldSeedFilterSelection: true)
        startFilteredFlowFromModeSelection(app: app)

        let personButton = app.buttons["filterSummary.person.button"]
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(personButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
        tapElement(personButton)
        assertInPersonFilterPage(app: app)
        tapChevronBackIfNeeded(app: app)
        XCTAssertTrue(
            app.buttons["filterSummary.startPlayback.button"].waitForExistence(
                timeout: WaitTiming.controlAppearanceTimeoutSeconds))
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testEmptyAlbumAndPersonFilterPagesCanReturn() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launchEnvironment["UI_TEST_SERVER_URL"] = "https://ui-test-empty-filter.invalid"
        app.launchEnvironment["UI_TEST_API_KEY"] = "ui-test-empty-filter-key"
        app.launchEnvironment["UI_TEST_FORCE_EMPTY_FILTER_DATA"] = "all"
        app.launch()

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "After injecting the test server config, the app should go straight to mode selection"
        )
        startFilteredFlowFromModeSelection(app: app)

        let albumButton = app.buttons["filterSummary.album.button"]
        XCTAssertTrue(
            albumButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Filter summary should show the album entry")
        tapElement(albumButton)

        let albumBackButton = app.buttons["albumFilter.back.button"]
        XCTAssertTrue(
            albumBackButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Empty album page should show a back button")
        // ui-label-lookup: Verify the displayed empty-album message itself.
        XCTAssertTrue(app.staticTexts["immich 中还没有相册"].exists, "Empty album page should show the empty-state message")
        attachScreenshot(app: app, name: "empty-album-filter-has-back-button")
        tapElement(albumBackButton)

        let personButton = app.buttons["filterSummary.person.button"]
        XCTAssertTrue(
            personButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Going back from the empty album page should return to the filter summary")
        tapElement(personButton)

        let personBackButton = app.buttons["personFilter.back.button"]
        XCTAssertTrue(
            personBackButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Empty people page should show a back button")
        // ui-label-lookup: Verify the displayed empty-people message itself.
        XCTAssertTrue(app.staticTexts["immich 中还没有人物"].exists, "Empty people page should show the empty-state message")
        attachScreenshot(app: app, name: "empty-person-filter-has-back-button")
        tapElement(personBackButton)

        XCTAssertTrue(
            app.buttons["filterSummary.album.button"].waitForExistence(
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Going back from the empty people page should return to the filter summary"
        )
    }

    @MainActor
    func testIPhonePortraitAndLandscapeSettingsSectionsNavigation() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        openSettingsFromSlideshow(app: app)
        XCTAssertTrue(waitForAnySettingsSurface(app: app, timeout: WaitTiming.controlAppearanceTimeoutSeconds))

        openSettingsSection(app: app, sectionID: "settings.item.playback")
        XCTAssertTrue(
            app.switches["settings.playback.autoPlay.toggle"].waitForExistence(
                timeout: WaitTiming.settingsChangeTimeoutSeconds))

        XCUIDevice.shared.orientation = .landscapeLeft
        openSettingsSection(app: app, sectionID: "settings.item.cache")
        XCTAssertTrue(
            app.buttons["settings.cache.clearDisk.button"].waitForExistence(
                timeout: WaitTiming.settingsChangeTimeoutSeconds))

        XCUIDevice.shared.orientation = .portrait
        returnToSlideshowFromSettings(app: app)
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: WaitTiming.controlAppearanceTimeoutSeconds))
    }

    // Visual pack that needs no test server: first-boot screenshots in light/dark and portrait/landscape.

    @MainActor
    func testVisualAuditPack_FirstBootMatrixSnapshots() throws {
        let schemes = ["light", "dark"]
        let orientations: [(name: String, value: UIDeviceOrientation)] = [
            ("portrait", .portrait),
            ("landscape", .landscapeLeft)
        ]

        for scheme in schemes {
            for orientation in orientations {
                let app = launchApp(shouldResetState: true, colorScheme: scheme)
                XCUIDevice.shared.orientation = orientation.value

                XCTAssertTrue(
                    app.textFields["firstboot.serverURL.field"].waitForExistence(
                        timeout: WaitTiming.settingsChangeTimeoutSeconds))
                XCTAssertTrue(app.secureTextFields["firstboot.apiKey.field"].exists)
                XCTAssertTrue(app.buttons["firstboot.testConnection.button"].exists)

                attachScreenshot(
                    app: app,
                    name: "audit-firstboot-\(scheme)-\(orientation.name)-\(currentDeviceTag())"
                )
                app.terminate()
            }
        }

        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testVisualAuditPack_InteractiveFlowSnapshots() throws {
        let config = try requireTestServerConfig()
        let schemes = ["light", "dark"]
        let orientations: [(name: String, value: UIDeviceOrientation)] = [
            ("portrait", .portrait),
            ("landscape", .landscapeLeft)
        ]

        for scheme in schemes {
            // Return to portrait before relaunching with another color scheme, otherwise the first-boot fields may
            // not get keyboard focus.

            XCUIDevice.shared.orientation = .portrait
            let app = launchApp(shouldResetState: true, shouldSeedFilterSelection: true, colorScheme: scheme)
            try completeFirstBootToModeSelection(app: app, serverURL: config.url, apiKey: config.apiKey)

            for orientation in orientations {
                XCUIDevice.shared.orientation = orientation.value
                XCTAssertTrue(
                    app.buttons["mode.random.button"].waitForExistence(
                        timeout: WaitTiming.elementAppearanceTimeoutSeconds))

                tapElement(app.buttons["mode.random.button"])
                attachScreenshot(
                    app: app,
                    name: "audit-mode-random-selected-\(scheme)-\(orientation.name)-\(currentDeviceTag())"
                )

                tapElement(app.buttons["mode.filtered.button"])
                attachScreenshot(
                    app: app,
                    name: "audit-mode-filtered-selected-\(scheme)-\(orientation.name)-\(currentDeviceTag())"
                )
            }

            let continueButton = app.buttons["mode.continue.button"]
            XCTAssertTrue(continueButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
            XCTAssertTrue(continueButton.isEnabled)
            tapElement(continueButton)
            XCTAssertTrue(
                app.buttons["filterSummary.album.button"].waitForExistence(
                    timeout: WaitTiming.controlAppearanceTimeoutSeconds))

            attachScreenshot(
                app: app,
                name: "audit-filter-summary-\(scheme)-\(currentDeviceTag())"
            )

            tapElement(app.buttons["filterSummary.album.button"])
            assertInAlbumFilterPage(app: app)
            attachScreenshot(
                app: app,
                name: "audit-album-filter-\(scheme)-\(currentDeviceTag())"
            )
            tapChevronBackIfNeeded(app: app)

            let startButton = app.buttons["filterSummary.startPlayback.button"]
            XCTAssertTrue(startButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))
            if startButton.isEnabled {
                tapElement(startButton)
                XCTAssertTrue(
                    app.buttons["slideshow.control.settings.button"].waitForExistence(
                        timeout: WaitTiming.playbackControlTimeoutSeconds))
                attachScreenshot(
                    app: app,
                    name: "audit-slideshow-\(scheme)-\(currentDeviceTag())"
                )
            }

            app.terminate()
        }

        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testRandomModeHidesPlaybackBackButtonWithoutPIN() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: WaitTiming.playbackControlTimeoutSeconds),
            "After entering playback in random mode, the settings entry should remain")
        XCTAssertFalse(
            app.buttons["global.back.button"].exists,
            "After entering playback in random mode, the top-left back button should no longer show")
    }

    @MainActor
    func testFilteredModeKeepsFilterSummaryBackButHidesPlaybackBackButton() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true, shouldSeedFilterSelection: true)
        startFilteredFlowFromModeSelection(app: app)

        let globalBackButton = app.buttons["global.back.button"]
        XCTAssertTrue(
            globalBackButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "Filter summary should be able to go back to mode selection")
        XCTAssertFalse(
            app.buttons["filterSummary.backToMode.button"].exists,
            "Filter summary should no longer show an extra bottom Back to Mode Selection button"
        )
        globalBackButton.tap()
        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))

        startFilteredFlowFromModeSelection(app: app)

        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(startPlaybackButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(startPlaybackButton.isEnabled, "With a non-empty filter, Start Playback should be tappable")
        startPlaybackButton.tap()

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: WaitTiming.playbackControlTimeoutSeconds))
        XCTAssertFalse(
            app.buttons["global.back.button"].exists,
            "After entering playback from the filter flow, the top-left back button should no longer show")
    }

    @MainActor
    func testPinProtectionBlocksBackAndRequiresPINForSettings() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        openSettingsFromSlideshow(app: app)
        openAccessProtectionSectionIfNeeded(app: app)

        tapSettingsPinInput(app: app, id: "settings.pin.input.enable")
        inputPinOnSheet(app: app, pin: "123456")
        tapSettingsPinInput(app: app, id: "settings.pin.input.enableConfirm")
        inputPinOnSheet(app: app, pin: "123456")

        let enableButton = app.buttons["settings.pin.enable.button"]
        XCTAssertTrue(enableButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(enableButton.isEnabled)
        enableButton.tap()

        returnToSlideshowFromSettings(app: app)

        XCTAssertFalse(
            app.buttons["global.back.button"].exists, "With PIN on, the playback page should still show no back button")

        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
        settingsButton.tap()

        let closePinEntry = app.buttons["pinEntry.close.button"]
        XCTAssertTrue(
            closePinEntry.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "With PIN on, opening settings should first show PIN verification")

        inputPinOnSheet(app: app, pin: "000000")
        let retryHint = findFirstExistingIdentifiedText(
            in: app,
            identifiers: ["pinEntry.error.message"],
            timeout: WaitTiming.shortInteractionTimeoutSeconds
        )
        XCTAssertNotNil(retryHint)
        // ui-label-lookup: Verify the Simplified Chinese wrong-PIN retry hint after identifier lookup.
        XCTAssertEqual(retryHint?.label, "PIN 错误，请重试")

        inputPinOnSheet(app: app, pin: "123456")
        let pinSheetCloseButton = app.buttons["pinEntry.close.button"]
        XCTAssertFalse(
            pinSheetCloseButton.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "After entering the correct PIN, the PIN sheet should close")
    }

    // Only checks that the config and PIN survive a relaunch; returning from settings is not mixed in.
    @MainActor
    func testPinAndServerConfigPersistAfterRelaunch() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        openSettingsFromSlideshow(app: app)
        openAccessProtectionSectionIfNeeded(app: app)

        tapSettingsPinInput(app: app, id: "settings.pin.input.enable")
        inputPinOnSheet(app: app, pin: "123456")
        tapSettingsPinInput(app: app, id: "settings.pin.input.enableConfirm")
        inputPinOnSheet(app: app, pin: "123456")
        app.buttons["settings.pin.enable.button"].tap()

        XCTAssertTrue(
            app.buttons["settings.pin.disable.button"].waitForExistence(
                timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "After enabling PIN, settings should switch to the enabled state"
        )

        app.terminate()
        app.launchEnvironment.removeAll()
        app.launch()

        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForExistence(timeout: WaitTiming.readbackTimeoutSeconds),
            "After relaunch, the app should not return to first-boot setup")
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: WaitTiming.connectionTimeoutSeconds),
            "After relaunch, the app should go straight back to playback")
        XCTAssertFalse(
            app.buttons["global.back.button"].exists,
            "After relaunch with a persisted PIN, the playback page should still show no back button")

        app.buttons["slideshow.control.settings.button"].tap()
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "After relaunch with a persisted PIN, opening settings should still require verification")
        attachScreenshot(app: app, name: "Desktop-relaunch-pin-gate")
    }

    // Playback settings constraint: with an empty filter, switching to filtered playback is blocked with an alert.
    @MainActor
    func testPlaybackSettingsBlocksFilteredModeWhenSelectionEmpty() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        openSettingsFromSlideshow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.playback")

        let playbackModePicker = app.segmentedControls["settings.playback.mode.picker"]
        XCTAssertTrue(playbackModePicker.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds))
        let filteredModeSegment = playbackModePicker.buttons.element(boundBy: 1)
        XCTAssertTrue(filteredModeSegment.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds))
        filteredModeSegment.tap()

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let blockedAlertTitle = findFirstExistingStaticText(
            in: app,
            labels: ["无法切换到筛选播放", "Can't Switch to Filtered Playback"],
            timeout: WaitTiming.elementAppearanceTimeoutSeconds
        )
        XCTAssertNotNil(blockedAlertTitle, "With an empty filter, the switch should be blocked with an alert")
        attachScreenshot(app: app, name: "ios-settings-playback-blocked-alert")
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        tapFirstExistingButton(in: app, labels: ["取消", "Cancel"])
    }

    @MainActor
    func testPlaybackSettingsDisplayModePickerCanSelectSinglePhoto() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        openSettingsFromSlideshow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.playback")

        let displayModePicker = app.segmentedControls["settings.playback.displayMode.picker"]
        XCTAssertTrue(
            displayModePicker.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "Playback settings should show the display mode segmented control")

        let smartFillSegment = displayModePicker.buttons["settings.playback.displayMode.smartFill.option"]
        let singlePhotoSegment = displayModePicker.buttons["settings.playback.displayMode.singlePhoto.option"]
        XCTAssertTrue(
            smartFillSegment.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "Display mode should offer Smart Fill")
        XCTAssertTrue(
            singlePhotoSegment.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "Display mode should offer Single Photo")

        singlePhotoSegment.tap()
        attachScreenshot(app: app, name: "ios-settings-playback-display-mode-single-photo")

        XCTAssertTrue(
            singlePhotoSegment.exists,
            "After switching to single photo mode, the display mode control should stay stable")
    }

    // The connection failure alert must appear on the current detail page, not only after going back to the list.

    @MainActor
    func testServerSettingsShowsConnectionErrorAlertImmediately() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        openSettingsFromSlideshow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.server")

        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(serverField.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds))
        serverField.tap()
        serverField.clearAndType(text: "foo://invalid-host")

        let testConnectionButton = app.buttons["firstboot.testConnection.button"]
        XCTAssertTrue(testConnectionButton.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds))
        dismissKeyboardIfNeeded(app: app)
        tapElement(testConnectionButton)

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let errorAlertTitle = findFirstExistingStaticText(
            in: app,
            labels: ["连接测试失败", "Connection test failed", "Connection Test Failed"],
            timeout: WaitTiming.elementAppearanceTimeoutSeconds
        )
        XCTAssertNotNil(
            errorAlertTitle,
            "When the connection test fails on the server settings detail page, an error should show immediately")
        attachScreenshot(app: app, name: "ios-settings-server-error-alert")
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        tapFirstExistingButton(in: app, labels: ["确定", "OK"])
    }

    @MainActor
    func testServerSettingsAPIKeyHelpSheet() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        openSettingsFromSlideshow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.server")

        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "Server settings should show the server address field")

        let helpButton = app.buttons["server.apiKey.help.button"]
        XCTAssertTrue(
            helpButton.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "Server settings should show the help entry next to the API Key title")
        tapElement(helpButton)

        let sheet = app.descendants(matching: .any)["server.apiKey.help.sheet"]
        XCTAssertTrue(
            sheet.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "Tapping the help entry should show the API Key help sheet")
        XCTAssertTrue(
            app.staticTexts["server.apiKey.help.sheet"].waitForExistence(
                timeout: WaitTiming.shortInteractionTimeoutSeconds))
        XCTAssertTrue(app.staticTexts["server.apiKey.help.section.list.number.title"].exists)
        XCTAssertTrue(app.staticTexts["server.apiKey.help.section.checklist.title"].exists)

        if !app.staticTexts["server.apiKey.help.section.key.fill.title"].exists {
            sheet.swipeUp()
        }
        XCTAssertTrue(
            app.staticTexts["server.apiKey.help.section.key.fill.title"].waitForExistence(
                timeout: WaitTiming.readbackTimeoutSeconds))
        attachScreenshot(app: app, name: "ios-settings-server-api-key-help-sheet")

        let closeButton = app.buttons["server.apiKey.help.close.button"]
        XCTAssertTrue(
            closeButton.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "Help sheet should provide a tappable close button")
        tapElement(closeButton)

        XCTAssertFalse(
            sheet.waitForExistence(timeout: WaitTiming.briefElementTimeoutSeconds),
            "The help sheet should be gone after closing it")
        XCTAssertTrue(
            serverField.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "After closing the help sheet, the server settings form should be back")
        XCTAssertTrue(app.secureTextFields["firstboot.apiKey.field"].exists)
    }

    @MainActor
    func testCacheManagementClearDiskCacheEntryWorks() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        openSettingsFromSlideshow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.cache")

        let clearDiskButton = app.buttons["settings.cache.clearDisk.button"]
        XCTAssertTrue(clearDiskButton.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds))
        clearDiskButton.tap()

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let confirmAlertTitle = findFirstExistingStaticText(
            in: app,
            labels: ["确认清理磁盘缓存", "Confirm Disk Cache Clear"],
            timeout: WaitTiming.elementAppearanceTimeoutSeconds
        )
        XCTAssertNotNil(confirmAlertTitle)
        attachScreenshot(app: app, name: "ios-settings-cache-confirm-alert")
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        tapFirstExistingButton(in: app, labels: ["取消", "Cancel"])
    }

    @MainActor
    func testResetStateEnvironmentForcesFirstBootAfterConfigured() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: WaitTiming.navigationTimeoutSeconds))

        app.terminate()
        // Clear the server injection when verifying reset, otherwise it is written back after the wipe.
        app.launchEnvironment.removeAll()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launch()

        XCTAssertTrue(
            app.textFields["firstboot.serverURL.field"].waitForExistence(
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "UI_TEST_RESET_STATE=1 should force a return to first-boot setup"
        )
    }

    @MainActor
    func testPlaybackSettingAutoPlayAppliesAfterBackToSlideshow() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        openSettingsFromSlideshow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.playback")

        let autoPlayToggle = app.switches["settings.playback.autoPlay.toggle"]
        XCTAssertTrue(autoPlayToggle.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds))
        if isToggleOn(autoPlayToggle) {
            autoPlayToggle.tap()
        }
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.stateChangeTimeoutSeconds) { !self.isToggleOn(autoPlayToggle) },
            "Auto-play toggle should be off")

        returnToSlideshowFromSettings(app: app)

        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.stateChangeTimeoutSeconds) {
                ((playPauseButton.value as? String) ?? "").lowercased() == "play"
            }, "After turning off auto-play, the playback control bar should immediately show the play state")
    }

    @MainActor
    func testCacheClearShowsSuccessMessageAfterConfirm() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        openSettingsFromSlideshow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.cache")

        let clearDiskButton = app.buttons["settings.cache.clearDisk.button"]
        XCTAssertTrue(clearDiskButton.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds))
        clearDiskButton.tap()

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let confirmAlertTitles = [
            "确认清理磁盘缓存",
            "Confirm Disk Cache Clear",
            "確認清理磁碟緩存",
            "ディスクキャッシュクリアの確認",
            "Confirmar limpieza de caché"
        ]
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.elementAppearanceTimeoutSeconds) {
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                confirmAlertTitles.contains { app.alerts[$0].exists }
            }
        )
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        tapFirstExistingButton(
            in: app,
            labels: ["清理", "Clear", "清除", "クリア", "Borrar"]
        )

        let successStatus = app.staticTexts["settings.cache.status.message"]
        XCTAssertTrue(
            successStatus.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "Success status message should show after clearing")
        attachScreenshot(app: app, name: "Desktop-cache-clear-success")
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

private extension immichSlidesUITests {
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
            app.buttons["mode.continue.button"].waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "After injecting the test server at launch, the app should go straight to mode selection"
        )
        return app
    }

    func assertModeSelectionCoreElements(app: XCUIApplication) {
        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(app.buttons["mode.filtered.button"].exists)
        XCTAssertTrue(app.buttons["mode.continue.button"].exists)
    }

    func completeFirstBootToModeSelection(app: XCUIApplication, serverURL: String, apiKey: String) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        guard serverField.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds) else {
            throw XCTSkip("Not in first-boot state; skipping first-boot flow assertions.")
        }
        serverField.tap()
        serverField.clearAndType(text: serverURL)

        let apiField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiField.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
        apiField.tap()
        apiField.clearAndType(text: apiKey)

        let testConnectionButton = app.buttons["firstboot.testConnection.button"]
        XCTAssertTrue(testConnectionButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
        // Do not tap empty space to dismiss the keyboard first; on small screens that may hit the keyboard. Use
        // XCUIElement.tap instead, which scrolls the element into view.

        testConnectionButton.tap()

        let saveButton = app.buttons["firstboot.saveConfig.button"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))
        let saveEnabledExpectation = NSPredicate(format: "isEnabled == true")
        let saveEnabledWait = expectation(for: saveEnabledExpectation, evaluatedWith: saveButton)
        wait(for: [saveEnabledWait], timeout: 45)
        tapElement(saveButton)

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds))
    }

    func startRandomPlaybackFromModeSelection(app: XCUIApplication) {
        let modeRandomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(modeRandomButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
        tapElement(modeRandomButton)

        let modeContinueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(modeContinueButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(modeContinueButton.isEnabled)
        tapElement(modeContinueButton)

        XCTAssertTrue(waitForSlideshowSettingsButton(app: app, timeout: 25))
    }

    func startFilteredFlowFromModeSelection(app: XCUIApplication) {
        let modeFilteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(modeFilteredButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
        tapElement(modeFilteredButton)

        let modeContinueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(modeContinueButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(modeContinueButton.isEnabled)
        tapElement(modeContinueButton)

        XCTAssertTrue(
            app.buttons["filterSummary.startPlayback.button"].waitForExistence(
                timeout: WaitTiming.navigationTimeoutSeconds))
    }

    func openSettingsFromSlideshow(app: XCUIApplication) {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(waitForSlideshowSettingsButton(app: app, timeout: WaitTiming.connectionTimeoutSeconds))
        tapElement(settingsButton)
    }

    func openAccessProtectionSectionIfNeeded(app: XCUIApplication) {
        openSettingsSection(app: app, sectionID: "settings.item.accessProtection")
        XCTAssertTrue(
            app.buttons["settings.pin.enable.button"].waitForExistence(
                timeout: WaitTiming.controlAppearanceTimeoutSeconds)
                || app.buttons["settings.pin.disable.button"].waitForExistence(
                    timeout: WaitTiming.controlAppearanceTimeoutSeconds)
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
                if candidate.waitForExistence(timeout: WaitTiming.briefElementTimeoutSeconds) {
                    if candidate.isHittable {
                        candidate.tap()
                        return
                    }
                    tapElement(candidate)
                    return
                }
            }

            let identifiedEntry = app.descendants(matching: .any)[sectionID].firstMatch
            if identifiedEntry.waitForExistence(timeout: WaitTiming.briefElementTimeoutSeconds) {
                tapElement(identifiedEntry)
                return
            }

            let navBack = app.navigationBars.buttons.firstMatch
            if navBack.exists && navBack.isHittable {
                navBack.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.readbackPollSeconds))
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
            pinInputButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "PIN input entry not found: \(id)")
        pinInputButton.tap()
    }

    func inputPinOnSheet(app: XCUIApplication, pin: String) {
        for digit in pin {
            let key = app.buttons["pinEntry.digit.\(digit).button"]
            XCTAssertTrue(
                key.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
                "PIN digit key does not exist: \(digit)")
            key.tap()
        }
    }

    func returnToSlideshowFromSettings(app: XCUIApplication) {
        // Playback hides the control bar after settings dismiss; close any PIN sheet first, then pop back and wake it.
        for _ in 0..<8 {
            if app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: WaitTiming.readbackTimeoutSeconds)
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
                RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.selectionPollSeconds))
                continue
            }

            if waitForSlideshowSettingsButton(app: app, timeout: WaitTiming.readbackTimeoutSeconds) {
                return
            }
        }
        XCTAssertTrue(
            waitForSlideshowSettingsButton(app: app, timeout: WaitTiming.elementAppearanceTimeoutSeconds),
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
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.shortFocusSettleSeconds))
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
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.readbackPollSeconds))
        }
        return button.exists
    }

    func tapChevronBackIfNeeded(app: XCUIApplication) {
        // Prefer the pages' stable back identifiers; the system nav-bar label changes with language.
        for identifier in ["albumFilter.back.button", "personFilter.back.button"] {
            let stableBackButton = app.buttons[identifier]
            if stableBackButton.waitForExistence(timeout: WaitTiming.briefElementTimeoutSeconds),
                stableBackButton.isHittable
            {
                stableBackButton.tap()
                return
            }
        }

        let explicitBack = app.buttons["global.back.button"]
        if explicitBack.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds), explicitBack.isHittable {
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
                timeout: WaitTiming.controlAppearanceTimeoutSeconds
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
                timeout: WaitTiming.controlAppearanceTimeoutSeconds
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
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.pollIntervalSeconds))
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

private extension XCUIElement {
    func clearAndType(text: String) {
        guard let existing = self.value as? String else {
            self.typeText(text)
            return
        }

        self.tap()
        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)
        self.typeText(deleteString)
        self.typeText(text)
    }
}
#endif
