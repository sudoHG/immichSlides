//
//  immichSlidesUITests.swift
//  immichSlidesUITests
//
//  Created by sudoHG on 2026/3/18.
//

import XCTest

enum immichSlidesUITestsWaitTiming {
    static let briefElementTimeoutSeconds: TimeInterval = TestWait.seconds(.product(1))
    static let connectionTimeoutSeconds: TimeInterval = TestWait.seconds(.product(15))
    static let controlAppearanceTimeoutSeconds: TimeInterval = TestWait.seconds(.product(8))
    static let elementAppearanceTimeoutSeconds: TimeInterval = TestWait.seconds(.product(5))
    static let navigationTimeoutSeconds: TimeInterval = TestWait.seconds(.product(10))
    static let playbackControlTimeoutSeconds: TimeInterval = TestWait.seconds(.product(20))
    static let pollIntervalSeconds: TimeInterval = TestWait.seconds(.product(0.1))
    static let readbackPollSeconds: TimeInterval = TestWait.seconds(.product(0.2))
    static let readbackTimeoutSeconds: TimeInterval = TestWait.seconds(.product(2))
    static let selectionPollSeconds: TimeInterval = TestWait.seconds(.product(0.25))
    static let settingsChangeTimeoutSeconds: TimeInterval = TestWait.seconds(.product(6))
    static let shortFocusSettleSeconds: TimeInterval = TestWait.seconds(.product(0.15))
    static let shortInteractionTimeoutSeconds: TimeInterval = TestWait.seconds(.product(3))
    static let stateChangeTimeoutSeconds: TimeInterval = TestWait.seconds(.product(4))
}

#if os(iOS)
final class immichSlidesUITests: XCTestCase {
    override func invokeTest() {
        FirstFailureContext.reset()
        super.invokeTest()
    }

    override func record(_ issue: XCTIssue) {
        FirstFailureEvidence.record(self, issue: issue)
        super.record(issue)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        if !name.contains("testCacheClearShowsSuccessMessageAfterConfirm") {
            try requireIPhoneDestination()
        }
        // Reset to portrait at the start of each test so a previous landscape test does not carry over.

        FirstFailureOrientation.set(.portrait)
    }

    @MainActor
    func testFirstBootValidationAndDisabledSaveButton() throws {
        let app = launchApp(shouldResetState: true)

        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForPublicElement(
                "firstboot.serverURL.field",
                timeout: TestWait.seconds(
                    .infrastructure(immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))))

