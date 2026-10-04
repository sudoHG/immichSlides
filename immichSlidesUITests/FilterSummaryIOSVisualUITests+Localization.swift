import Foundation
import XCTest

#if os(iOS)
extension FilterSummaryIOSVisualUITests {
    @MainActor
    func testIOSTraditionalChineseHKAcceptanceOnboardingScreenshots() throws {
        try runIOSLocalizedOnboardingAcceptance(locale: .hongKong)
    }

    @MainActor
    func testIOSTraditionalChineseHKAcceptanceFilterEditorScreenshot() throws {
        try runIOSLocalizedFilterEditorAcceptance(locale: .hongKong)
    }

    @MainActor
    func testIOSTraditionalChineseHKAcceptanceAlbumAndPersonScreenshots() throws {
        try runIOSLocalizedAlbumAndPersonAcceptance(locale: .hongKong)
    }

    @MainActor
    func testIOSTraditionalChineseHKAcceptanceSettingsPrimaryScreenshots() throws {
        try runIOSLocalizedSettingsPrimaryAcceptance(locale: .hongKong)
    }

    @MainActor
    func testIOSTraditionalChineseHKAcceptanceAboutScreenshots() throws {
        try runIOSLocalizedAboutAcceptance(locale: .hongKong)
    }

    @MainActor
    func testIOSTraditionalChineseTWAcceptanceOnboardingScreenshots() throws {
        try runIOSLocalizedOnboardingAcceptance(locale: .taiwan)
    }

    @MainActor
    func testIOSTraditionalChineseTWAcceptanceFilterEditorScreenshot() throws {
        try runIOSLocalizedFilterEditorAcceptance(locale: .taiwan)
    }

    @MainActor
    func testIOSTraditionalChineseTWAcceptanceAlbumAndPersonScreenshots() throws {
        try runIOSLocalizedAlbumAndPersonAcceptance(locale: .taiwan)
    }

    @MainActor
    func testIOSTraditionalChineseTWAcceptanceSettingsPrimaryScreenshots() throws {
        try runIOSLocalizedSettingsPrimaryAcceptance(locale: .taiwan)
    }

    @MainActor
    func testIOSTraditionalChineseTWAcceptanceAboutScreenshots() throws {
        try runIOSLocalizedAboutAcceptance(locale: .taiwan)
    }

    @MainActor
    func testIOSJapaneseAcceptanceOnboardingScreenshots() throws {
        try runIOSLocalizedOnboardingAcceptance(locale: .japanese)
    }

    @MainActor
    func testIOSJapaneseAcceptanceFilterEditorScreenshot() throws {
        try runIOSLocalizedFilterEditorAcceptance(locale: .japanese)
    }

    @MainActor
    func testIOSJapaneseAcceptanceAlbumAndPersonScreenshots() throws {
        try runIOSLocalizedAlbumAndPersonAcceptance(locale: .japanese)
    }

    @MainActor
    func testIOSJapaneseAcceptanceSettingsPrimaryScreenshots() throws {
        try runIOSLocalizedSettingsPrimaryAcceptance(locale: .japanese)
    }

    @MainActor
    func testIOSJapaneseAcceptanceAboutScreenshots() throws {
        try runIOSLocalizedAboutAcceptance(locale: .japanese)
    }

    @MainActor
    func testIOSSpanishAcceptanceOnboardingScreenshots() throws {
        try runIOSLocalizedOnboardingAcceptance(locale: .spanish)
    }

    @MainActor
    func testIOSSpanishAcceptanceFilterEditorScreenshot() throws {
        try runIOSLocalizedFilterEditorAcceptance(locale: .spanish)
    }

    @MainActor
    func testIOSSpanishAcceptanceAlbumAndPersonScreenshots() throws {
        try runIOSLocalizedAlbumAndPersonAcceptance(locale: .spanish)
    }

    @MainActor
    func testIOSSpanishAcceptanceSettingsPrimaryScreenshots() throws {
        try runIOSLocalizedSettingsPrimaryAcceptance(locale: .spanish)
    }

    @MainActor
    func testIOSSpanishAcceptanceAboutScreenshots() throws {
        try runIOSLocalizedAboutAcceptance(locale: .spanish)
    }

