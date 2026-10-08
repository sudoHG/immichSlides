//
//  immichSlidesUITests.swift
//  immichSlidesUITests
//
//  Created by sudoHG on 2026/3/18.
//

import XCTest

enum immichSlidesUITestsWaitTiming {
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
        XCTAssertTrue(
            serverField.waitForExistence(
                timeout: TestWait.seconds(
                    .infrastructure(immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))))

        let apiField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiField.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))

        let saveButton = app.buttons["firstboot.saveConfig.button"]
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds))
        XCTAssertFalse(saveButton.isEnabled, "Save button should stay disabled before the connection is verified")

        serverField.tap()
        serverField.immichSlidesUITestsClearAndType(text: "foo://invalid-host")
        apiField.tap()
        apiField.immichSlidesUITestsClearAndType(text: "dummy-key")
        app.typeText("\n")

        let testConnectionButton = app.buttons["firstboot.testConnection.button"]
        XCTAssertTrue(
            testConnectionButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds)
        )
        dismissKeyboardIfNeeded(app: app)
        tapElement(testConnectionButton)

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let errorAlert = app.alerts.firstMatch
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let errorAlertTitle = findFirstExistingStaticText(
            in: app,
            labels: ["连接测试失败", "Connection test failed", "Connection Test Failed"],
            timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds
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
            helpButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "First-boot page should show the help entry next to the API Key title")
        tapElement(helpButton)

        let sheet = app.descendants(matching: .any)["server.apiKey.help.sheet"]
        XCTAssertTrue(
            sheet.waitForExistence(timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds),
            "Tapping the help entry should show the API Key help sheet")
        XCTAssertTrue(
            app.staticTexts["server.apiKey.help.sheet"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds))
        XCTAssertTrue(app.staticTexts["server.apiKey.help.section.list.number.title"].exists)
        XCTAssertTrue(app.staticTexts["server.apiKey.help.section.checklist.title"].exists)

        if !app.staticTexts["server.apiKey.help.section.key.fill.title"].exists {
            sheet.swipeUp()
        }
        XCTAssertTrue(
            app.staticTexts["server.apiKey.help.section.key.fill.title"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.readbackTimeoutSeconds))
        attachScreenshot(app: app, name: "firstboot-api-key-help-sheet")

        let closeButton = app.buttons["server.apiKey.help.close.button"]
        XCTAssertTrue(
            closeButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds),
            "Help sheet should provide a tappable close button")
        tapElement(closeButton)
        XCTAssertFalse(
            sheet.waitForExistence(timeout: immichSlidesUITestsWaitTiming.briefElementTimeoutSeconds),
            "The help sheet should be gone after closing it")
        XCTAssertTrue(
            app.secureTextFields["firstboot.apiKey.field"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds))
    }

    @MainActor
    func testDarkModeSnapshotModeSelection() throws {
        // Inject the server directly and stop on the mode page, so first boot interferes less with the screenshot.
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true, colorScheme: "dark")
        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
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
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(app.buttons["filterSummary.person.button"].exists)

        attachScreenshot(app: app, name: "dark-mode-filter-summary")
    }

    @MainActor
    func testIPhonePortraitAndLandscapeModeSelectionFlow() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        assertModeSelectionCoreElements(app: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            waitUntil(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds) {
                app.buttons["mode.random.button"].exists
            })
        assertModeSelectionCoreElements(app: app)

        tapElement(app.buttons["mode.random.button"])
        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(continueButton.isEnabled)
        tapElement(continueButton)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.playbackControlTimeoutSeconds))

        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testIPhonePortraitAndLandscapeSlideshowControls() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        let settingsButton = app.buttons["slideshow.control.settings.button"]
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.navigationTimeoutSeconds))
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.navigationTimeoutSeconds))

        playPauseButton.tap()
        playPauseButton.tap()

        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        app.tap()
        settingsButton.tap()

        XCTAssertTrue(
            waitForAnySettingsSurface(app: app, timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Should be able to open settings in landscape")
        returnToSlideshowFromSettings(app: app)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))
    }

    @MainActor
    func testIPhonePortraitAndLandscapeFirstBootElements() throws {
        let app = launchApp(shouldResetState: true)

        XCTAssertTrue(
            app.textFields["firstboot.serverURL.field"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds))
        XCTAssertTrue(app.secureTextFields["firstboot.apiKey.field"].exists)
        XCTAssertTrue(app.buttons["firstboot.testConnection.button"].exists)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            app.textFields["firstboot.serverURL.field"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
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
        XCTAssertTrue(
            albumButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))

        tapElement(albumButton)
        assertInAlbumFilterPage(app: app)
        tapChevronBackIfNeeded(app: app)
        XCTAssertTrue(
            app.buttons["filterSummary.startPlayback.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testIPhonePortraitAndLandscapeFilterSummaryToPerson() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true, shouldSeedFilterSelection: true)
        startFilteredFlowFromModeSelection(app: app)

        let personButton = app.buttons["filterSummary.person.button"]
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(
            personButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        tapElement(personButton)
        assertInPersonFilterPage(app: app)
        tapChevronBackIfNeeded(app: app)
        XCTAssertTrue(
            app.buttons["filterSummary.startPlayback.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))
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
            app.buttons["mode.continue.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.navigationTimeoutSeconds),
            "After injecting the test server config, the app should go straight to mode selection"
        )
        startFilteredFlowFromModeSelection(app: app)

        let albumButton = app.buttons["filterSummary.album.button"]
        XCTAssertTrue(
            albumButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Filter summary should show the album entry")
        tapElement(albumButton)

        let albumBackButton = app.buttons["albumFilter.back.button"]
        XCTAssertTrue(
            albumBackButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Empty album page should show a back button")
        // ui-label-lookup: Verify the displayed empty-album message itself.
        XCTAssertTrue(app.staticTexts["Immich 中还没有相册"].exists, "Empty album page should show the empty-state message")
        attachScreenshot(app: app, name: "empty-album-filter-has-back-button")
        tapElement(albumBackButton)

        let personButton = app.buttons["filterSummary.person.button"]
        XCTAssertTrue(
            personButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Going back from the empty album page should return to the filter summary")
        tapElement(personButton)

        let personBackButton = app.buttons["personFilter.back.button"]
        XCTAssertTrue(
            personBackButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Empty people page should show a back button")
        // ui-label-lookup: Verify the displayed empty-people message itself.
        XCTAssertTrue(app.staticTexts["Immich 中还没有人物"].exists, "Empty people page should show the empty-state message")
        attachScreenshot(app: app, name: "empty-person-filter-has-back-button")
        tapElement(personBackButton)

        XCTAssertTrue(
            app.buttons["filterSummary.album.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Going back from the empty people page should return to the filter summary"
        )
    }

    @MainActor
    func testIPhonePortraitAndLandscapeSettingsSectionsNavigation() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        openSettingsFromSlideshow(app: app)
        XCTAssertTrue(
            waitForAnySettingsSurface(app: app, timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))

        openSettingsSection(app: app, sectionID: "settings.item.playback")
        XCTAssertTrue(
            app.switches["settings.playback.autoPlay.toggle"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds))

        XCUIDevice.shared.orientation = .landscapeLeft
        openSettingsSection(app: app, sectionID: "settings.item.cache")
        XCTAssertTrue(
            app.buttons["settings.cache.clearDisk.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds))

        XCUIDevice.shared.orientation = .portrait
        returnToSlideshowFromSettings(app: app)
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))
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
                        timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds))
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
                        timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))

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
            XCTAssertTrue(
                continueButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
            XCTAssertTrue(continueButton.isEnabled)
            tapElement(continueButton)
            XCTAssertTrue(
                app.buttons["filterSummary.album.button"].waitForExistence(
                    timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))

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
            XCTAssertTrue(
                startButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))
            if startButton.isEnabled {
                tapElement(startButton)
                XCTAssertTrue(
                    app.buttons["slideshow.control.settings.button"].waitForExistence(
                        timeout: immichSlidesUITestsWaitTiming.playbackControlTimeoutSeconds))
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
                timeout: immichSlidesUITestsWaitTiming.playbackControlTimeoutSeconds),
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
            globalBackButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "Filter summary should be able to go back to mode selection")
        XCTAssertFalse(
            app.buttons["filterSummary.backToMode.button"].exists,
            "Filter summary should no longer show an extra bottom Back to Mode Selection button"
        )
        globalBackButton.tap()
        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))

        startFilteredFlowFromModeSelection(app: app)

        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startPlaybackButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds)
        )
        XCTAssertTrue(startPlaybackButton.isEnabled, "With a non-empty filter, Start Playback should be tappable")
        startPlaybackButton.tap()

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.playbackControlTimeoutSeconds))
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
        XCTAssertTrue(
            enableButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(enableButton.isEnabled)
        enableButton.tap()

        returnToSlideshowFromSettings(app: app)

        XCTAssertFalse(
            app.buttons["global.back.button"].exists, "With PIN on, the playback page should still show no back button")

        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        settingsButton.tap()

        let closePinEntry = app.buttons["pinEntry.close.button"]
        XCTAssertTrue(
            closePinEntry.waitForExistence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "With PIN on, opening settings should first show PIN verification")

        inputPinOnSheet(app: app, pin: "000000")
        let retryHint = findFirstExistingIdentifiedText(
            in: app,
            identifiers: ["pinEntry.error.message"],
            timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds
        )
        XCTAssertNotNil(retryHint)
        // ui-label-lookup: Verify the Simplified Chinese wrong-PIN retry hint after identifier lookup.
        XCTAssertEqual(retryHint?.label, "PIN 错误，请重试")

        inputPinOnSheet(app: app, pin: "123456")
        let pinSheetCloseButton = app.buttons["pinEntry.close.button"]
        XCTAssertFalse(
            pinSheetCloseButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds),
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
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "After enabling PIN, settings should switch to the enabled state"
        )

        app.terminate()
        app.launchEnvironment.removeAll()
        app.launch()

        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.readbackTimeoutSeconds),
            "After relaunch, the app should not return to first-boot setup")
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.connectionTimeoutSeconds),
            "After relaunch, the app should go straight back to playback")
        XCTAssertFalse(
            app.buttons["global.back.button"].exists,
            "After relaunch with a persisted PIN, the playback page should still show no back button")

        app.buttons["slideshow.control.settings.button"].tap()
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "After relaunch with a persisted PIN, opening settings should still require verification")
        attachScreenshot(app: app, name: "Desktop-relaunch-pin-gate")
    }
}

extension XCUIElement {
    func immichSlidesUITestsClearAndType(text: String) {
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