        let apiField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiField.waitForPublicElement(
                "firstboot.apiKey.field", timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))

        let saveButton = app.buttons["firstboot.saveConfig.button"]
        XCTAssertTrue(
            saveButton.waitForPublicElement(
                "firstboot.saveConfig.button", timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds))
        XCTAssertFalse(saveButton.isEnabled, "Save button should stay disabled before the connection is verified")

        serverField.tapForFailureEvidence()
        serverField.immichSlidesUITestsClearAndType(text: "foo://invalid-host")
        apiField.tapForFailureEvidence()
        apiField.immichSlidesUITestsClearAndType(text: "dummy-key")
        app.typeForFailureEvidence("\n")

        let testConnectionButton = app.buttons["firstboot.testConnection.button"]
        XCTAssertTrue(
            testConnectionButton.waitForPublicElement(
                "firstboot.testConnection.button", timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds
            )
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
            helpButton.waitForFailureEvidence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "First-boot page should show the help entry next to the API Key title")
        tapElement(helpButton)

        let sheet = app.descendants(matching: .any)["server.apiKey.help.sheet"]
        XCTAssertTrue(
            sheet.waitForFailureEvidence(timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds),
            "Tapping the help entry should show the API Key help sheet")
        XCTAssertTrue(
            app.staticTexts["server.apiKey.help.sheet"].waitForFailureEvidence(
                timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds))
        XCTAssertTrue(app.staticTexts["server.apiKey.help.section.list.number.title"].exists)
        XCTAssertTrue(app.staticTexts["server.apiKey.help.section.checklist.title"].exists)

        if !app.staticTexts["server.apiKey.help.section.key.fill.title"].exists {
            sheet.swipeUpForFailureEvidence()
        }
        XCTAssertTrue(
            app.staticTexts["server.apiKey.help.section.key.fill.title"].waitForFailureEvidence(
                timeout: immichSlidesUITestsWaitTiming.readbackTimeoutSeconds))
        attachScreenshot(app: app, name: "firstboot-api-key-help-sheet")

        let closeButton = app.buttons["server.apiKey.help.close.button"]
        XCTAssertTrue(
            closeButton.waitForFailureEvidence(timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds),
            "Help sheet should provide a tappable close button")
        tapElement(closeButton)
        XCTAssertFalse(
            sheet.waitForFailureEvidence(timeout: immichSlidesUITestsWaitTiming.briefElementTimeoutSeconds),
            "The help sheet should be gone after closing it")
        XCTAssertTrue(
            app.secureTextFields["firstboot.apiKey.field"].waitForPublicElement(
                "firstboot.apiKey.field",
                timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds))
    }

    @MainActor
    func testDarkModeSnapshotModeSelection() throws {
        // Inject the server directly and stop on the mode page, so first boot interferes less with the screenshot.
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true, colorScheme: "dark")
        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForPublicElement(
                "mode.random.button",
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
            app.buttons["filterSummary.album.button"].waitForFailureEvidence(
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(app.buttons["filterSummary.person.button"].exists)

        attachScreenshot(app: app, name: "dark-mode-filter-summary")
    }

    @MainActor
    func testIPhonePortraitAndLandscapeModeSelectionFlow() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        assertModeSelectionCoreElements(app: app)

        FirstFailureOrientation.set(.landscapeLeft)
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
            app.buttons["slideshow.control.settings.button"].waitForPublicElement(
                "slideshow.control.settings.button",
                timeout: immichSlidesUITestsWaitTiming.playbackControlTimeoutSeconds))

        FirstFailureOrientation.set(.portrait)
    }

    @MainActor
    func testIPhonePortraitAndLandscapeSlideshowControls() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        let settingsButton = app.buttons["slideshow.control.settings.button"]
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            settingsButton.waitForPublicElement(
                "slideshow.control.settings.button", timeout: immichSlidesUITestsWaitTiming.navigationTimeoutSeconds))
        XCTAssertTrue(
            playPauseButton.waitForPublicElement(
                "slideshow.control.playPause.button", timeout: immichSlidesUITestsWaitTiming.navigationTimeoutSeconds))

        // The control bar auto-hides 8 seconds after the last interaction; a slow runner can cross that between
        // the lookup above and this tap, so wake it right before tapping.
        app.tapForFailureEvidence()
        XCTAssertTrue(
            playPauseButton.waitForPublicElement(
                "slideshow.control.playPause.button",
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "A tap on the slideshow should bring the control bar back")
        playPauseButton.tapForFailureEvidence()
        playPauseButton.tapForFailureEvidence()

        FirstFailureOrientation.set(.landscapeRight)
        XCTAssertTrue(
            settingsButton.waitForPublicElement(
                "slideshow.control.settings.button",
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(
            playPauseButton.waitForPublicElement(
                "slideshow.control.playPause.button",
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        app.tapForFailureEvidence()
        settingsButton.tapForFailureEvidence()

        XCTAssertTrue(
            waitForAnySettingsSurface(app: app, timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Should be able to open settings in landscape")
        returnToSlideshowFromSettings(app: app)

        FirstFailureOrientation.set(.portrait)
        XCTAssertTrue(
            settingsButton.waitForPublicElement(
                "slideshow.control.settings.button",
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))
    }

    @MainActor
    func testIPhonePortraitAndLandscapeFirstBootElements() throws {
        let app = launchApp(shouldResetState: true)

        XCTAssertTrue(
            app.textFields["firstboot.serverURL.field"].waitForPublicElement(
                "firstboot.serverURL.field",
                timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds))
        XCTAssertTrue(app.secureTextFields["firstboot.apiKey.field"].exists)
        XCTAssertTrue(app.buttons["firstboot.testConnection.button"].exists)

        FirstFailureOrientation.set(.landscapeLeft)
        XCTAssertTrue(
            app.textFields["firstboot.serverURL.field"].waitForPublicElement(
                "firstboot.serverURL.field",
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(app.secureTextFields["firstboot.apiKey.field"].exists)
        XCTAssertTrue(app.buttons["firstboot.saveConfig.button"].exists)

        FirstFailureOrientation.set(.portrait)
    }

    @MainActor
    func testIPhonePortraitAndLandscapeFilterSummaryToAlbum() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true, shouldSeedFilterSelection: true)
        startFilteredFlowFromModeSelection(app: app)

        let albumButton = app.buttons["filterSummary.album.button"]
        FirstFailureOrientation.set(.landscapeRight)
        XCTAssertTrue(
            albumButton.waitForFailureEvidence(timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))

        tapElement(albumButton)
        assertInAlbumFilterPage(app: app)
        tapChevronBackIfNeeded(app: app)
        XCTAssertTrue(
            app.buttons["filterSummary.startPlayback.button"].waitForFailureEvidence(
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        FirstFailureOrientation.set(.portrait)
    }

    @MainActor
    func testIPhonePortraitAndLandscapeFilterSummaryToPerson() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true, shouldSeedFilterSelection: true)
        startFilteredFlowFromModeSelection(app: app)

        let personButton = app.buttons["filterSummary.person.button"]
        FirstFailureOrientation.set(.landscapeRight)
        XCTAssertTrue(
            personButton.waitForFailureEvidence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        tapElement(personButton)
        assertInPersonFilterPage(app: app)
        tapChevronBackIfNeeded(app: app)
        XCTAssertTrue(
            app.buttons["filterSummary.startPlayback.button"].waitForFailureEvidence(
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        FirstFailureOrientation.set(.portrait)
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
        app.launchForFailureEvidence()

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForPublicElement(
                "mode.continue.button",
                timeout: immichSlidesUITestsWaitTiming.navigationTimeoutSeconds),
            "After injecting the test server config, the app should go straight to mode selection"
        )
        startFilteredFlowFromModeSelection(app: app)

        let albumButton = app.buttons["filterSummary.album.button"]
        XCTAssertTrue(
            albumButton.waitForFailureEvidence(timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Filter summary should show the album entry")
        tapElement(albumButton)

        let albumBackButton = app.buttons["albumFilter.back.button"]
        XCTAssertTrue(
            albumBackButton.waitForFailureEvidence(
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Empty album page should show a back button")
        // ui-label-lookup: Verify the displayed empty-album message itself.
        XCTAssertTrue(app.staticTexts["Immich 中还没有相册"].exists, "Empty album page should show the empty-state message")
        attachScreenshot(app: app, name: "empty-album-filter-has-back-button")
        tapElement(albumBackButton)

        let personButton = app.buttons["filterSummary.person.button"]
        XCTAssertTrue(
            personButton.waitForFailureEvidence(timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Going back from the empty album page should return to the filter summary")
        tapElement(personButton)

        let personBackButton = app.buttons["personFilter.back.button"]
        XCTAssertTrue(
            personBackButton.waitForFailureEvidence(
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Empty people page should show a back button")
        // ui-label-lookup: Verify the displayed empty-people message itself.
        XCTAssertTrue(app.staticTexts["Immich 中还没有人物"].exists, "Empty people page should show the empty-state message")
        attachScreenshot(app: app, name: "empty-person-filter-has-back-button")
        tapElement(personBackButton)

        XCTAssertTrue(
            app.buttons["filterSummary.album.button"].waitForFailureEvidence(
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Going back from the empty people page should return to the filter summary"
        )
    }

    @MainActor
    func testIPhonePortraitAndLandscapeSettingsSectionsNavigation() throws {
        let app = try launchConfiguredAppAtModeSelection(
            shouldResetState: true,
            extraLaunchEnvironment: SlideshowControlBarNavigationTestConfiguration.extendedAutoHideLaunchEnvironment
        )
        startRandomPlaybackFromModeSelection(app: app)

        openSettingsFromSlideshow(app: app)
        XCTAssertTrue(
            waitForAnySettingsSurface(app: app, timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))

        openSettingsSection(app: app, sectionID: "settings.item.playback")
        XCTAssertTrue(
            app.switches["settings.playback.autoPlay.toggle"].waitForPublicElement(
                "settings.playback.autoPlay.toggle",
                timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds))

        FirstFailureOrientation.set(.landscapeLeft)
        openSettingsSection(app: app, sectionID: "settings.item.cache")
        XCTAssertTrue(
            app.buttons["settings.cache.clearDisk.button"].waitForPublicElement(
                "settings.cache.clearDisk.button",
                timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds))

        FirstFailureOrientation.set(.portrait)
        returnToSlideshowFromSettings(app: app)
        XCTAssertTrue(
            app.waitForSlideshowControlBarButton(
                identifier: "slideshow.control.settings.button",
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
                FirstFailureOrientation.set(orientation.value)

                XCTAssertTrue(
                    app.textFields["firstboot.serverURL.field"].waitForPublicElement(
                        "firstboot.serverURL.field",
                        timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds))
                XCTAssertTrue(app.secureTextFields["firstboot.apiKey.field"].exists)
                XCTAssertTrue(app.buttons["firstboot.testConnection.button"].exists)

                attachScreenshot(
                    app: app,
                    name: "audit-firstboot-\(scheme)-\(orientation.name)-\(currentDeviceTag())"
                )
                app.terminateForFailureEvidence()
            }
        }

        FirstFailureOrientation.set(.portrait)
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

            FirstFailureOrientation.set(.portrait)
            let app = launchApp(shouldResetState: true, shouldSeedFilterSelection: true, colorScheme: scheme)
            try completeFirstBootToModeSelection(app: app, serverURL: config.url, apiKey: config.apiKey)

            for orientation in orientations {
                FirstFailureOrientation.set(orientation.value)
                XCTAssertTrue(
                    app.buttons["mode.random.button"].waitForPublicElement(
                        "mode.random.button",
                        timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))

                IOSFirstBootNavigation(app: app).selectMode(
                    "mode.random.button", timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds)
                attachScreenshot(
                    app: app,
                    name: "audit-mode-random-selected-\(scheme)-\(orientation.name)-\(currentDeviceTag())"
                )

                IOSFirstBootNavigation(app: app).selectMode(
                    "mode.filtered.button", timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds)
                attachScreenshot(
                    app: app,
                    name: "audit-mode-filtered-selected-\(scheme)-\(orientation.name)-\(currentDeviceTag())"
                )
            }

            guard
                let summaryDeadline = IOSFirstBootNavigation(app: app).selectModeAndContinue(
                    "mode.filtered.button", destinationIdentifier: "filterSummary.startPlayback.button")
            else { return }
            XCTAssertTrue(
                summaryDeadline.confirms { nodes in
                    nodes.contains { $0.identifier == "filterSummary.album.button" && $0.elementType == .button }
                })

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
                startButton.waitForFailureEvidence(
                    timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))
            if startButton.isEnabled {
                tapElement(startButton)
                XCTAssertTrue(
                    app.buttons["slideshow.control.settings.button"].waitForPublicElement(
                        "slideshow.control.settings.button",
                        timeout: immichSlidesUITestsWaitTiming.playbackControlTimeoutSeconds))
                attachScreenshot(
                    app: app,
                    name: "audit-slideshow-\(scheme)-\(currentDeviceTag())"
                )
            }

            app.terminateForFailureEvidence()
        }

        FirstFailureOrientation.set(.portrait)
    }

    @MainActor
    func testRandomModeHidesPlaybackBackButtonWithoutPIN() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForPublicElement(
                "slideshow.control.settings.button",
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
            globalBackButton.waitForFailureEvidence(
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "Filter summary should be able to go back to mode selection")
        XCTAssertFalse(
            app.buttons["filterSummary.backToMode.button"].exists,
            "Filter summary should no longer show an extra bottom Back to Mode Selection button"
        )
        globalBackButton.tapForFailureEvidence()
        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForPublicElement(
                "mode.continue.button",
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))

        startFilteredFlowFromModeSelection(app: app)

        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startPlaybackButton.waitForFailureEvidence(
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds)
        )
        XCTAssertTrue(startPlaybackButton.isEnabled, "With a non-empty filter, Start Playback should be tappable")
        startPlaybackButton.tapForFailureEvidence()

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForPublicElement(
                "slideshow.control.settings.button",
                timeout: immichSlidesUITestsWaitTiming.playbackControlTimeoutSeconds))
        XCTAssertFalse(
            app.buttons["global.back.button"].exists,
            "After entering playback from the filter flow, the top-left back button should no longer show")
    }

    @MainActor
    func testPinProtectionBlocksBackAndRequiresPINForSettings() throws {
        let app = try launchConfiguredAppAtModeSelection(
            shouldResetState: true,
            extraLaunchEnvironment: SlideshowControlBarNavigationTestConfiguration.extendedAutoHideLaunchEnvironment
        )
        startRandomPlaybackFromModeSelection(app: app)

        openSettingsFromSlideshow(app: app)
        openAccessProtectionSectionIfNeeded(app: app)

        tapSettingsPinInput(app: app, id: "settings.pin.input.enable")
        inputPinOnSheet(app: app, pin: "123456")
        tapSettingsPinInput(app: app, id: "settings.pin.input.enableConfirm")
        inputPinOnSheet(app: app, pin: "123456")

        let enableButton = app.buttons["settings.pin.enable.button"]
        XCTAssertTrue(
            enableButton.waitForFailureEvidence(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        XCTAssertTrue(enableButton.isEnabled)
        enableButton.tapForFailureEvidence()

        returnToSlideshowFromSettings(app: app)

        XCTAssertFalse(
            app.buttons["global.back.button"].exists, "With PIN on, the playback page should still show no back button")

        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            app.waitForSlideshowControlBarButton(
                identifier: "slideshow.control.settings.button",
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds))
        settingsButton.tapForFailureEvidence()

        let closePinEntry = app.buttons["pinEntry.close.button"]
        XCTAssertTrue(
            closePinEntry.waitForFailureEvidence(
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds),
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
            pinSheetCloseButton.waitForFailureEvidence(
                timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds),
            "After entering the correct PIN, the PIN sheet should close")
    }

    // Only checks that the config and PIN survive a relaunch; returning from settings is not mixed in.
    @MainActor
    func testPinAndServerConfigPersistAfterRelaunch() throws {
        let app = try launchConfiguredAppAtModeSelection(
            shouldResetState: true,
            extraLaunchEnvironment: SlideshowControlBarNavigationTestConfiguration.extendedAutoHideLaunchEnvironment
        )
        startRandomPlaybackFromModeSelection(app: app)

        openSettingsFromSlideshow(app: app)
        openAccessProtectionSectionIfNeeded(app: app)

        tapSettingsPinInput(app: app, id: "settings.pin.input.enable")
        inputPinOnSheet(app: app, pin: "123456")
        tapSettingsPinInput(app: app, id: "settings.pin.input.enableConfirm")
        inputPinOnSheet(app: app, pin: "123456")
        app.buttons["settings.pin.enable.button"].tapForFailureEvidence()

        XCTAssertTrue(
            app.buttons["settings.pin.disable.button"].waitForFailureEvidence(
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "After enabling PIN, settings should switch to the enabled state"
        )

        app.terminateForFailureEvidence()
        app.launchEnvironment.removeAll()
        app.launchForFailureEvidence()

        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForPublicElement(
                "firstboot.serverURL.field",
                timeout: immichSlidesUITestsWaitTiming.readbackTimeoutSeconds),
            "After relaunch, the app should not return to first-boot setup")
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForPublicElement(
                "slideshow.control.settings.button",
                timeout: immichSlidesUITestsWaitTiming.connectionTimeoutSeconds),
            "After relaunch, the app should go straight back to playback")
        XCTAssertFalse(
            app.buttons["global.back.button"].exists,
            "After relaunch with a persisted PIN, the playback page should still show no back button")

        app.buttons["slideshow.control.settings.button"].tapForFailureEvidence()
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForFailureEvidence(
                timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "After relaunch with a persisted PIN, opening settings should still require verification")
        attachScreenshot(app: app, name: "Desktop-relaunch-pin-gate")
    }
}

extension XCUIElement {
    func immichSlidesUITestsClearAndType(text: String) {
        guard let existing = self.value as? String else {
            self.typeForFailureEvidence(text)
            return
        }

        self.tapForFailureEvidence()
        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)
        self.typeForFailureEvidence(deleteString)
        self.typeForFailureEvidence(text)
    }
}
#endif
