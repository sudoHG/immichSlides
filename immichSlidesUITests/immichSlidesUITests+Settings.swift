import XCTest

#if os(iOS)
extension immichSlidesUITests {
    // Playback settings constraint: with an empty filter, switching to filtered playback is blocked with an alert.
    @MainActor
    func testPlaybackSettingsBlocksFilteredModeWhenSelectionEmpty() throws {
        let app = try launchConfiguredAppAtModeSelection(shouldResetState: true)
        startRandomPlaybackFromModeSelection(app: app)

        openSettingsFromSlideshow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.playback")

        let playbackModePicker = app.segmentedControls["settings.playback.mode.picker"]
        XCTAssertTrue(
            playbackModePicker.waitForExistence(timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds))
        let filteredModeSegment = playbackModePicker.buttons.element(boundBy: 1)
        XCTAssertTrue(
            filteredModeSegment.waitForExistence(timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds))
        filteredModeSegment.tap()

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let blockedAlertTitle = findFirstExistingStaticText(
            in: app,
            labels: ["无法切换到筛选播放", "Can't Switch to Filtered Playback"],
            timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds
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
            displayModePicker.waitForExistence(timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "Playback settings should show the display mode segmented control")

        let smartFillSegment = displayModePicker.buttons["settings.playback.displayMode.smartFill.option"]
        let singlePhotoSegment = displayModePicker.buttons["settings.playback.displayMode.singlePhoto.option"]
        XCTAssertTrue(
            smartFillSegment.waitForExistence(timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds),
            "Display mode should offer Smart Fill")
        XCTAssertTrue(
            singlePhotoSegment.waitForExistence(timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds),
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
        XCTAssertTrue(serverField.waitForExistence(timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds))
        serverField.tap()
        serverField.immichSlidesUITestsClearAndType(text: "foo://invalid-host")

        let testConnectionButton = app.buttons["firstboot.testConnection.button"]
        XCTAssertTrue(
            testConnectionButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds))
        dismissKeyboardIfNeeded(app: app)
        tapElement(testConnectionButton)

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let errorAlertTitle = findFirstExistingStaticText(
            in: app,
            labels: ["连接测试失败", "Connection test failed", "Connection Test Failed"],
            timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds
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
            serverField.waitForExistence(timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "Server settings should show the server address field")

        let helpButton = app.buttons["server.apiKey.help.button"]
        XCTAssertTrue(
            helpButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "Server settings should show the help entry next to the API Key title")
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
        attachScreenshot(app: app, name: "ios-settings-server-api-key-help-sheet")

        let closeButton = app.buttons["server.apiKey.help.close.button"]
        XCTAssertTrue(
            closeButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds),
            "Help sheet should provide a tappable close button")
        tapElement(closeButton)

        XCTAssertFalse(
            sheet.waitForExistence(timeout: immichSlidesUITestsWaitTiming.briefElementTimeoutSeconds),
            "The help sheet should be gone after closing it")
        XCTAssertTrue(
            serverField.waitForExistence(timeout: immichSlidesUITestsWaitTiming.shortInteractionTimeoutSeconds),
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
        XCTAssertTrue(
            clearDiskButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds))
        clearDiskButton.tap()

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let confirmAlertTitle = findFirstExistingStaticText(
            in: app,
            labels: ["确认清理磁盘缓存", "Confirm Disk Cache Clear"],
            timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds
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
                timeout: immichSlidesUITestsWaitTiming.navigationTimeoutSeconds))

        app.terminate()
        // Clear the server injection when verifying reset, otherwise it is written back after the wipe.
        app.launchEnvironment.removeAll()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launch()

        XCTAssertTrue(
            app.textFields["firstboot.serverURL.field"].waitForExistence(
                timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
        XCTAssertTrue(
            autoPlayToggle.waitForExistence(timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds))
        if isToggleOn(autoPlayToggle) {
            autoPlayToggle.tap()
        }
        XCTAssertTrue(
            waitUntil(timeout: immichSlidesUITestsWaitTiming.stateChangeTimeoutSeconds) {
                !self.isToggleOn(autoPlayToggle)
            },
            "Auto-play toggle should be off")

        returnToSlideshowFromSettings(app: app)

        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(
            waitUntil(timeout: immichSlidesUITestsWaitTiming.stateChangeTimeoutSeconds) {
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
        XCTAssertTrue(
            clearDiskButton.waitForExistence(timeout: immichSlidesUITestsWaitTiming.settingsChangeTimeoutSeconds))
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
            waitUntil(timeout: immichSlidesUITestsWaitTiming.elementAppearanceTimeoutSeconds) {
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
            successStatus.waitForExistence(timeout: immichSlidesUITestsWaitTiming.navigationTimeoutSeconds),
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
extension immichSlidesUITests {

}
#endif
