import Foundation
import XCTest

#if os(iOS)
extension FilterSummaryIOSVisualUITests {
    @MainActor
    func testIOSSettingsRootLocalizationEnglishScreenshot() throws {

        let app = try launchIntoSlideShow(
            colorScheme: "dark",
            shouldForceEnglishLocalization: true
        )

        openSettingsFromSlideShow(app: app)
        assertEnglishSettingsRootLabels(app: app)

        attachScreenshot(
            app: app,
            name: "ios-settings-root-localization-english-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSettingsServerSectionScreenshotLight() throws {

        let app = try launchIntoSlideShow(colorScheme: "light")

        openSettingsFromSlideShow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.server")

        let serverURLField = app.textFields["firstboot.serverURL.field"]
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        let testButton = app.buttons["firstboot.testConnection.button"]
        let saveButton = app.buttons["firstboot.saveConfig.button"]

        XCTAssertTrue(
            serverURLField.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Server settings page should show the server URL field")
        XCTAssertTrue(
            apiKeyField.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Server settings page should show the API Key field")
        XCTAssertTrue(
            testButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Server settings page should show the 'Test Connection' button")
        XCTAssertTrue(
            saveButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Server settings page should show the 'Save Settings' button")

        attachScreenshot(
            app: app,
            name: "ios-settings-server-section-light-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSettingsServerSectionScreenshotDark() throws {

        let app = try launchIntoSlideShow(colorScheme: "dark")

        openSettingsFromSlideShow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.server")

        let serverURLField = app.textFields["firstboot.serverURL.field"]
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        let testButton = app.buttons["firstboot.testConnection.button"]
        let saveButton = app.buttons["firstboot.saveConfig.button"]

        XCTAssertTrue(
            serverURLField.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Server settings page should show the server URL field")
        XCTAssertTrue(
            apiKeyField.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Server settings page should show the API Key field")
        XCTAssertTrue(
            testButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Server settings page should show the 'Test Connection' button")
        XCTAssertTrue(
            saveButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Server settings page should show the 'Save Settings' button")

        attachScreenshot(
            app: app,
            name: "ios-settings-server-section-dark-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSettingsPlaybackBlockedAlertScreenshotDarkAccessibility() throws {

        let app = try launchIntoRandomSlideShow(
            colorScheme: "dark",
            dynamicTypeSize: "accessibility5"
        )

        openSettingsFromSlideShow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.playback")

        let playbackModePicker = app.segmentedControls["settings.playback.mode.picker"]
        XCTAssertTrue(
            playbackModePicker.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Playback settings page should show the default playback mode segmented picker")

        let filteredModeSegment = playbackModePicker.buttons.element(boundBy: 1)
        XCTAssertTrue(
            filteredModeSegment.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "Playback settings page should show the 'Filtered Playback' option")
        tapElement(filteredModeSegment)

        XCTAssertNotNil(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            waitForAnyElement(
                app: app,
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                labels: ["无法切换到筛选播放", "Can't Switch to Filtered Playback"],
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "With empty filters, a blocking alert should appear directly on the current detail page"
        )

        attachScreenshot(
            app: app,
            name: "ios-settings-playback-alert-dark-accessibility-\(currentDeviceTag())"
        )
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        tapFirstExistingButton(app: app, labels: ["取消", "Cancel"])
    }

    @MainActor
    func testIOSSettingsServerErrorAlertScreenshotDarkAccessibility() throws {

        let app = try launchIntoRandomSlideShow(
            colorScheme: "dark",
            dynamicTypeSize: "accessibility5"
        )

        openSettingsFromSlideShow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.server")

        let serverURLField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverURLField.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Server settings page should show the server URL field")
        tapElement(serverURLField)
        serverURLField.filterSummaryIOSVisualUITestsClearAndType(text: "foo://invalid-host")

        let testConnectionButton = app.buttons["firstboot.testConnection.button"]
        XCTAssertTrue(
            testConnectionButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Server settings page should show the test connection button")
        dismissKeyboardIfNeeded(app: app)
        tapElement(testConnectionButton)

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let serverErrorAlert = waitForAnyElement(
            app: app,
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            labels: ["连接测试失败", "Connection test failed", "Connection Test Failed"],
            timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds
        )

        if serverErrorAlert == nil {

            let testingStatus = app.staticTexts["settings.server.status.testing"]
            let idleStatus = app.staticTexts["settings.server.status.message"]
            let observedStatus: String

            if testingStatus.exists {
                observedStatus = "testing:\(testingStatus.label)"
            } else if idleStatus.exists {
                observedStatus = "message:\(idleStatus.label)"
            } else {
                observedStatus = "none"
            }

            attachScreenshot(
                app: app,
                name: "ios-settings-server-alert-missing-dark-accessibility-\(currentDeviceTag())"
            )
            XCTFail(
                "When the connection fails, an error alert should appear directly on the current server detail page; current status: \(observedStatus)"
            )
        }

        attachScreenshot(
            app: app,
            name: "ios-settings-server-alert-dark-accessibility-\(currentDeviceTag())"
        )
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        tapFirstExistingButton(app: app, labels: ["确定", "OK"])
    }

    @MainActor
    func testIOSSettingsCacheClearAlertScreenshotDarkAccessibility() throws {

        let app = try launchIntoSlideShow(
            colorScheme: "dark",
            dynamicTypeSize: "accessibility5"
        )

        openSettingsFromSlideShow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.cache")

        let clearDiskButton = app.buttons["settings.cache.clearDisk.button"]
        XCTAssertTrue(
            clearDiskButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Cache management page should show the clear disk cache button")
        tapElement(clearDiskButton)

        XCTAssertNotNil(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            waitForAnyElement(
                app: app,
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                labels: ["确认清理磁盘缓存", "Confirm Disk Cache Clear"],
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "After tapping clear disk cache, a confirmation alert should appear directly on the current cache management detail page"
        )

        attachScreenshot(
            app: app,
            name: "ios-settings-cache-alert-dark-accessibility-\(currentDeviceTag())"
        )
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        tapFirstExistingButton(app: app, labels: ["取消", "Cancel"])
    }

    @MainActor
    func testAlertLookupRejectsUnrelatedAlertAndAcceptsMatchingText() throws {
        let app = try launchIntoSlideShow(colorScheme: "dark")
        openSettingsFromSlideShow(app: app)
        openSettingsSection(app: app, sectionID: "settings.item.cache")

        let clearDiskButton = app.buttons["settings.cache.clearDisk.button"]
        XCTAssertTrue(
            clearDiskButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        tapElement(clearDiskButton)
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        XCTAssertTrue(
            app.alerts.firstMatch.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        XCTAssertNil(waitForAnyElement(app: app, labels: ["unrelated alert sentinel"], timeout: 0.2))
        XCTAssertNotNil(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            waitForAnyElement(
                app: app,
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                labels: ["确认清理磁盘缓存", "Confirm Disk Cache Clear"],
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.readbackTimeoutSeconds
            )
        )
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        tapFirstExistingButton(app: app, labels: ["取消", "Cancel"])
    }

    @MainActor
    func testIOSSettingsAboutPageScreenshotDark() throws {

        let app = try launchIntoSlideShow(colorScheme: "dark")

        openSettingsFromSlideShow(app: app)
        openSettingsAboutPage(app: app)
        assertSettingsAboutPageLoaded(app: app)

        attachScreenshot(
            app: app,
            name: "ios-settings-about-page-dark-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSettingsAboutPageScreenshotLight() throws {
        let app = try launchIntoSlideShow(colorScheme: "light")

        openSettingsFromSlideShow(app: app)
        openSettingsAboutPage(app: app)
        assertSettingsAboutPageLoaded(app: app)

        attachScreenshot(
            app: app,
            name: "ios-settings-about-page-light-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSettingsAboutPageScreenshotAccessibility() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "dark",
            dynamicTypeSize: "accessibility5"
        )

        openSettingsFromSlideShow(app: app)
        openSettingsAboutPage(app: app)
        assertSettingsAboutPageLoaded(app: app)

        attachScreenshot(
            app: app,
            name: "ios-settings-about-page-accessibility-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSettingsAboutPageScreenshotLandscape() throws {
        defer {
            XCUIDevice.shared.orientation = .portrait
        }

        let app = try launchIntoSlideShow(colorScheme: "light")

        openSettingsFromSlideShow(app: app)
        openSettingsAboutPage(app: app)
        assertSettingsAboutPageLoaded(app: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            // ui-label-lookup: This is a translated About copy assertion.
            anyElement(app: app, withLabel: "应用名称").waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "In landscape, the About page should still show the app name"
        )
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.transitionPollSeconds))

        attachScreenshot(
            app: app,
            name: "ios-settings-about-page-landscape-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSettingsAboutPageEnglishLocalizationScreenshotLight() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "light",
            shouldForceEnglishLocalization: true
        )

        openSettingsFromSlideShow(app: app)
        openSettingsAboutPage(app: app)
        assertSettingsAboutPageLoaded(app: app, shouldForceEnglishLocalization: true)

        attachScreenshot(
            app: app,
            name: "ios-settings-about-page-english-light-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSettingsOpenSourceLicensesPageScreenshotLight() throws {

        let app = try launchIntoSlideShow(colorScheme: "light")

        openSettingsFromSlideShow(app: app)
        openSettingsAboutPage(app: app)
        assertSettingsAboutPageLoaded(app: app)

        let openSourceLink = app.descendants(matching: .any)
            .matching(identifier: "settings.about.opensource.link")
            .firstMatch
        XCTAssertTrue(
            openSourceLink.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the 'Open Source Licenses' entry")

        attachScreenshot(
            app: app,
            name: "ios-settings-about-open-source-entry-light-\(currentDeviceTag())"
        )
        openSourceLink.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "settings.about.opensource.page")
                .firstMatch
                .waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.shortInteractionTimeoutSeconds),
            "Tapping should open the open source licenses detail page"
        )
        XCTAssertTrue(
            anyElement(app: app, withLabel: "SDWebImage").waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Open source licenses page should show the SDWebImage card"
        )
        XCTAssertTrue(
            anyElement(app: app, withLabel: "SDWebImageSwiftUI").waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Open source licenses page should show the SDWebImageSwiftUI card"
        )

        attachScreenshot(
            app: app,
            name: "ios-settings-open-source-page-light-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSettingsOpenSourceLicensesCanReopenAfterBackOnPad() throws {

        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom != .pad,
            "This regression test only covers reopening the open source licenses entry in iPad settings"
        )

        let app = try launchIntoSlideShow(colorScheme: "light")

        openSettingsFromSlideShow(app: app)
        openSettingsAboutPage(app: app)
        assertSettingsAboutPageLoaded(app: app)

        openOpenSourceLicensesFromAbout(app: app)
        returnToSettingsAboutFromOpenSourceLicenses(app: app)
        openOpenSourceLicensesFromAbout(app: app)

        attachScreenshot(
            app: app,
            name: "ios-settings-open-source-reopen-after-back-light-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSettingsOpenSourceLicensesKeepsPadSidebarResponsive() throws {

        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom != .pad,
            "This regression test only covers the split-view navigation in iPad settings"
        )

        let app = try launchIntoSlideShow(colorScheme: "light")

        openSettingsFromSlideShow(app: app)
        openSettingsAboutPage(app: app)
        assertSettingsAboutPageLoaded(app: app)

        let openSourceLink = app.descendants(matching: .any)
            .matching(identifier: "settings.about.opensource.link")
            .firstMatch
        XCTAssertTrue(
            openSourceLink.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the 'Open Source Licenses' entry")
        tapElement(openSourceLink)

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "settings.about.opensource.page")
                .firstMatch
                .waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.shortInteractionTimeoutSeconds),
            "Tapping should open the open source licenses detail page"
        )

        openSettingsSection(app: app, sectionID: "settings.item.server")

        XCTAssertTrue(
            app.textFields["firstboot.serverURL.field"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After tapping 'Server' in the left sidebar from the open source licenses page, the right detail pane should switch to server settings immediately"
        )

        attachScreenshot(
            app: app,
            name: "ios-settings-open-source-sidebar-recovery-light-\(currentDeviceTag())"
        )
    }
}
extension FilterSummaryIOSVisualUITests {

}
#endif