    @MainActor
    func runIOSLocalizedOnboardingAcceptance(locale: LocalizedAcceptanceLocale) throws {
        let firstBootApp = launchIntoOnboardingFirstBoot(
            colorScheme: "light",
            acceptanceLocale: locale
        )
        assertOnboardingHeader(
            app: firstBootApp,
            expectedWizardTitle: locale.wizardTitle,
            expectedPageTitle: locale.firstBootTitle,
            pageTitleIdentifier: "firstboot.page.title"
        )
        attachScreenshot(
            app: firstBootApp,
            name: "\(locale.screenshotPrefix)-ios-firstboot-\(currentDeviceTag())"
        )
        firstBootApp.terminate()

        let modeApp = try launchIntoOnboardingModeSelection(
            colorScheme: "light",
            acceptanceLocale: locale
        )
        assertOnboardingHeader(
            app: modeApp,
            expectedWizardTitle: locale.wizardTitle,
            expectedPageTitle: locale.modeSelectionTitle,
            pageTitleIdentifier: "mode.page.title"
        )
        attachScreenshot(
            app: modeApp,
            name: "\(locale.screenshotPrefix)-ios-mode-selection-\(currentDeviceTag())"
        )
        modeApp.terminate()

        let filterSummaryApp = try launchIntoOnboardingFilterSummary(
            colorScheme: "light",
            acceptanceLocale: locale
        )
        assertOnboardingHeader(
            app: filterSummaryApp,
            expectedWizardTitle: locale.wizardTitle,
            expectedPageTitle: locale.filterSummaryTitle,
            pageTitleIdentifier: "filterSummary.page.title"
        )
        attachScreenshot(
            app: filterSummaryApp,
            name: "\(locale.screenshotPrefix)-ios-filter-summary-\(currentDeviceTag())"
        )
    }

    @MainActor
    func runIOSLocalizedFilterEditorAcceptance(locale: LocalizedAcceptanceLocale) throws {
        let filterEditorApp = try launchIntoFilterEditor(
            colorScheme: "light",
            shouldPrepareFilterEditorVisuals: false,
            acceptanceLocale: locale
        )
        XCTAssertTrue(
            waitForLocalizedElement(
                filterEditorApp,
                identifier: "filterEditor.page.title",
                label: locale.filterEditorTitle,
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "In the localized environment, the filter editor should show text for the target locale"
        )
        attachScreenshot(
            app: filterEditorApp,
            name: "\(locale.screenshotPrefix)-ios-filter-editor-\(currentDeviceTag())"
        )
    }

    @MainActor
    func runIOSLocalizedAlbumAndPersonAcceptance(locale: LocalizedAcceptanceLocale) throws {
        let albumApp = try launchIntoAlbumFilterPage(
            colorScheme: "light",
            dynamicTypeSize: nil,
            acceptanceLocale: locale
        )
        attachScreenshot(
            app: albumApp,
            name: "\(locale.screenshotPrefix)-ios-album-filter-\(currentDeviceTag())"
        )
        albumApp.terminate()

        let personApp = try launchIntoPersonFilterPage(
            colorScheme: "light",
            dynamicTypeSize: nil,
            acceptanceLocale: locale
        )
        attachScreenshot(
            app: personApp,
            name: "\(locale.screenshotPrefix)-ios-person-filter-\(currentDeviceTag())"
        )
    }

    @MainActor
    func runIOSLocalizedSettingsPrimaryAcceptance(locale: LocalizedAcceptanceLocale) throws {
        let settingsApp = try launchIntoSlideShow(
            colorScheme: "light",
            acceptanceLocale: locale
        )
        attachScreenshot(
            app: settingsApp,
            name: "\(locale.screenshotPrefix)-ios-slideshow-\(currentDeviceTag())"
        )

        openSettingsFromSlideShow(app: settingsApp)
        XCTAssertTrue(
            waitForLocalizedElement(
                settingsApp,
                identifier: "settings.item.playback",
                label: locale.playbackSettingsTitle,
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "In the localized environment, the settings root should show the playback settings entry"
        )
        attachScreenshot(
            app: settingsApp,
            name: "\(locale.screenshotPrefix)-ios-settings-root-\(currentDeviceTag())"
        )

        openSettingsSection(
            app: settingsApp,
            sectionID: "settings.item.playback"
        )
        XCTAssertTrue(
            settingsApp.buttons["settings.playback.filterConfig.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Localized playback settings page should show the edit filters entry"
        )
        attachScreenshot(
            app: settingsApp,
            name: "\(locale.screenshotPrefix)-ios-settings-playback-\(currentDeviceTag())"
        )

        openSettingsSection(
            app: settingsApp,
            sectionID: "settings.item.accessProtection"
        )
        XCTAssertTrue(
            anyElement(app: settingsApp, withLabel: locale.accessProtectionDisabledTitle)
                .waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Localized access protection page should show the disabled status"
        )
        attachScreenshot(
            app: settingsApp,
            name: "\(locale.screenshotPrefix)-ios-settings-access-protection-\(currentDeviceTag())"
        )

        openSettingsSection(
            app: settingsApp,
            sectionID: "settings.item.server"
        )
        XCTAssertTrue(
            settingsApp.textFields["firstboot.serverURL.field"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Localized server settings page should show the server URL field"
        )
        attachScreenshot(
            app: settingsApp,
            name: "\(locale.screenshotPrefix)-ios-settings-server-\(currentDeviceTag())"
        )

        openSettingsSection(
            app: settingsApp,
            sectionID: "settings.item.cache"
        )
        XCTAssertTrue(
            settingsApp.buttons["settings.cache.clearDisk.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Localized cache management page should show the clear disk cache button"
        )
        attachScreenshot(
            app: settingsApp,
            name: "\(locale.screenshotPrefix)-ios-settings-cache-\(currentDeviceTag())"
        )
    }

    @MainActor
    func runIOSLocalizedAboutAcceptance(locale: LocalizedAcceptanceLocale) throws {
        let aboutApp = try launchIntoSlideShow(
            colorScheme: "light",
            acceptanceLocale: locale
        )
        openSettingsFromSlideShow(app: aboutApp)

        openSettingsSection(
            app: aboutApp,
            sectionID: "settings.item.about"
        )
        XCTAssertTrue(
            anyElement(app: aboutApp, withLabel: locale.appInfoTitle).waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Localized About page should show the App info section"
        )
        XCTAssertTrue(
            anyElement(app: aboutApp, withLabel: locale.privacyPolicyTitle).waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Localized About page should show the privacy policy entry text for the target locale"
        )
        attachScreenshot(
            app: aboutApp,
            name: "\(locale.screenshotPrefix)-ios-settings-about-\(currentDeviceTag())"
        )

        openOpenSourceLicensesFromAbout(app: aboutApp)
        XCTAssertTrue(
            anyElement(app: aboutApp, withLabel: locale.openSourceTitle).waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Localized open source licenses page should show text for the target locale"
        )
        attachScreenshot(
            app: aboutApp,
            name: "\(locale.screenshotPrefix)-ios-settings-open-source-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSEnglishAcceptanceFirstBootScreenshot() throws {

        let app = launchIntoOnboardingFirstBoot(
            colorScheme: "light",
            shouldForceEnglishLocalization: true
        )
        assertOnboardingHeader(
            app: app,
            expectedWizardTitle: "Setup Wizard",
            expectedPageTitle: "Connect to Immich Server",
            pageTitleIdentifier: "firstboot.page.title"
        )
        attachScreenshot(
            app: app,
            name: "english-ios-firstboot-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSEnglishAcceptanceModeSelectionScreenshot() throws {
        let app = try launchIntoOnboardingModeSelection(
            colorScheme: "light",
            shouldForceEnglishLocalization: true
        )
        assertOnboardingHeader(
            app: app,
            expectedWizardTitle: "Setup Wizard",
            expectedPageTitle: "Choose Playback Mode",
            pageTitleIdentifier: "mode.page.title"
        )
        attachScreenshot(
            app: app,
            name: "english-ios-mode-selection-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSEnglishAcceptanceFilterSummaryScreenshot() throws {
        let app = try launchIntoOnboardingFilterSummary(
            colorScheme: "light",
            shouldForceEnglishLocalization: true
        )
        assertOnboardingHeader(
            app: app,
            expectedWizardTitle: "Setup Wizard",
            expectedPageTitle: "Set Photo Range",
            pageTitleIdentifier: "filterSummary.page.title"
        )
        attachScreenshot(
            app: app,
            name: "english-ios-filter-summary-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSEnglishAcceptanceFilterEditorScreenshot() throws {

        let app = try launchIntoFilterEditor(
            colorScheme: "light",
            shouldPrepareFilterEditorVisuals: false,
            shouldForceEnglishLocalization: true
        )
        XCTAssertTrue(
            anyElement(app: app, withLabel: "Edit Filters").waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "In English, the filter editor title should be Edit Filters"
        )
        attachScreenshot(
            app: app,
            name: "english-ios-filter-editor-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSEnglishAcceptanceAlbumFilterScreenshot() throws {
        let app = try launchIntoAlbumFilterPage(
            colorScheme: "light",
            dynamicTypeSize: nil,
            shouldForceEnglishLocalization: true
        )
        attachScreenshot(
            app: app,
            name: "english-ios-album-filter-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSEnglishAcceptancePersonFilterScreenshot() throws {
        let app = try launchIntoPersonFilterPage(
            colorScheme: "light",
            dynamicTypeSize: nil,
            shouldForceEnglishLocalization: true
        )
        attachScreenshot(
            app: app,
            name: "english-ios-person-filter-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSEnglishAcceptanceSlideshowAndSettingsRootScreenshots() throws {

        let app = try launchIntoSlideShow(
            colorScheme: "light",
            shouldForceEnglishLocalization: true
        )

        attachScreenshot(
            app: app,
            name: "english-ios-slideshow-\(currentDeviceTag())"
        )

        openSettingsFromSlideShow(app: app)
        assertEnglishSettingsRootLabels(app: app)
        attachScreenshot(
            app: app,
            name: "english-ios-settings-root-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSEnglishAcceptanceSettingsPlaybackScreenshot() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "light",
            shouldForceEnglishLocalization: true
        )

        openSettingsFromSlideShow(app: app)

        openSettingsSection(app: app, sectionID: "settings.item.playback")
        XCTAssertTrue(
            anyElement(app: app, withLabel: "Autoplay").waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "English playback settings page should show Autoplay"
        )
        attachScreenshot(
            app: app,
            name: "english-ios-settings-playback-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSEnglishAcceptanceSettingsServerScreenshot() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "light",
            shouldForceEnglishLocalization: true
        )

        openSettingsFromSlideShow(app: app)

        openSettingsSection(app: app, sectionID: "settings.item.server")
        XCTAssertTrue(
            app.textFields["firstboot.serverURL.field"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "English server settings page should show the server URL field"
        )
        attachScreenshot(
            app: app,
            name: "english-ios-settings-server-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSEnglishAcceptanceSettingsCacheScreenshot() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "light",
            shouldForceEnglishLocalization: true
        )

        openSettingsFromSlideShow(app: app)

        openSettingsSection(app: app, sectionID: "settings.item.cache")
        XCTAssertTrue(
            app.buttons["settings.cache.clearDisk.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "English cache management page should show the clear disk cache button"
        )
        attachScreenshot(
            app: app,
            name: "english-ios-settings-cache-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSEnglishAcceptanceSettingsAboutOpenSourceScreenshots() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "light",
            shouldForceEnglishLocalization: true
        )

        openSettingsFromSlideShow(app: app)

        openSettingsAboutPage(app: app)
        assertSettingsAboutPageLoaded(app: app, shouldForceEnglishLocalization: true)
        attachScreenshot(
            app: app,
            name: "english-ios-settings-about-\(currentDeviceTag())"
        )

        openOpenSourceLicensesFromAbout(app: app)
        XCTAssertTrue(
            anyElement(app: app, withLabel: "Open Source Licenses").waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "English open source licenses page should show the Open Source Licenses title"
        )
        attachScreenshot(
            app: app,
            name: "english-ios-settings-open-source-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSAlbumCardAccessibilityFramesIgnoreCoverShape() throws {
        let app = try launchIntoAlbumFilterFromSummary()
        try AlbumCardSnapshot.assertFramesIgnoreCoverShape(in: app)
    }

    @MainActor
    func testIOSAlbumCardTapsIgnoreCoverShape() throws {
        let app = try launchIntoAlbumFilterFromSummary()
        try AlbumCardSnapshot.assertTapsIgnoreCoverShape(in: app)
    }
}
extension FilterSummaryIOSVisualUITests {

}
#endif
