//
//  FilterSummaryTVOSVisualUITests.swift
//  immichSlidesUITests
//
//  tvOS UI acceptance: onboarding, FilterSummary, playback, settings, PIN, privacy, licenses, and localization
//

import XCTest

private enum CapsuleGeometry {
    static let maximumLeadingPositionPoints: CGFloat = 170
    static let maximumTopPositionPoints: CGFloat = 90
}

private enum AccessProtection {
    static let pinDigitCount: Int = 6
}

private enum SettingsNavigation {
    static let playbackSteps: Int = 0
    static let accessProtectionSteps: Int = 1
    static let serverSteps: Int = 2
    static let cacheSteps: Int = 3
    static let aboutSteps: Int = 4
}

private enum WaitTiming {
    static let albumFocusSettleSeconds: TimeInterval = 0.18
    static let briefElementTimeoutSeconds: TimeInterval = 1
    static let connectionTimeoutSeconds: TimeInterval = 15
    static let controlAppearanceTimeoutSeconds: TimeInterval = 8
    static let elementAppearanceTimeoutSeconds: TimeInterval = 5
    static let focusPollSeconds: TimeInterval = 0.08
    static let focusSettleSeconds: TimeInterval = 0.16
    static let navigationFocusSettleSeconds: TimeInterval = 0.22
    static let navigationTimeoutSeconds: TimeInterval = 10
    static let pollIntervalSeconds: TimeInterval = 0.1
    static let readbackTimeoutSeconds: TimeInterval = 2
    static let remotePressSettleSeconds: TimeInterval = 0.12
    static let screenSettleSeconds: TimeInterval = 0.8
    static let screenTransitionTimeoutSeconds: TimeInterval = 12
    static let selectionPollSeconds: TimeInterval = 0.25
    static let settingsChangeTimeoutSeconds: TimeInterval = 6
    static let shortFocusSettleSeconds: TimeInterval = 0.15
    static let shortInteractionTimeoutSeconds: TimeInterval = 3
    static let snapshotPollSeconds: TimeInterval = 0.5
    static let stateChangeTimeoutSeconds: TimeInterval = 4
    static let transitionPollSeconds: TimeInterval = 0.4
}

#if os(tvOS)
final class FilterSummaryTVOSVisualUITests: XCTestCase {

    struct LocalizedAcceptanceLocale {
        let screenshotPrefix: String
        let languageCode: String
        let localeIdentifier: String
        let modeSelectionTitle: String
        let filterSummaryTitle: String
        let albumFilterTitle: String
        let personFilterTitle: String
        let playbackSettingsTitle: String
        let accessProtectionDisabledTitle: String
        let accessProtectionEnableRequirement: String
        let appInfoTitle: String
        let openSourceTitle: String

        static let hongKong = LocalizedAcceptanceLocale(
            screenshotPrefix: "zh-Hant-HK",
            languageCode: "zh-Hant-HK",
            localeIdentifier: "zh_HK",
            modeSelectionTitle: "選擇播放方式",
            filterSummaryTitle: "設定相片範圍",
            albumFilterTitle: "篩選相簿",
            personFilterTitle: "篩選人物",
            playbackSettingsTitle: "播放設定",
            accessProtectionDisabledTitle: "存取保護未開啟",
            accessProtectionEnableRequirement: "需要設定並確認 PIN",
            appInfoTitle: "App 資訊",
            openSourceTitle: "開源授權"
        )

        static let taiwan = LocalizedAcceptanceLocale(
            screenshotPrefix: "zh-Hant-TW",
            languageCode: "zh-Hant-TW",
            localeIdentifier: "zh_TW",
            modeSelectionTitle: "選擇播放方式",
            filterSummaryTitle: "設定照片範圍",
            albumFilterTitle: "篩選相簿",
            personFilterTitle: "篩選人物",
            playbackSettingsTitle: "播放設定",
            accessProtectionDisabledTitle: "存取保護未開啟",
            accessProtectionEnableRequirement: "需要設定並確認 PIN",
            appInfoTitle: "App 資訊",
            openSourceTitle: "開源授權"
        )

        static let japanese = LocalizedAcceptanceLocale(
            screenshotPrefix: "ja",
            languageCode: "ja",
            localeIdentifier: "ja_JP",
            modeSelectionTitle: "再生方法を選択",
            filterSummaryTitle: "写真範囲を設定",
            albumFilterTitle: "アルバムをフィルター",
            personFilterTitle: "人物をフィルター",
            playbackSettingsTitle: "再生設定",
            accessProtectionDisabledTitle: "アクセス保護が無効になっています",
            accessProtectionEnableRequirement: "PIN の設定と確認が必要です",
            appInfoTitle: "App 情報",
            openSourceTitle: "オープンソースライセンス"
        )

        static let spanish = LocalizedAcceptanceLocale(
            screenshotPrefix: "es",
            languageCode: "es",
            localeIdentifier: "es_ES",
            modeSelectionTitle: "Elegir modo de reproducción",
            filterSummaryTitle: "Rango de fotos",
            albumFilterTitle: "Filtrar álbumes",
            personFilterTitle: "Filtrar personas",
            playbackSettingsTitle: "Ajustes de reproducción",
            accessProtectionDisabledTitle: "Protección inactiva",
            accessProtectionEnableRequirement: "Se requiere configuración y confirmación de PIN",
            appInfoTitle: "Información de la app",
            openSourceTitle: "Licencias de código abierto"
        )
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try requireTVOSDestination()
    }

    @MainActor
    func testTVOSTraditionalChineseHKAcceptanceCoreScreenshots() throws {
        try runTVOSLocalizedCoreAcceptance(locale: .hongKong)
    }

    @MainActor
    func testTVOSTraditionalChineseHKAcceptancePlaybackSettingsScreenshots() throws {
        try runTVOSLocalizedPlaybackSettingsAcceptance(locale: .hongKong)
    }

    @MainActor
    func testTVOSTraditionalChineseHKAcceptanceAccessProtectionScreenshot() throws {
        try runTVOSLocalizedAccessProtectionAcceptance(locale: .hongKong)
    }

    @MainActor
    func testTVOSTraditionalChineseHKAcceptanceServerAndCacheScreenshots() throws {
        try runTVOSLocalizedServerAndCacheAcceptance(locale: .hongKong)
    }

    @MainActor
    func testTVOSTraditionalChineseHKAcceptanceAboutScreenshots() throws {
        try runTVOSLocalizedAboutAcceptance(locale: .hongKong)
    }

    @MainActor
    func testTVOSTraditionalChineseTWAcceptanceCoreScreenshots() throws {
        try runTVOSLocalizedCoreAcceptance(locale: .taiwan)
    }

    @MainActor
    func testTVOSTraditionalChineseTWAcceptancePlaybackSettingsScreenshots() throws {
        try runTVOSLocalizedPlaybackSettingsAcceptance(locale: .taiwan)
    }

    @MainActor
    func testTVOSTraditionalChineseTWAcceptanceAccessProtectionScreenshot() throws {
        try runTVOSLocalizedAccessProtectionAcceptance(locale: .taiwan)
    }

    @MainActor
    func testTVOSTraditionalChineseTWAcceptanceServerAndCacheScreenshots() throws {
        try runTVOSLocalizedServerAndCacheAcceptance(locale: .taiwan)
    }

    @MainActor
    func testTVOSTraditionalChineseTWAcceptanceAboutScreenshots() throws {
        try runTVOSLocalizedAboutAcceptance(locale: .taiwan)
    }

    @MainActor
    func testTVOSJapaneseAcceptanceCoreScreenshots() throws {
        try runTVOSLocalizedCoreAcceptance(locale: .japanese)
    }

    @MainActor
    func testTVOSJapaneseAcceptancePlaybackSettingsScreenshots() throws {
        try runTVOSLocalizedPlaybackSettingsAcceptance(locale: .japanese)
    }

    @MainActor
    func testTVOSJapaneseAcceptanceAccessProtectionScreenshot() throws {
        try runTVOSLocalizedAccessProtectionAcceptance(locale: .japanese)
    }

    @MainActor
    func testTVOSJapaneseAcceptanceServerAndCacheScreenshots() throws {
        try runTVOSLocalizedServerAndCacheAcceptance(locale: .japanese)
    }

    @MainActor
    func testTVOSJapaneseAcceptanceAboutScreenshots() throws {
        try runTVOSLocalizedAboutAcceptance(locale: .japanese)
    }

    @MainActor
    func testTVOSSpanishAcceptanceCoreScreenshots() throws {
        try runTVOSLocalizedCoreAcceptance(locale: .spanish)
    }

    @MainActor
    func testTVOSSpanishSingularSelectionCountsScreenshot() throws {
        let app = try launchIntoFilterSummary(
            colorScheme: "light",
            languageCode: "es",
            localeIdentifier: "es_ES"
        )
        waitForReadinessMarker(app: app, identifier: "filterSummary.album.ready")
        waitForReadinessMarker(app: app, identifier: "filterSummary.people.ready")

        let singularAlbumSummary = app.descendants(matching: .any).matching(
            // ui-label-lookup: This checks the translated Spanish album summary copy.
            NSPredicate(format: "label CONTAINS %@", "1 álbum ·")
        ).firstMatch
        let singularPeopleSummary = app.descendants(matching: .any).matching(
            // ui-label-lookup: This checks the translated Spanish people summary copy.
            NSPredicate(format: "label CONTAINS %@", "1 persona ·")
        ).firstMatch

        XCTAssertTrue(
            singularAlbumSummary.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Spanish summary for a single album should use the singular álbum"
        )
        XCTAssertTrue(
            singularPeopleSummary.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Spanish summary for a single person should use the singular persona"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "es-tvos-singular-selection-counts")
    }

    @MainActor
    func testTVOSSpanishAcceptancePlaybackSettingsScreenshots() throws {
        try runTVOSLocalizedPlaybackSettingsAcceptance(locale: .spanish)
    }

    @MainActor
    func testTVOSSpanishAcceptanceAccessProtectionScreenshot() throws {
        try runTVOSLocalizedAccessProtectionAcceptance(locale: .spanish)
    }

    @MainActor
    func testTVOSSpanishAcceptanceServerAndCacheScreenshots() throws {
        try runTVOSLocalizedServerAndCacheAcceptance(locale: .spanish)
    }

    @MainActor
    func testTVOSSpanishAcceptanceAboutScreenshots() throws {
        try runTVOSLocalizedAboutAcceptance(locale: .spanish)
    }

    @MainActor
    func runTVOSLocalizedCoreAcceptance(locale: LocalizedAcceptanceLocale) throws {
        let modeApp = try launchIntoModeSelection(
            colorScheme: "light",
            languageCode: locale.languageCode,
            localeIdentifier: locale.localeIdentifier
        )
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: modeApp, label: locale.modeSelectionTitle, timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS mode selection page should show the target locale text"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: modeApp, name: "\(locale.screenshotPrefix)-tvos-mode-selection")
        modeApp.terminate()

        let filterSummaryApp = try launchIntoFilterSummary(
            colorScheme: "light",
            languageCode: locale.languageCode,
            localeIdentifier: locale.localeIdentifier
        )
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: filterSummaryApp, label: locale.filterSummaryTitle,
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS filter summary page should show the target locale text"
        )
        waitForReadinessMarker(app: filterSummaryApp, identifier: "filterSummary.album.ready")
        waitForFocusVisualSettle()
        attachScreenshot(app: filterSummaryApp, name: "\(locale.screenshotPrefix)-tvos-filter-summary")
        filterSummaryApp.terminate()

        let albumApp = try launchIntoFilterSummary(
            colorScheme: "light",
            languageCode: locale.languageCode,
            localeIdentifier: locale.localeIdentifier
        )
        openAlbumFilter(from: albumApp)
        waitForAlbumFilterReady(app: albumApp)
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: albumApp, label: locale.albumFilterTitle, timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS album filter page should show the target locale text"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: albumApp, name: "\(locale.screenshotPrefix)-tvos-album-filter")
        albumApp.terminate()

        let personApp = try launchIntoFilterSummary(
            colorScheme: "light",
            languageCode: locale.languageCode,
            localeIdentifier: locale.localeIdentifier
        )
        openPersonFilter(from: personApp)
        waitForPersonFilterReady(app: personApp)
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: personApp, label: locale.personFilterTitle, timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS person filter page should show the target locale text"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: personApp, name: "\(locale.screenshotPrefix)-tvos-person-filter")
    }

    @MainActor
    func runTVOSLocalizedPlaybackSettingsAcceptance(locale: LocalizedAcceptanceLocale) throws {
        let settingsApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: locale.languageCode,
            localeIdentifier: locale.localeIdentifier
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: settingsApp, name: "\(locale.screenshotPrefix)-tvos-slideshow")

        openSettingsFromSlideShow(app: settingsApp)
        _ = waitForSettingsHomeItem(
            app: settingsApp,
            identifier: "settings.item.playback",
            downStepsFromPlayback: SettingsNavigation.playbackSteps,
            failureMessage: "Localized tvOS settings home should show Playback Settings"
        )
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: settingsApp, label: locale.playbackSettingsTitle,
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS settings home should show the Playback Settings entry"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: settingsApp, name: "\(locale.screenshotPrefix)-tvos-settings-root")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: settingsApp, identifier: "settings.playback.autoPlay.link",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS playback settings page should show the Autoplay entry"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: settingsApp, name: "\(locale.screenshotPrefix)-tvos-settings-playback")
    }

    @MainActor
    func runTVOSLocalizedAccessProtectionAcceptance(locale: LocalizedAcceptanceLocale) throws {
        let accessProtectionApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: locale.languageCode,
            localeIdentifier: locale.localeIdentifier
        )
        openSettingsFromSlideShow(app: accessProtectionApp)
        _ = waitForSettingsHomeItem(
            app: accessProtectionApp,
            identifier: "settings.item.accessProtection",
            downStepsFromPlayback: SettingsNavigation.accessProtectionSteps,
            failureMessage: "Localized tvOS settings home should be able to open Access Protection"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: accessProtectionApp, label: locale.accessProtectionDisabledTitle,
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS access protection page should show the disabled state"
        )
        // UI-test mode exposes row values verbatim; they must still be localized, not catalog keys.
        let enableButton = accessProtectionApp.buttons["settings.pin.enable.button"]
        XCTAssertTrue(enableButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))
        let enableValue = enableButton.value as? String ?? ""
        XCTAssertTrue(
            enableValue.contains(locale.accessProtectionEnableRequirement),
            "Turn-on row value is not localized: \(enableValue)"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: accessProtectionApp, name: "\(locale.screenshotPrefix)-tvos-settings-access-protection")
    }

    @MainActor
    func runTVOSLocalizedServerAndCacheAcceptance(locale: LocalizedAcceptanceLocale) throws {
        let serverApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: locale.languageCode,
            localeIdentifier: locale.localeIdentifier
        )
        openSettingsFromSlideShow(app: serverApp)
        _ = waitForSettingsHomeItem(
            app: serverApp,
            identifier: "settings.item.server",
            downStepsFromPlayback: SettingsNavigation.serverSteps,
            failureMessage: "Localized tvOS settings home should be able to open Server"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: serverApp, identifier: "server.apiKey.help.button",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS server page should show the API Key help entry"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: serverApp, name: "\(locale.screenshotPrefix)-tvos-settings-server")
        serverApp.terminate()

        let cacheApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: locale.languageCode,
            localeIdentifier: locale.localeIdentifier
        )
        openSettingsFromSlideShow(app: cacheApp)
        _ = waitForSettingsHomeItem(
            app: cacheApp,
            identifier: "settings.item.cache",
            downStepsFromPlayback: SettingsNavigation.cacheSteps,
            failureMessage: "Localized tvOS settings home should be able to open Cache Management"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: cacheApp, identifier: "settings.cache.disk.row",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS cache page should show the disk cache metric"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: cacheApp, name: "\(locale.screenshotPrefix)-tvos-settings-cache")
    }

    @MainActor
    func runTVOSLocalizedAboutAcceptance(locale: LocalizedAcceptanceLocale) throws {
        let aboutApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: locale.languageCode,
            localeIdentifier: locale.localeIdentifier
        )
        openSettingsFromSlideShow(app: aboutApp)
        _ = waitForSettingsHomeItem(
            app: aboutApp,
            identifier: "settings.item.about",
            downStepsFromPlayback: SettingsNavigation.aboutSteps,
            failureMessage: "Localized tvOS settings home should be able to open About"
        )
        XCUIRemote.shared.press(.select)

        let appInfoSection = waitForSettingsControl(
            app: aboutApp,
            identifier: "settings.about.appInfo.section",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page should show the App Info section"
        )
        waitForButtonToGainFocus(
            appInfoSection,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page default focus should land on App Info"
        )
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: aboutApp, label: locale.appInfoTitle, timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS About page should show the target locale text"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: aboutApp, name: "\(locale.screenshotPrefix)-tvos-settings-about")

        let privacyPolicyLink = waitForSettingsControl(
            app: aboutApp,
            identifier: "settings.about.privacyPolicy.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page should show the Privacy Policy entry"
        )
        for _ in 0..<3 {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.22)
        }
        waitForButtonToGainFocus(
            privacyPolicyLink,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page should let focus move to Privacy Policy"
        )
        attachScreenshot(app: aboutApp, name: "\(locale.screenshotPrefix)-tvos-settings-about-bottom")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: aboutApp, identifier: "settings.about.privacyPolicy.section.0",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS privacy policy page should open the policy text"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: aboutApp, name: "\(locale.screenshotPrefix)-tvos-settings-privacy-policy")
        aboutApp.terminate()

        let openSourceApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: locale.languageCode,
            localeIdentifier: locale.localeIdentifier
        )
        openSettingsFromSlideShow(app: openSourceApp)
        _ = waitForSettingsHomeItem(
            app: openSourceApp,
            identifier: "settings.item.about",
            downStepsFromPlayback: SettingsNavigation.aboutSteps,
            failureMessage: "Localized tvOS settings home should be able to open About again"
        )
        XCUIRemote.shared.press(.select)

        let openSourceAppInfoSection = waitForSettingsControl(
            app: openSourceApp,
            identifier: "settings.about.appInfo.section",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page should show the App Info section"
        )
        waitForButtonToGainFocus(
            openSourceAppInfoSection,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page default focus should land on App Info"
        )

        let openSourceLink = waitForSettingsControl(
            app: openSourceApp,
            identifier: "settings.about.opensource.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page should show the Open Source Licenses entry"
        )
        for _ in 0..<4 {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.22)
        }
        waitForButtonToGainFocus(
            openSourceLink,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page should let focus move to Open Source Licenses"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: openSourceApp, label: locale.openSourceTitle, timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS open source licenses page should show the target locale text"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: openSourceApp, name: "\(locale.screenshotPrefix)-tvos-settings-open-source")
    }

    @MainActor
    func testTVOSModeSelectionInlineOnboardingHeaderScreenshot() throws {
        let app = try launchIntoModeSelection()
        attachScreenshot(app: app, name: "tvos-onboarding-mode-selection-inline-header")
    }

    @MainActor
    func testTVOSModeSelectionInlineOnboardingHeaderScreenshotLight() throws {

        let app = try launchIntoModeSelection(colorScheme: "light")
        attachScreenshot(app: app, name: "tvos-onboarding-mode-selection-inline-header-light")
    }

    @MainActor
    func testTVOSModeSelectionInlineOnboardingHeaderAccessibilityTextScreenshot() throws {

        let app = try launchIntoModeSelection(dynamicTypeSize: "accessibility3")
        attachScreenshot(app: app, name: "tvos-onboarding-mode-selection-inline-header-accessibility-text")
    }

    @MainActor
    func testTVOSModeSelectionInlineOnboardingHeaderScreenshotEnglish() throws {

        let app = try launchIntoModeSelection(
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        attachScreenshot(app: app, name: "tvos-onboarding-mode-selection-inline-header-english")
    }

    @MainActor
    func testTVOSModeSelectionContinueToggleKeepsFilteredCardStableScreenshot() throws {
        let app = try launchIntoModeSelection()
        let filteredButton = app.buttons["mode.filtered.button"]
        let continueButton = app.buttons["mode.continue.button"]

        XCTAssertTrue(
            filteredButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Mode selection page should show the 'Filtered slideshow' card"
        )
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Mode selection page should show the 'Continue' button")

        moveFocusToFilteredModeCard()
        XCUIRemote.shared.press(.select)
        waitForFocusVisualSettle(seconds: 0.22)
        moveFocusToModeContinueButton()

        for _ in 0..<3 {
            XCUIRemote.shared.press(.up)
            waitForFocusVisualSettle(seconds: 0.22)
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.22)
        }

        XCTAssertTrue(continueButton.isEnabled, "After choosing a mode, the 'Continue' button should become enabled")
        XCTAssertTrue(
            isSettingsControlFocused(continueButton),
            "After switching back and forth, focus should stay on the 'Continue' button")
        XCTAssertFalse(
            isSettingsControlFocused(filteredButton),
            "After switching back and forth, the 'Filtered slideshow' card should not stay in a focused state")

        attachScreenshot(app: app, name: "tvos-onboarding-mode-selection-continue-toggle-stable")
    }

    @MainActor
    func testTVOSModeSelectionContinueFocusedScreenshotLight() throws {

        let app = try launchIntoModeSelection(colorScheme: "light")

        moveFocusToFilteredModeCard()
        XCUIRemote.shared.press(.select)
        waitForFocusVisualSettle(seconds: 0.22)
        moveFocusToModeContinueButton()

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "In light mode the 'Continue' button should be visible")
        XCTAssertTrue(
            continueButton.isEnabled, "In light mode, after choosing a mode, the 'Continue' button should be enabled")
        XCTAssertTrue(
            isSettingsControlFocused(continueButton),
            "In light mode focus should land reliably on the 'Continue' button")

        attachScreenshot(app: app, name: "tvos-onboarding-mode-selection-continue-focused-light")
    }

    @MainActor
    func testTVOSFilterSummaryAlbumStateScreenshot() throws {
        let app = try launchIntoFilterSummary()
        waitForReadinessMarker(app: app, identifier: "filterSummary.album.ready")
        attachScreenshot(app: app, name: "tvos-filter-summary-album-state")
    }

    @MainActor
    func testTVOSFilterSummaryAlbumStateScreenshotLight() throws {

        let app = try launchIntoFilterSummary(colorScheme: "light")
        waitForReadinessMarker(app: app, identifier: "filterSummary.album.ready")
        attachScreenshot(app: app, name: "tvos-filter-summary-album-state-light")
    }

    @MainActor
    func testTVOSFilterSummaryAlbumStateAccessibilityTextScreenshot() throws {

        let app = try launchIntoFilterSummary(dynamicTypeSize: "accessibility3")
        waitForReadinessMarker(app: app, identifier: "filterSummary.album.ready")
        attachScreenshot(app: app, name: "tvos-filter-summary-album-state-accessibility-text")
    }

    @MainActor
    func testTVOSFilterSummaryAlbumStateScreenshotEnglish() throws {

        let app = try launchIntoFilterSummary(languageCode: "en", localeIdentifier: "en_US")
        waitForReadinessMarker(app: app, identifier: "filterSummary.album.ready")
        attachScreenshot(app: app, name: "tvos-filter-summary-album-state-english")
    }

    @MainActor
    func testTVOSFilterSummaryAlbumStateScreenshotEnglishLight() throws {

        let app = try launchIntoFilterSummary(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        waitForReadinessMarker(app: app, identifier: "filterSummary.album.ready")
        attachScreenshot(app: app, name: "tvos-filter-summary-album-state-english-light")
    }

    @MainActor
    func testTVOSFilterSummaryPeopleStateScreenshot() throws {
        let app = try launchIntoFilterSummary()
        moveFocusToPeopleCard()
        waitForReadinessMarker(app: app, identifier: "filterSummary.people.ready")
        attachScreenshot(app: app, name: "tvos-filter-summary-people-state")
    }

    @MainActor
    func testTVOSFilterSummaryPeopleStateScreenshotLight() throws {
        let app = try launchIntoFilterSummary(colorScheme: "light")
        moveFocusToPeopleCard()
        waitForReadinessMarker(app: app, identifier: "filterSummary.people.ready")
        attachScreenshot(app: app, name: "tvos-filter-summary-people-state-light")
    }

    @MainActor
    func testTVOSFilterSummaryBackButtonFocusedScreenshot() throws {
        let app = try launchIntoFilterSummary()
        moveFocusToBackButton()
        waitForReadinessMarker(app: app, identifier: "filterSummary.people.ready")
        attachScreenshot(app: app, name: "tvos-filter-summary-back-button-focused")
    }

    @MainActor
    func testTVOSFilterSummaryBackButtonFocusedScreenshotEnglish() throws {

        let app = try launchIntoFilterSummary(languageCode: "en", localeIdentifier: "en_US")
        moveFocusToBackButton()
        waitForReadinessMarker(app: app, identifier: "filterSummary.people.ready")
        attachScreenshot(app: app, name: "tvos-filter-summary-back-button-focused-english")
    }

    @MainActor
    func testTVOSFilterSummaryStartButtonFocusedScreenshotLight() throws {

        let app = try launchIntoFilterSummary(colorScheme: "light")
        moveFocusToStartButton()
        waitForReadinessMarker(app: app, identifier: "filterSummary.people.ready")
        attachScreenshot(app: app, name: "tvos-filter-summary-start-button-focused-light")
    }

    @MainActor
    func testTVOSFilterSummaryBackButtonFocusedScreenshotLight() throws {

        let app = try launchIntoFilterSummary(colorScheme: "light")
        moveFocusToBackButton()
        waitForReadinessMarker(app: app, identifier: "filterSummary.people.ready")
        attachScreenshot(app: app, name: "tvos-filter-summary-back-button-focused-light")
    }

    @MainActor
    func testTVOSFilterSummaryActionBarToggleKeepsPeopleCardStableScreenshot() throws {
        let app = try launchIntoFilterSummary()

        moveFocusToBackButton()

        for _ in 0..<3 {
            XCUIRemote.shared.press(.up)
            waitForFocusVisualSettle(seconds: 0.22)
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.22)
        }

        let backButton = app.buttons["filterSummary.backToMode.button"]
        let peopleButton = app.buttons["filterSummary.person.button"]

        XCTAssertTrue(
            backButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "After repeated switching, the 'Back to mode selection' button should still exist")
        XCTAssertTrue(
            peopleButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "After repeated switching, the 'Filter people' card should still exist")

        XCTAssertTrue(
            isSettingsControlFocused(backButton),
            "After switching back and forth, focus should stay on the 'Back to mode selection' button")
        XCTAssertFalse(
            isSettingsControlFocused(peopleButton),
            "After switching back and forth, the 'Filter people' card should not wrongly stay in a focused state")

        attachScreenshot(app: app, name: "tvos-filter-summary-actionbar-toggle-stable")
    }

    @MainActor
    func testTVOSAlbumFilterScreenshot() throws {
        let app = try launchIntoFilterSummary()
        openAlbumFilter(from: app)
        waitForAlbumFilterReady(app: app)
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-album-filter")
    }

    @MainActor
    func testTVOSEmptyAlbumAndPersonFilterPagesCanReturn() throws {

        let app = launchApp(shouldResetState: true, colorScheme: "dark")
        app.launchEnvironment["UI_TEST_SERVER_URL"] = "https://ui-test-empty-filter.invalid"
        app.launchEnvironment["UI_TEST_API_KEY"] = "ui-test-empty-filter-key"
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_EMPTY_FILTER_DATA"] = "all"
        app.launch()

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: WaitTiming.connectionTimeoutSeconds),
            "After injecting the test server config, the app should go straight to the mode selection page")
        startFilteredFlowFromModeSelection(app: app)

        openAlbumFilter(from: app)
        XCTAssertTrue(
            // ui-label-lookup: This lookup asserts the displayed empty album copy.
            waitForElementWithLabelExists(
                app: app, label: "immich中还没有相册哦～快去添加一些试试吧！", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Empty album page should show the empty-state text, confirming the no-albums branch was reached"
        )
        let albumBackButton = app.buttons["albumFilter.back.button"]
        XCTAssertTrue(
            albumBackButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Empty album page should show the back button")
        waitForButtonToGainFocus(
            albumBackButton, timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "The back button on the empty album page should be able to get tvOS focus")
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-empty-album-filter-back-focused")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            app.buttons["filterSummary.person.button"].waitForExistence(
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "After pressing Select to go back from the empty album page, the filter summary page should be shown again"
        )

        openPersonFilter(from: app)
        XCTAssertTrue(
            // ui-label-lookup: This lookup asserts the displayed empty people copy.
            waitForElementWithLabelExists(
                app: app, label: "immich 中还没有人物", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Empty person page should show the empty-state text, confirming the no-people branch was reached"
        )
        let personBackButton = app.buttons["personFilter.back.button"]
        XCTAssertTrue(
            personBackButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Empty person page should show the back button")
        waitForButtonToGainFocus(
            personBackButton, timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "The back button on the empty person page should be able to get tvOS focus")
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-empty-person-filter-back-focused")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            app.buttons["filterSummary.album.button"].waitForExistence(
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "After pressing Select to go back from the empty person page, the filter summary page should be shown again"
        )
    }

    @MainActor
    func testTVOSAlbumFilterBottomAreaScreenshot() throws {
        let app = try launchIntoFilterSummary()
        openAlbumFilter(from: app)
        waitForAlbumFilterReady(app: app)
        try moveFocusToAlbumGridBottom(app: app)
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-album-filter-bottom-area")
    }

    @MainActor
    func testTVOSAlbumFilterLightModeScreenshot() throws {
        let app = try launchIntoFilterSummary(colorScheme: "light")
        openAlbumFilter(from: app)
        waitForAlbumFilterReady(app: app)
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-album-filter-light-mode")
    }

    @MainActor
    func testTVOSAlbumFilterScreenshotEnglish() throws {

        let app = try launchIntoFilterSummary(languageCode: "en", localeIdentifier: "en_US")
        openAlbumFilter(from: app)
        waitForAlbumFilterReady(app: app)
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-album-filter-english")
    }

    @MainActor
    func testTVOSAlbumFilterScreenshotEnglishLight() throws {
        let app = try launchIntoFilterSummary(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openAlbumFilter(from: app)
        waitForAlbumFilterReady(app: app)
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-album-filter-english-light")
    }

    @MainActor
    func testTVOSAlbumFilterAccessibilityTextScreenshotEnglish() throws {
        let app = try launchIntoFilterSummary(
            dynamicTypeSize: "accessibility3",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openAlbumFilter(from: app)
        waitForAlbumFilterReady(app: app)
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-album-filter-accessibility-text-english")
    }

    @MainActor
    func testTVOSAlbumFilterAccessibilityTextScreenshot() throws {
        let app = try launchIntoFilterSummary(dynamicTypeSize: "accessibility3")
        openAlbumFilter(from: app)
        waitForAlbumFilterReady(app: app)
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-album-filter-accessibility-text")
    }

    @MainActor
    func testTVOSAlbumFilterTopBarFocusedScreenshot() throws {

        let app = try launchIntoFilterSummary()
        openAlbumFilter(from: app)
        waitForAlbumFilterReady(app: app)

        XCUIRemote.shared.press(.up)
        waitForAnyAlbumTopBarButtonToGainFocus(app: app, timeout: WaitTiming.controlAppearanceTimeoutSeconds)
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-album-filter-topbar-focused")
    }

    @MainActor
    func testTVOSAlbumFilterFocusCanMoveToSecondCard() throws {
        let app = try launchIntoFilterSummary()
        openAlbumFilter(from: app)
        waitForAlbumFilterReady(app: app)

        let firstCard = try albumCardInServerOrder(at: 0, in: app)
        let secondCard = try albumCardInServerOrder(at: 1, in: app)

        XCTAssertTrue(
            firstCard.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Album filter page should render at least the first album card")
        XCTAssertTrue(
            secondCard.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Album filter page should render at least a second album card to verify horizontal focus movement")

        waitForElementToGainFocus(
            firstCard,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "When the album filter page opens, default focus should land on the first album card"
        )

        XCUIRemote.shared.press(.right)
        waitForElementToGainFocus(
            secondCard,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving right from the first album card, focus should reach the second album card"
        )
    }

    @MainActor
    func testTVOSAlbumFilterSelectCanToggleSelectionForSecondCard() throws {
        let app = try launchIntoFilterSummary()
        openAlbumFilter(from: app)
        waitForAlbumFilterReady(app: app)

        let secondCard = try albumCardInServerOrder(at: 1, in: app)
        XCTAssertTrue(
            secondCard.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Album filter page should render at least a second album card")

        XCUIRemote.shared.press(.right)
        waitForElementToGainFocus(
            secondCard,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After moving right, focus should land on the second album card"
        )

        XCUIRemote.shared.press(.select)
        // ui-label-lookup: This checks the localized accessibility value for selected and focused state.
        waitForElementValue(
            secondCard,
            expectedValue: "已选中，已聚焦",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Pressing Select on the second album card should switch it to selected and keep focus"
        )
    }

    @MainActor
    func testTVOSAlbumFilterUpFromSecondCardCanReachTopBar() throws {
        let app = try launchIntoFilterSummary()
        openAlbumFilter(from: app)
        waitForAlbumFilterReady(app: app)

        let secondCard = try albumCardInServerOrder(at: 1, in: app)
        XCTAssertTrue(
            secondCard.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Album filter page should render at least a second album card")

        XCUIRemote.shared.press(.right)
        waitForElementToGainFocus(
            secondCard,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After moving right, focus should land on the second album card"
        )

        XCUIRemote.shared.press(.up)
        waitForAnyAlbumTopBarButtonToGainFocus(app: app, timeout: WaitTiming.controlAppearanceTimeoutSeconds)
    }

    @MainActor
    func testTVOSAlbumFilterUpFromThirdCardCanReachTopBar() throws {
        let app = try launchIntoFilterSummary()
        openAlbumFilter(from: app)
        waitForAlbumFilterReady(app: app)

        let thirdCard = try albumCardInServerOrder(at: 2, in: app)
        XCTAssertTrue(
            thirdCard.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Album filter page should render at least a third album card")

        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        waitForElementToGainFocus(
            thirdCard,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After moving right twice, focus should land on the third album card"
        )

        XCUIRemote.shared.press(.up)
        waitForAnyAlbumTopBarButtonToGainFocus(app: app, timeout: WaitTiming.controlAppearanceTimeoutSeconds)
    }

    @MainActor
    func testTVOSPersonFilterScreenshot() throws {
        let app = try launchIntoFilterSummary()
        openPersonFilter(from: app)
        waitForPersonFilterReady(app: app)
        attachScreenshot(app: app, name: "tvos-person-filter")
    }

    @MainActor
    func testTVOSPersonFilterLightModeScreenshot() throws {
        let app = try launchIntoFilterSummary(colorScheme: "light")
        openPersonFilter(from: app)
        waitForPersonFilterReady(app: app)
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-person-filter-light-mode")
    }

    @MainActor
    func testTVOSPersonFilterScreenshotEnglish() throws {

        let app = try launchIntoFilterSummary(languageCode: "en", localeIdentifier: "en_US")
        openPersonFilter(from: app)
        waitForPersonFilterReady(app: app)
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-person-filter-english")
    }

    @MainActor
    func testTVOSPersonFilterScreenshotEnglishLight() throws {
        let app = try launchIntoFilterSummary(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openPersonFilter(from: app)
        waitForPersonFilterReady(app: app)
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-person-filter-english-light")
    }

    @MainActor
    func testTVOSPersonFilterAccessibilityTextScreenshotEnglish() throws {
        let app = try launchIntoFilterSummary(
            dynamicTypeSize: "accessibility3",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openPersonFilter(from: app)
        waitForPersonFilterReady(app: app)
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-person-filter-accessibility-text-english")
    }

    @MainActor
    func testTVOSPersonFilterTopBarFocusedScreenshot() throws {

        let app = try launchIntoFilterSummary()
        openPersonFilter(from: app)
        waitForPersonFilterReady(app: app)

        XCUIRemote.shared.press(.up)
        let backButton = app.buttons["personFilter.back.button"]
        waitForButtonToGainFocus(
            backButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After moving up on the person filter page, the back button should get focus"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-person-filter-topbar-focused")
    }

    @MainActor
    func testTVOSPersonFilterLongNamesScreenshot() throws {
        let app = try launchIntoFilterSummary(shouldUseLongPersonNames: true)
        openPersonFilter(from: app)
        waitForPersonFilterReady(app: app)
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-person-filter-long-names")
    }

    @MainActor
    func testTVOSPersonFilterAccessibilityTextScreenshot() throws {
        let app = try launchIntoFilterSummary(dynamicTypeSize: "accessibility3")
        openPersonFilter(from: app)
        waitForPersonFilterReady(app: app)
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-person-filter-accessibility-text")
    }

    @MainActor
    func testTVOSPersonFilterPlayPauseShortcutCanEnableSoloModeForFocusedCard() throws {
        let app = try launchIntoFilterSummary()
        openPersonFilter(from: app)
        waitForPersonFilterReady(app: app)

        let firstCard = personPrimaryCardButtons(in: app).element(boundBy: 0)
        XCTAssertTrue(
            firstCard.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Person filter page should render at least the first person card")

        waitForElementToGainFocus(
            firstCard,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "When the person filter page opens, default focus should land on the first person card"
        )

        XCUIRemote.shared.press(.playPause)
        // ui-label-lookup: This checks the localized accessibility value for selected solo playback state.
        waitForElementValue(
            firstCard,
            expectedValue: "已选中，单人模式，已聚焦",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "Pressing Play/Pause on the focused person card should go straight to selected with solo mode"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-person-filter-playpause-solo-enabled")
    }

    @MainActor
    func testTVOSPersonFilterPlayPauseShortcutCanEnableSoloModeForFocusedCardEnglish() throws {

        let app = try launchIntoFilterSummary(languageCode: "en", localeIdentifier: "en_US")
        openPersonFilter(from: app)
        waitForPersonFilterReady(app: app)

        let firstCard = personPrimaryCardButtons(in: app).element(boundBy: 0)
        XCTAssertTrue(
            firstCard.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "English person filter page should render at least the first person card")

        waitForElementToGainFocus(
            firstCard,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "When the English person filter page opens, default focus should land on the first person card"
        )

        XCUIRemote.shared.press(.playPause)
        waitForElementValue(
            firstCard,
            expectedValue: "Selected, Solo Mode, Focused",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In English, pressing Play/Pause should switch to selected with solo mode"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-person-filter-playpause-solo-enabled-english")
    }

    @MainActor
    func testTVOSPersonFilterFocusCanMoveToSecondCard() throws {
        let app = try launchIntoFilterSummary()
        openPersonFilter(from: app)
        waitForPersonFilterReady(app: app)

        let personCards = personPrimaryCardButtons(in: app)
        let firstCard = personCards.element(boundBy: 0)
        let secondCard = personCards.element(boundBy: 1)

        XCTAssertTrue(
            firstCard.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Person filter page should render at least the first primary person card")
        XCTAssertTrue(
            secondCard.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Person filter page should render at least a second primary person card to verify horizontal focus movement"
        )

        waitForElementToGainFocus(
            firstCard,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "When the person filter page opens, default focus should land on the first primary person card"
        )

        XCUIRemote.shared.press(.right)
        waitForElementToGainFocus(
            secondCard,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "Moving right from the first person card, focus should reach the second, not stay stuck in the first"
        )
    }

    @MainActor
    func testTVOSPersonFilterSelectCanToggleSelectionForSecondCard() throws {
        let app = try launchIntoFilterSummary()
        openPersonFilter(from: app)
        waitForPersonFilterReady(app: app)

        let secondCard = personPrimaryCardButtons(in: app).element(boundBy: 1)
        XCTAssertTrue(
            secondCard.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Person filter page should render at least a second person card")

        XCUIRemote.shared.press(.right)
        waitForElementToGainFocus(
            secondCard,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After moving right, focus should land on the second person card"
        )

        XCUIRemote.shared.press(.select)
        // ui-label-lookup: This checks the localized accessibility value for selected and focused state.
        waitForElementValue(
            secondCard,
            expectedValue: "已选中，普通模式，已聚焦",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "Pressing Select on the second person card should add that person to the filter and keep normal mode"
        )
    }

    @MainActor
    func testTVOSExifAlbumDiagnosticScreenshots() throws {
        let photoCount = try requireExifDiagnosticAlbumAssetCount()
        // The EXIF panel belongs to single-photo scenes; SmartFill, the default, shows several photos at once.
        let app = try launchIntoSlideShow(
            shouldForceAutoPlayOff: true,
            exifDiagnosticAlbumID: try requireExifDiagnosticAlbumID(),
            shouldPrepareFilterSummaryVisuals: false,
            extraLaunchEnvironment: ["UI_TEST_FORCE_PLAYBACK_DISPLAY_MODE": "singlePhoto"]
        )

        captureTVOSExifDiagnosticSlides(
            app: app,
            expectedCount: photoCount
        )
    }

    @MainActor
    func testTVOSSlideShowControlBarCanWakeByAnyDirectionalPress() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The four-direction key test must run on tvOS.")
            return
        }

        let input = try requireStrictE2EInput()
        let app = launchApp(shouldResetState: true, shouldDisablePlaybackEntryHint: true)
        app.launchEnvironment["UI_TEST_SERVER_URL"] = input.serverURL
        app.launchEnvironment["UI_TEST_API_KEY"] = input.publicKey
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launch()
        defer { app.terminate() }

        try enterRandomPlaybackFromModeSelection(app: app)

        let directionalScenarios: [(name: String, button: XCUIRemote.Button)] = [
            ("up", .up),
            ("down", .down),
            ("left", .left),
            ("right", .right)
        ]

        for scenario in directionalScenarios {
            try assertControlBarCanWakeFromHiddenState(
                app: app,
                scenarioName: "Arrow key \(scenario.name)",
                screenshotName: "tvos-slideshow-controlbar-wakeup-by-direction-\(scenario.name)"
            ) { _ in
                XCUIRemote.shared.press(scenario.button)
            }
        }
    }

    @MainActor
    func testTVOSSlideShowInitialDefaultFocusIsPlayPause() throws {
        let app = try launchIntoSlideShow()
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]

        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "After entering the playback page, the Play/Pause button should be shown")

        waitForButtonToGainFocus(
            playPauseButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage:
                "On first entering the tvOS playback page, default focus should land on the Play/Pause button"
        )
        attachScreenshot(app: app, name: "tvos-slideshow-default-focus-playpause")
    }

    @MainActor
    func testTVOSSlideShowPlaybackEntryHintScreenshot() throws {
        let app = try launchIntoSlideShow(shouldDisablePlaybackEntryHint: false)
        let entryHintTitle = app.staticTexts["slideshow.entryHint.title"]
        let entryHintAction = app.otherElements["slideshow.entryHint.action"]
        let entryHintKeycap = app.otherElements["slideshow.entryHint.keycap"]
        let settingsButton = app.buttons["slideshow.control.settings.button"]

        XCTAssertTrue(
            entryHintTitle.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "On first reaching the playback page after the first-launch flow, the one-time tip should appear"
        )
        XCTAssertEqual(
            entryHintTitle.label,
            "在这里调整照片播放范围和速度"
        )
        XCTAssertTrue(
            entryHintAction.waitForExistence(timeout: WaitTiming.readbackTimeoutSeconds),
            "The tip bubble should show a separate action sentence that helps the user understand the next step"
        )
        XCTAssertEqual(
            entryHintAction.label,
            "按 向下键 隐藏提示"
        )
        XCTAssertTrue(
            entryHintKeycap.waitForExistence(timeout: WaitTiming.readbackTimeoutSeconds),
            "The 'Down key' in the tip bubble should show as a separate keycap label"
        )
        XCTAssertEqual(entryHintKeycap.label, "向下键")
        waitForButtonToGainFocus(
            settingsButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage:
                "First-run tip: focus should start on the settings button so the user sees what the bubble points to"
        )

        waitForPlaybackEntryHintAnimationToSettle()
        attachScreenshot(app: app, name: "tvos-slideshow-entry-hint")
    }

    @MainActor
    func testTVOSSlideShowPlaybackEntryHintEnglishScreenshot() throws {
        let app = try launchIntoSlideShow(
            shouldDisablePlaybackEntryHint: false,
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        let entryHintTitle = app.staticTexts["slideshow.entryHint.title"]
        let entryHintAction = app.otherElements["slideshow.entryHint.action"]
        let entryHintKeycap = app.otherElements["slideshow.entryHint.keycap"]
        let settingsButton = app.buttons["slideshow.control.settings.button"]

        XCTAssertTrue(
            entryHintTitle.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "In English, first entering the playback page should also show the one-time tip"
        )
        XCTAssertEqual(
            entryHintTitle.label,
            "Adjust photo range and speed here"
        )
        XCTAssertTrue(
            entryHintAction.waitForExistence(timeout: WaitTiming.readbackTimeoutSeconds),
            "In English, the action sentence should also be shown in full"
        )
        XCTAssertEqual(
            entryHintAction.label,
            "Press Down to hide this tip"
        )
        XCTAssertTrue(
            entryHintKeycap.waitForExistence(timeout: WaitTiming.readbackTimeoutSeconds),
            "In English, the Down key should still show as a separate keycap label"
        )
        XCTAssertEqual(entryHintKeycap.label, "Down")
        waitForButtonToGainFocus(
            settingsButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage:
                "In English, when the first-run tip appears, default focus should still land on the settings button"
        )

        waitForPlaybackEntryHintAnimationToSettle()
        attachScreenshot(app: app, name: "tvos-slideshow-entry-hint-en")
    }

    @MainActor
    func testTVOSSlideShowPlaybackEntryHintJapaneseScreenshot() throws {
        let app = try launchIntoSlideShow(
            shouldDisablePlaybackEntryHint: false,
            languageCode: "ja",
            localeIdentifier: "ja_JP"
        )
        let entryHintTitle = app.staticTexts["slideshow.entryHint.title"]
        let entryHintAction = app.otherElements["slideshow.entryHint.action"]
        let entryHintKeycap = app.otherElements["slideshow.entryHint.keycap"]
        let settingsButton = app.buttons["slideshow.control.settings.button"]

        XCTAssertTrue(entryHintTitle.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds))
        XCTAssertEqual(entryHintTitle.label, "ここで写真の範囲と速度を調整します")
        XCTAssertTrue(entryHintAction.waitForExistence(timeout: WaitTiming.readbackTimeoutSeconds))
        XCTAssertEqual(entryHintAction.label, "下キーを押すとヒントが閉じます")
        XCTAssertTrue(entryHintKeycap.waitForExistence(timeout: WaitTiming.readbackTimeoutSeconds))
        XCTAssertEqual(entryHintKeycap.label, "下キー")
        waitForButtonToGainFocus(
            settingsButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "When the Japanese tip appears, the settings button should still get default focus"
        )

        waitForPlaybackEntryHintAnimationToSettle()
        attachScreenshot(app: app, name: "ja-tvos-slideshow-entry-hint")
    }

    @MainActor
    func testTVOSSlideShowPlaybackEntryHintDismissesHintAndControlBarWithDown() throws {
        let app = try launchIntoSlideShow(shouldDisablePlaybackEntryHint: false)
        let entryHintBanner = app.otherElements["slideshow.entryHint.banner"]
        let settingsButton = app.buttons["slideshow.control.settings.button"]

        XCTAssertTrue(
            entryHintBanner.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "The first-run tip state should show a bubble anchored to the settings button")
        waitForButtonToGainFocus(
            settingsButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "In the first-run tip state, default focus should land on the settings button"
        )

        XCUIRemote.shared.press(.down)

        waitForElementToDisappear(
            entryHintBanner,
            timeout: WaitTiming.stateChangeTimeoutSeconds,
            failureMessage: "After pressing Down, the tip bubble should disappear immediately"
        )
        waitForElementToDisappear(
            settingsButton,
            timeout: WaitTiming.stateChangeTimeoutSeconds,
            failureMessage: "After pressing Down, the bottom control bar should hide too"
        )
    }

    @MainActor
    func testTVOSSlideShowPlaybackEntryHintShowsOnlyOncePerOnboardingFlow() throws {
        let app = try launchIntoSlideShow(shouldDisablePlaybackEntryHint: false)
        let entryHint = app.staticTexts["slideshow.entryHint.title"]

        XCTAssertTrue(
            entryHint.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "On first entering the playback page, the one-time tip should appear"
        )

        openSettingsFromSlideShow(app: app)
        exitSettingsToSlideShow(app: app)

        XCTAssertFalse(
            entryHint.waitForExistence(timeout: WaitTiming.readbackTimeoutSeconds),
            "The one-time tip should not reappear on return from settings to playback in the same first-launch flow"
        )
    }

    @MainActor
    func testTVOSSlideShowHasNoBackButtonScreenshot() throws {
        let app = try launchIntoSlideShow()
        let settingsButton = app.buttons["slideshow.control.settings.button"]

        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 18),
            "After entering the playback page, the settings entry in the bottom control bar should be visible")
        XCTAssertFalse(
            app.buttons["global.back.button"].exists,
            "The playback page must not show a back button in the top-left corner")

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-slideshow-no-back-button")
    }

    @MainActor
    func testTVOSSlideShowPlayPauseCanToggleAndWakeControlBar() throws {
        let app = try launchIntoSlideShow()
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "After entering the playback page, the Play/Pause button should be visible")

        let initialValue = (playPauseButton.value as? String) ?? ""
        XCTAssertFalse(
            initialValue.isEmpty, "The Play/Pause button should expose its current state value (play or pause)")

        waitForElementToDisappear(
            playPauseButton,
            timeout: WaitTiming.screenTransitionTimeoutSeconds,
            failureMessage: "The control bar should hide on its own before the Play/Pause wake path is verified"
        )

        // Play/Pause while the bar is hidden should toggle autoplay and bring back the control bar.
        XCUIRemote.shared.press(.playPause)

        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "Pressing Play/Pause while the control bar is hidden should wake the bar and show the playback state"
        )

        let updatedValue = (playPauseButton.value as? String) ?? ""
        XCTAssertNotEqual(
            updatedValue,
            initialValue,
            "After pressing Play/Pause, the playback state should toggle (play <-> pause)"
        )
        attachScreenshot(app: app, name: "tvos-slideshow-controlbar-wakeup-by-playpause")
    }

    @MainActor
    func testTVOSSlideShowWakeReturnsFocusToPlayPause() throws {
        let app = try launchIntoSlideShow()
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]

        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "After entering the playback page, the Play/Pause button should be visible")
        waitForButtonToGainFocus(
            playPauseButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "When the playback page first opens, focus should land on the Play/Pause button"
        )

        // Wake as soon as the bar starts hiding: a press during the fade-out is the hardest case for focus.
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.screenTransitionTimeoutSeconds) { !playPauseButton.exists },
            "The control bar must hide on its own before it can be woken"
        )

        XCUIRemote.shared.press(.up)

        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "Pressing a direction key while the control bar is hidden should wake the bar first"
        )
        waitForButtonToGainFocus(
            playPauseButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "After the control bar wakes again, focus should return to the Play/Pause button"
        )
        attachScreenshot(app: app, name: "tvos-slideshow-wake-focus-playpause")

        // Then wake a bar that has fully faded out, the path most presses take. The invisible wake receiver takes
        // focus as the 0.3-second fade-out starts, so it has to keep focus for longer than the fade.
        let wakeReceiver = app.otherElements["slideshow.hiddenWakeReceiver"]
        var receiverFocusedSince: Date?
        // The bar hides 8 seconds after the first wake; the wait also covers the fade and the focus hold.
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.connectionTimeoutSeconds) {
                guard !playPauseButton.exists, wakeReceiver.exists, wakeReceiver.hasFocus else {
                    receiverFocusedSince = nil
                    return false
                }
                let focusedSince = receiverFocusedSince ?? Date()
                receiverFocusedSince = focusedSince
                return Date().timeIntervalSince(focusedSince) >= 0.6
            },
            "The control bar must hide on its own again and leave focus on the wake receiver"
        )
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "A directional press must bring back a fully hidden control bar"
        )
        waitForButtonToGainFocus(
            playPauseButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "Waking a fully hidden control bar must focus Play/Pause"
        )
    }

    @MainActor
    func testTVOSSlideShowControlBarFocusStatesScreenshot() throws {
        let app = try launchIntoSlideShow()
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        let previousButton = app.buttons["slideshow.control.previous.button"]
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        let nextButton = app.buttons["slideshow.control.next.button"]

        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "Playback page should show the settings button")
        XCTAssertTrue(
            previousButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "Playback page should show the previous button")
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "Playback page should show the Play/Pause button")
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "Playback page should show the next button")

        for _ in 0..<5 {
            if settingsButton.hasFocus { break }
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.remotePressSettleSeconds))
        }

        waitForButtonToGainFocus(
            settingsButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "The control bar should be able to bring focus to the settings button (far left)"
        )
        attachScreenshot(app: app, name: "tvos-slideshow-controlbar-focus-settings")

        XCTAssertFalse(
            previousButton.isEnabled,
            "At the initial history boundary, previous should be disabled and skipped in the tvOS focus path")

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            playPauseButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage:
                "Previous is disabled at the initial history boundary, so moving right should jump focus to Play/Pause"
        )
        attachScreenshot(app: app, name: "tvos-slideshow-controlbar-focus-playpause")

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            nextButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "Moving right again, focus should reach the next button"
        )
        attachScreenshot(app: app, name: "tvos-slideshow-controlbar-focus-next")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.settingsChangeTimeoutSeconds) { previousButton.isEnabled },
            "One next should create history to go back to and enable previous again"
        )

        XCUIRemote.shared.press(.left)
        waitForButtonToGainFocus(
            playPauseButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "Moving left from next, focus should return to the Play/Pause button"
        )

        XCUIRemote.shared.press(.left)
        waitForButtonToGainFocus(
            previousButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "Once history exists, moving left again should reach the previous button"
        )
        attachScreenshot(app: app, name: "tvos-slideshow-controlbar-focus-previous")
    }

    @MainActor
    func testTVOSSlideShowControlBarLightModeContrastScreenshot() throws {
        let app = try launchIntoSlideShow(colorScheme: "light")
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "Light mode playback page should show the control bar")

        for _ in 0..<5 {
            if settingsButton.hasFocus { break }
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.remotePressSettleSeconds))
        }

        waitForButtonToGainFocus(
            settingsButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "Before the light mode screenshot, focus should land back on the settings button reliably"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-slideshow-controlbar-light-contrast")
    }

    @MainActor
    func testTVOSSlideShowControlBarButtonsCanActivateOnSelect() throws {
        let app = try launchIntoSlideShow()
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        let previousButton = app.buttons["slideshow.control.previous.button"]
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        let nextButton = app.buttons["slideshow.control.next.button"]
        let removedProgressLabel = app.staticTexts["slideshow.control.progress.label"]

        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "Playback page should show the settings button")
        XCTAssertTrue(
            previousButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "Playback page should show the previous button")
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "Playback page should show the Play/Pause button")
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "Playback page should show the next button")
        XCTAssertFalse(
            removedProgressLabel.exists, "The visible photo index above the control bar should have been removed")

        // Bring focus back to the far left first; the later path is only stable from there.
        for _ in 0..<5 {
            if settingsButton.hasFocus { break }
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.remotePressSettleSeconds))
        }

        waitForButtonToGainFocus(
            settingsButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage:
                "Before the control bar activation test starts, focus should return to the settings button reliably"
        )

        let initialSignature = try currentTVOSSceneSignature(app: app)

        XCTAssertFalse(
            previousButton.isEnabled,
            "At the initial history boundary, previous should be disabled and out of the tvOS focus path")

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            playPauseButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage:
                "Previous is disabled at the initial history boundary, so moving right should focus Play/Pause"
        )

        let initialPlayPauseValue = (playPauseButton.value as? String) ?? ""
        XCTAssertFalse(initialPlayPauseValue.isEmpty, "The Play/Pause button should expose its current state value")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.stateChangeTimeoutSeconds) {
                ((playPauseButton.value as? String) ?? "") != initialPlayPauseValue
            },
            "Pressing Select on the Play/Pause button should toggle the current playback state"
        )

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            nextButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "After moving right again, focus should reach the next button"
        )

        XCUIRemote.shared.press(.select)
        let signatureAfterNext = try waitForTVOSSceneSignatureChange(
            app: app,
            from: initialSignature,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds
        )
        XCTAssertNotEqual(signatureAfterNext, initialSignature, "The next button should move the visible scene forward")

        XCUIRemote.shared.press(.left)
        waitForButtonToGainFocus(
            playPauseButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "Moving left from next, focus should return to the Play/Pause button"
        )

        XCUIRemote.shared.press(.left)
        waitForButtonToGainFocus(
            previousButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "Moving left again, focus should reach the previous button"
        )

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.controlAppearanceTimeoutSeconds) {
                self.currentTVOSSceneSignatureValue(app: app) == initialSignature
            },
            "Pressing Select on the previous button should go back to the previous scene in playback history"
        )

        XCUIRemote.shared.press(.left)
        waitForButtonToGainFocus(
            settingsButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "Moving left again, focus should return to the settings button"
        )

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForAnySettingsSurface(app: app, timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "Pressing Select on the settings button should open the settings page or the PIN check page"
        )
    }

    @MainActor
    func testTVOSPreviousNextRetainedHistoryFromSlideshowControls() throws {
        let app = try launchIntoSlideShow(shouldForceAutoPlayOff: true)
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        let previousButton = app.buttons["slideshow.control.previous.button"]
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        let nextButton = app.buttons["slideshow.control.next.button"]

        ensureTVOSSlideshowControlBarVisible(app: app)
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "Playback page should show the settings button")
        XCTAssertTrue(
            previousButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "Playback page should show the previous button")
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "Playback page should show the Play/Pause button")
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "Playback page should show the next button")

        waitForButtonToGainFocus(
            playPauseButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "Once the control bar appears, default focus should be on the Play/Pause button"
        )
        attachScreenshot(app: app, name: "tvos-retained-history-01-initial")

        let initialSignature = try currentTVOSSceneSignature(app: app)

        XCTAssertFalse(
            previousButton.isEnabled,
            "At the history boundary, previous should be disabled and out of the tvOS focus path")

        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        let secondSignature = try waitForTVOSSceneSignatureChange(
            app: app, from: initialSignature, timeout: WaitTiming.controlAppearanceTimeoutSeconds)
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.stateChangeTimeoutSeconds) { previousButton.isEnabled },
            "Once there is history to go back to, previous should be enabled again"
        )
        attachScreenshot(app: app, name: "tvos-retained-history-02-after-next")

        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        let thirdSignature = try waitForTVOSSceneSignatureChange(
            app: app, from: secondSignature, timeout: WaitTiming.controlAppearanceTimeoutSeconds)
        XCTAssertNotEqual(thirdSignature, initialSignature, "Two nexts in a row should reach a new playback scene")
        attachScreenshot(app: app, name: "tvos-retained-history-03-after-second-next")

        ensureTVOSSlideshowControlBarVisible(app: app)
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.left)

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.controlAppearanceTimeoutSeconds) {
                self.currentTVOSSceneSignatureValue(app: app) == secondSignature
            },
            "The first previous should go back to the prior retained-history position"
        )
        attachScreenshot(app: app, name: "tvos-retained-history-04-previous-to-second")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.controlAppearanceTimeoutSeconds) {
                self.currentTVOSSceneSignatureValue(app: app) == initialSignature
            },
            "The second previous should continue along retained history back to the initial position"
        )
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.stateChangeTimeoutSeconds) { previousButton.isEnabled == false },
            "Back at the oldest history boundary, previous should be disabled again"
        )
        attachScreenshot(app: app, name: "tvos-retained-history-05-previous-to-initial")
    }

    @MainActor
    func testTVOSSettingsPlaybackDefaultFocusedScreenshot() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "After opening settings, the home page should show the 'Playback Settings' entry")

        waitForSettingsHomeItemFocus(
            button: playbackItem,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening settings, default focus should land on 'Playback Settings'"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-root-default-focus")
    }

    @MainActor
    func testTVOSSettingsAutoPlayUsesDedicatedSubpage() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home should show the 'Playback Settings' entry")
        waitForSettingsHomeItemFocus(
            button: playbackItem,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Settings home default focus should land on 'Playback Settings'"
        )
        XCUIRemote.shared.press(.select)

        let autoPlayLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening Playback Settings, the 'Autoplay' row should be visible"
        )

        waitForButtonToGainFocus(
            autoPlayLink,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "After opening 'Playback Settings', default focus should land on the first actionable item, 'Autoplay'"
        )

        XCUIRemote.shared.press(.select)

        let autoPlayOnButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.on.button",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening 'Autoplay', the 'Autoplay on' option should be shown"
        )
        let autoPlayOffButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.off.button",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening 'Autoplay', the 'Autoplay off' option should be shown"
        )

        waitForButtonToGainFocus(
            autoPlayOnButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening 'Autoplay', default focus should land on the first item, 'Autoplay on'"
        )
        waitForFocusVisualSettle()

        let isOnOptionSelected = accessibilityValueString(for: autoPlayOnButton).contains("已选中")
        if isOnOptionSelected {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle()
        }
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.controlAppearanceTimeoutSeconds) {

                self.accessibilityValueString(for: autoPlayOnButton).contains(isOnOptionSelected ? "未选中" : "已选中")
                    && self.accessibilityValueString(for: autoPlayOffButton).contains(
                        isOnOptionSelected ? "已选中" : "未选中")
            },
            """
            After picking the other option on the 'Autoplay' subpage, the selection on this page should switch.
            Current state snapshot:
            autoPlayOn.value=\(accessibilityValueString(for: autoPlayOnButton))
            autoPlayOff.value=\(accessibilityValueString(for: autoPlayOffButton))
            """
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-playback-autoPlay-page")
    }

    @MainActor
    func testTVOSSettingsPlaybackIntervalUsesDedicatedSubpage() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home should show the 'Playback Settings' entry")
        waitForSettingsHomeItemFocus(
            button: playbackItem,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Settings home default focus should land on 'Playback Settings'"
        )
        XCUIRemote.shared.press(.select)

        let autoPlayLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Playback settings page should show the 'Autoplay' row"
        )
        let intervalLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.interval.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Playback settings page should show the 'Autoplay Interval' entry"
        )
        let modeLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.mode.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Playback settings page should show the 'Default Playback Mode' entry"
        )
        let displayLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.display.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Playback settings page should show the 'Display Items' entry"
        )

        waitForButtonToGainFocus(
            autoPlayLink,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening 'Playback Settings', default focus should land on the 'Autoplay' entry"
        )

        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.controlAppearanceTimeoutSeconds) {
                app.buttons["settings.playback.interval.5.button"].exists
            },
            """
            After moving down once from 'Autoplay', Select should open the 'Autoplay Interval' subpage.
            Current state snapshot:
            autoPlayLink.value=\(accessibilityValueString(for: autoPlayLink))
            intervalLink.value=\(accessibilityValueString(for: intervalLink))
            modeLink.value=\(accessibilityValueString(for: modeLink))
            displayLink.value=\(accessibilityValueString(for: displayLink))
            autoPlayPage.exists=\(app.buttons["settings.playback.autoPlay.on.button"].exists)
            intervalPage.exists=\(app.buttons["settings.playback.interval.5.button"].exists)
            """
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-playback-interval-page")
    }

    @MainActor
    func testTVOSSettingsFilterConfigButtonCanOpenEditor() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home should show the 'Playback Settings' entry")
        waitForSettingsHomeItemFocus(
            button: playbackItem,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Settings home default focus should land on 'Playback Settings'"
        )
        XCUIRemote.shared.press(.select)

        let autoPlayLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Playback settings page should show the 'Autoplay' entry"
        )
        let filterConfigButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.filterConfig.button",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "When the default playback mode is 'Filtered playback', the 'Edit Filters' entry should be shown"
        )

        waitForButtonToGainFocus(
            autoPlayLink,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening 'Playback Settings', default focus should land on the 'Autoplay' entry"
        )

        for _ in 0..<8 where !filterConfigButton.hasFocus {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle()
        }
        XCTAssertTrue(filterConfigButton.hasFocus, "Edit Filters must get focus first")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.navigationTimeoutSeconds) {
                app.buttons["filter.editor.done.button"].exists && app.buttons["filter.editor.album.entry"].exists
                    && app.buttons["filter.editor.person.entry"].exists
            },
            """
            Selecting 'Edit Filters' should actually open the filter editor, not stay on the playback settings page.
            Current state snapshot:
            filterConfig.exists=\(filterConfigButton.exists)
            filterConfig.value=\(accessibilityValueString(for: filterConfigButton))
            done.exists=\(app.buttons["filter.editor.done.button"].exists)
            album.exists=\(app.buttons["filter.editor.album.entry"].exists)
            people.exists=\(app.buttons["filter.editor.person.entry"].exists)
            """
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-filter-editor")
    }

    @MainActor
    func testTVOSSettingsSidebarDefaultsToPlaybackAndCanMoveToAccessProtection() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let playbackItem = app.buttons["settings.item.playback"]
        let accessProtectionItem = app.buttons["settings.item.accessProtection"]

        XCTAssertTrue(
            playbackItem.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "After opening settings, the home page should show the 'Playback Settings' entry")
        XCTAssertTrue(
            accessProtectionItem.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "After opening settings, the home page should show the 'Access Protection' entry")

        waitForSettingsHomeItemFocus(
            button: playbackItem,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening settings, default focus should land on 'Playback Settings'"
        )

        XCUIRemote.shared.press(.down)
        waitForSettingsHomeItemFocus(
            button: accessProtectionItem,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After moving down once on the home page, focus should reach 'Access Protection'"
        )

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.pin.enable.button",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds
            ),
            "After opening 'Access Protection', the PIN enable controls should be shown"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-access-protection-page")
    }

    @MainActor
    func testTVOSSettingsSidebarDirectionalRoutingMatchesPressedDirection() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let playbackItem = app.buttons["settings.item.playback"]
        let accessProtectionItem = app.buttons["settings.item.accessProtection"]

        XCTAssertTrue(
            playbackItem.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home page should show the 'Playback Settings' entry")
        XCTAssertTrue(
            accessProtectionItem.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home page should show the 'Access Protection' entry")

        waitForSettingsHomeItemFocus(
            button: playbackItem,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening settings, default focus should land reliably on 'Playback Settings'"
        )

        XCUIRemote.shared.press(.down)
        waitForSettingsHomeItemFocus(
            button: accessProtectionItem,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Pressing Down on 'Playback Settings' should move focus to 'Access Protection'"
        )
        XCUIRemote.shared.press(.select)
        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening 'Access Protection', the PIN settings should be shown"
        )

        waitForButtonToGainFocus(
            enablePinInput,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening 'Access Protection', default focus should go to the first PIN input entry"
        )
    }

    @MainActor
    func testTVOSSettingsSidebarAccessProtectionScreenshotLight() throws {

        let app = try launchIntoSlideShow(colorScheme: "light")
        openSettingsFromSlideShow(app: app)

        let accessProtectionItem = app.buttons["settings.item.accessProtection"]
        XCTAssertTrue(
            accessProtectionItem.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "After opening settings, the home page should show the 'Access Protection' entry")

        XCUIRemote.shared.press(.down)
        waitForSettingsHomeItemFocus(
            button: accessProtectionItem,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In light mode, moving down on the home page should also reliably focus 'Access Protection'"
        )

        XCUIRemote.shared.press(.select)
        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In light mode, opening 'Access Protection' should show the PIN input entry"
        )
        waitForButtonToGainFocus(
            enablePinInput,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "In light mode, on the access protection page default focus should be on the 'Set PIN' input entry"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-access-protection-page-light")
    }

    @MainActor
    func testTVOSSettingsAccessProtectionAccessibilityTextScreenshot() throws {

        let app = try launchIntoSlideShow(dynamicTypeSize: "accessibility3")
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.accessProtection",
            downStepsFromPlayback: SettingsNavigation.accessProtectionSteps,
            failureMessage:
                "With large text, settings home should reliably reach the 'Access Protection' entry with direction keys"
        )

        XCUIRemote.shared.press(.select)
        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "With large text, opening 'Access Protection' should show the 'Set PIN' input entry"
        )
        waitForButtonToGainFocus(
            enablePinInput,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "With large text, on the access protection page default focus should be on the 'Set PIN' input entry"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-access-protection-accessibility-text")
    }

    @MainActor
    func testTVOSPinSheetAccessibilityTextBottomRowRoutingScreenshot() throws {

        let app = try launchIntoSlideShow(dynamicTypeSize: "accessibility3")
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.accessProtection",
            downStepsFromPlayback: SettingsNavigation.accessProtectionSteps,
            failureMessage:
                "With large text, settings home should reliably reach the 'Access Protection' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "With large text, the access protection page should show the 'Set PIN' input entry"
        )
        waitForButtonToGainFocus(
            enablePinInput,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "With large text, entering the access protection page should focus the 'Set PIN' input entry first"
        )
        XCUIRemote.shared.press(.select)

        let digitOneButton = app.buttons["pinEntry.digit.1.button"]
        let closeButton = app.buttons["pinEntry.close.button"]
        let zeroButton = app.buttons["pinEntry.digit.0.button"]
        let deleteButton = app.buttons["pinEntry.delete.button"]

        XCTAssertTrue(
            closeButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "With large text, the opened PIN sheet should show the close button")
        XCTAssertTrue(
            digitOneButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "With large text, the opened PIN sheet should show the number pad")
        XCTAssertTrue(
            zeroButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "With large text, the PIN sheet should show digit 0")
        XCTAssertTrue(
            deleteButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "With large text, the PIN sheet should show the delete button")

        waitForButtonToGainFocus(
            digitOneButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "With large text, default focus in the opened PIN sheet should land on digit 1"
        )

        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            closeButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "With large text, moving down three times from digit 1 should land focus on 'Close'"
        )

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            zeroButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "With large text, moving right from 'Close' should move focus to digit 0"
        )

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            deleteButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "With large text, moving right from digit 0 should move focus to 'Delete'"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-pin-sheet-accessibility-text-routing")
    }

    @MainActor
    func testTVOSPinSheetDefaultsToDigitOneAndBottomRowKeepsStableRouting() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let accessProtectionItem = app.buttons["settings.item.accessProtection"]
        XCTAssertTrue(
            accessProtectionItem.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home page should show the 'Access Protection' entry")

        XCUIRemote.shared.press(.down)
        waitForSettingsHomeItemFocus(
            button: accessProtectionItem,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After moving down, focus should reach 'Access Protection'"
        )

        XCUIRemote.shared.press(.select)

        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Set PIN' input entry"
        )
        waitForButtonToGainFocus(
            enablePinInput,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "On entering the access protection page, focus should land on the 'Set PIN' input entry first"
        )

        XCUIRemote.shared.press(.select)

        let digitOneButton = app.buttons["pinEntry.digit.1.button"]
        let digitTwoButton = app.buttons["pinEntry.digit.2.button"]
        let closeButton = app.buttons["pinEntry.close.button"]
        let zeroButton = app.buttons["pinEntry.digit.0.button"]
        let deleteButton = app.buttons["pinEntry.delete.button"]

        XCTAssertTrue(
            closeButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "The opened PIN sheet should show the close button")
        XCTAssertTrue(
            digitOneButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "The opened PIN sheet should show the number pad")
        XCTAssertTrue(
            digitTwoButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "The opened PIN sheet should show digit 2")
        XCTAssertTrue(
            zeroButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "The PIN sheet should show digit 0")
        XCTAssertTrue(
            deleteButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "The PIN sheet should show the delete button")

        // The PIN sheet's default focus must be on the digit pad, not drift to the close button.
        waitForButtonToGainFocus(
            digitOneButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "When the PIN sheet opens, default focus should land on digit 1"
        )

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            digitTwoButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving right from digit 1, focus should reach digit 2"
        )

        XCUIRemote.shared.press(.left)
        waitForButtonToGainFocus(
            digitOneButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving left from digit 2, focus should return to digit 1"
        )

        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            closeButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down three times from digit 1, focus should land reliably on 'Close'"
        )

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            zeroButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving right from 'Close', focus should reach digit 0"
        )

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            deleteButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving right from digit 0, focus should reach 'Delete'"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-pin-sheet-bottom-row-routing")
    }

    @MainActor
    func testTVOSAccessProtectionShowsProminentSuccessFeedbackAfterEnable() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let accessProtectionItem = app.buttons["settings.item.accessProtection"]
        XCTAssertTrue(
            accessProtectionItem.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home page should show the 'Access Protection' entry")

        XCUIRemote.shared.press(.down)
        waitForSettingsHomeItemFocus(
            button: accessProtectionItem,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After moving down, focus should reach 'Access Protection'"
        )
        XCUIRemote.shared.press(.select)

        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Set PIN' input entry"
        )
        let enablePinConfirmInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enableConfirm",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Confirm PIN' input entry"
        )
        let enableProtectionButton = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.enable.button",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Enable Access Protection' button"
        )

        waitForButtonToGainFocus(
            enablePinInput,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the access protection page, default focus should land on the 'Set PIN' input entry"
        )
        XCUIRemote.shared.press(.select)
        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Set PIN")

        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            enablePinConfirmInput,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After filling 'Set PIN', moving down should focus 'Confirm PIN'"
        )
        XCUIRemote.shared.press(.select)
        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Confirm PIN")

        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            enableProtectionButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "After entering and confirming the PIN, moving down should focus the 'Enable Access Protection' button"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.pin.feedback.success.prominent",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds
            ),
            "After access protection is enabled, a prominent success banner should show at the top of the page. state=\(accessibilityValueString(for: app.otherElements["settings.pin.stateProbe"]))"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.pin.disable.button",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds
            ),
            "After access protection is enabled, the page should switch to the 'Disable Access Protection' controls"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-access-protection-enable-success-feedback")
    }

    @MainActor
    func testTVOSAccessProtectionShowsProminentSuccessFeedbackAfterDisable() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let accessProtectionItem = app.buttons["settings.item.accessProtection"]
        XCTAssertTrue(
            accessProtectionItem.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home page should show the 'Access Protection' entry")

        XCUIRemote.shared.press(.down)
        waitForSettingsHomeItemFocus(
            button: accessProtectionItem,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After moving down, focus should reach 'Access Protection'"
        )
        XCUIRemote.shared.press(.select)

        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Set PIN' input entry"
        )
        let enablePinConfirmInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enableConfirm",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Confirm PIN' input entry"
        )
        let enableProtectionButton = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.enable.button",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Enable Access Protection' button"
        )

        waitForButtonToGainFocus(
            enablePinInput,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the access protection page, default focus should land on the 'Set PIN' input entry"
        )
        XCUIRemote.shared.press(.select)
        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Set PIN")

        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            enablePinConfirmInput,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After filling 'Set PIN', moving down should focus 'Confirm PIN'"
        )
        XCUIRemote.shared.press(.select)
        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Confirm PIN")

        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            enableProtectionButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "After entering and confirming the PIN, moving down should focus the 'Enable Access Protection' button"
        )
        XCUIRemote.shared.press(.select)

        let disableCurrentPinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.disableCurrent",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "After enabling access protection, the 'Enter current PIN' entry should be shown. state=\(accessibilityValueString(for: app.otherElements["settings.pin.stateProbe"]))"
        )
        let disableProtectionButton = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.disable.button",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After enabling access protection, the 'Disable Access Protection' button should be shown"
        )

        waitForButtonToGainFocus(
            disableCurrentPinInput,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "After access protection is enabled, default focus should be on the 'Enter current PIN' entry"
        )
        XCUIRemote.shared.press(.select)
        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Enter current PIN")

        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            disableProtectionButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "After entering the current PIN, moving down should focus the 'Disable Access Protection' button"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.pin.feedback.success.prominent",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds
            ),
            "After access protection is disabled, a prominent success banner should be shown. state=\(accessibilityValueString(for: app.otherElements["settings.pin.stateProbe"]))"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.pin.enable.button",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds
            ),
            "After disabling access protection, the page should switch back to the 'Enable Access Protection' controls"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-access-protection-disable-success-feedback")
    }

    @MainActor
    func testTVOSSettingsServerPageShowsFormAndStatusBanner() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.server",
            downStepsFromPlayback: SettingsNavigation.serverSteps,
            failureMessage: "Settings home should reliably reach the 'Server' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "firstboot.serverURL.row", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "The server page should show the server URL input row"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "firstboot.apiKey.row", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "The server page should show the API Key input row"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "firstboot.testConnection.button",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "The server page should show the Test Connection button"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "server.apiKey.help.button", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "The server page should show the API Key help entry"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.server.hero.summary",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Server page should show the connection status summary in the Hero area"
        )

        _ = waitForSettingsControl(
            app: app,
            identifier: "firstboot.serverURL.row",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "The server page should show the server URL input row"
        )
        let serverURLField = waitForSettingsControl(
            app: app,
            identifier: "firstboot.serverURL.field",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "The server page should expose the server URL text field itself"
        )
        waitForButtonToGainFocus(
            serverURLField,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the server page, default focus should land reliably on the server URL field"
        )

        assertTVOSServerSettingsAPIKeyHelpSheet(
            app: app,
            context: "tvOS server settings page",
            shouldVerifySimplifiedChineseContent: true,
            screenshotName: "tvos-settings-server-api-key-help-sheet-dark"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-server-page-dark")
    }

    @MainActor
    func testTVOSSettingsServerDetailTestConnectionAlertAppearsInline() throws {
        let app = try launchIntoSlideShow(extraLaunchEnvironment: [
            "UI_TEST_APP_STORE_SCREENSHOT_PREFILL_CONNECTION": "1",
            "UI_TEST_APP_STORE_SCREENSHOT_SERVER_URL": "foo://invalid-host",
            "UI_TEST_APP_STORE_SCREENSHOT_API_KEY": "ui-test-invalid-key"
        ])
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.server",
            downStepsFromPlayback: SettingsNavigation.serverSteps,
            failureMessage: "Settings home should reliably reach the 'Server' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.server.hero.summary",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "The server detail page should show the server settings Hero"
        )

        let testConnectionButton = waitForSettingsControl(
            app: app,
            identifier: "firstboot.testConnection.button",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Server detail page should show the Test Connection button"
        )
        for _ in 0..<4 {
            if testConnectionButton.hasFocus { break }
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.shortFocusSettleSeconds))
        }
        waitForButtonToGainFocus(
            testConnectionButton,
            timeout: WaitTiming.stateChangeTimeoutSeconds,
            failureMessage:
                "On the server detail page, direction keys should be able to focus the Test Connection button"
        )
        XCUIRemote.shared.press(.select)

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let alert = app.alerts["连接测试失败"]
        XCTAssertTrue(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            alert.waitForExistence(timeout: WaitTiming.stateChangeTimeoutSeconds),
            "Test Connection on server detail should show the error there at once, not after returning to settings root"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.server.hero.summary", timeout: WaitTiming.briefElementTimeoutSeconds),
            "When the alert appears, the server detail page should still be underneath, not the settings root"
        )
        XCTAssertTrue(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            alert.staticTexts["服务器地址必须以 http 或 https 开头"].exists
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                || alert.staticTexts["服务器地址格式无效"].exists,
            "A prefilled invalid URL should trigger the local server URL validation error"
        )
    }

    @MainActor
    func testTVOSSettingsCachePageShowsAllCacheMetrics() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.cache",
            downStepsFromPlayback: SettingsNavigation.cacheSteps,
            failureMessage: "Settings home should reliably reach the 'Cache Management' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.cache.disk.row", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Cache page should show the 'Disk Cache' metric"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.cache.trackedURL.row",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Cache page should show the 'Tracked URLs' metric"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.cache.trackedState.row",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Cache page should show the 'Tracked States' metric"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.cache.runningTask.row",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Cache page should show the 'Running Tasks' metric"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.cache.clearDisk.button",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Cache page should show the clear disk cache button"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-cache-page-dark")
    }

    @MainActor
    func testTVOSSettingsCacheClearShowsConfirmationImmediately() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.cache",
            downStepsFromPlayback: SettingsNavigation.cacheSteps,
            failureMessage: "Settings home should reliably reach the 'Cache Management' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        let clearCacheButton = waitForSettingsControl(
            app: app,
            identifier: "settings.cache.clearDisk.button",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Cache page should show the 'Clear Disk Cache' button"
        )

        for _ in 0..<8 {
            if clearCacheButton.hasFocus || accessibilityValueString(for: clearCacheButton).contains("focused") {
                break
            }
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.remotePressSettleSeconds))
        }

        waitForButtonToGainFocus(
            clearCacheButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the cache page, direction keys should be able to focus the 'Clear Disk Cache' button"
        )

        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.stateChangeTimeoutSeconds) {
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                self.waitForElementWithLabelExists(app: app, label: "确认清理磁盘缓存", timeout: 0)
                    // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                    || app.alerts.element(boundBy: 0).exists
                    // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                    || self.waitForElementWithLabelExists(app: app, label: "清理", timeout: 0)
                    // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                    || self.waitForElementWithLabelExists(app: app, label: "取消", timeout: 0)
            },
            "After choosing 'Clear Disk Cache', a confirmation should pop up right away on the cache page"
        )
        XCTAssertTrue(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            waitForElementWithLabelExists(app: app, label: "清理", timeout: WaitTiming.stateChangeTimeoutSeconds),
            "The confirmation dialog should show the 'Clear' action button"
        )
        XCTAssertTrue(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            waitForElementWithLabelExists(app: app, label: "取消", timeout: WaitTiming.stateChangeTimeoutSeconds),
            "The confirmation dialog should show the 'Cancel' button"
        )
    }

    @MainActor
    func testTVOSSettingsAboutPageShowsVersionAndPlatformInfo() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.about",
            downStepsFromPlayback: SettingsNavigation.aboutSteps,
            failureMessage: "Settings home should reliably reach the 'About' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.appName.row", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the app name"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.version.row", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the version number"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.platform.row", timeout: WaitTiming.controlAppearanceTimeoutSeconds
            ),
            "About page should show the platform info"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.feedback.hint",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the feedback hint"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.feedback.email",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the support email row (existence only; the address text is not read)"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.unofficialNotice.hint",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the unofficial notice"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.privacyPolicy.link",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the Privacy Policy entry"
        )
        XCTAssertTrue(
            // ui-label-lookup: This lookup asserts the displayed feedback hint copy.
            app.staticTexts["提交问题前，建议先确认版本号与运行平台。"].waitForExistence(
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the real feedback text, not placeholder text"
        )
        XCTAssertTrue(
            // ui-label-lookup: This lookup asserts the displayed privacy description copy.
            app.staticTexts["查看完整隐私政策与数据处理说明。"].waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the privacy policy description"
        )
        XCTAssertFalse(
            // ui-label-lookup: This lookup rejects obsolete displayed placeholder copy.
            app.staticTexts["后续会在这里补齐反馈入口和开源协议链接。"].waitForExistence(timeout: WaitTiming.briefElementTimeoutSeconds),
            "About page should no longer show 'to be added later' placeholder text"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-about-page-dark")
    }

    @MainActor
    func testTVOSSettingsAboutPageFocusCanReachPrivacyAndOpenSourceEntries() throws {

        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.about",
            downStepsFromPlayback: SettingsNavigation.aboutSteps,
            failureMessage: "Settings home should reliably reach the 'About' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        let appInfoSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.appInfo.section",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should expose the 'App Info' focus area"
        )
        waitForButtonToGainFocus(
            appInfoSection,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the About page, the first focus should land on the 'App Info' section"
        )

        let unofficialNoticeSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.unofficialNotice.section",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should expose the 'Unofficial Notice' focus area"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            unofficialNoticeSection,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down from 'App Info', focus should reach the 'Unofficial Notice' section"
        )

        let feedbackSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.feedback.section",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should expose the 'Feedback & Support' focus area"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            feedbackSection,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down again, focus should reach the 'Feedback & Support' section"
        )

        let privacyPolicyLink = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should show the 'Privacy Policy' entry"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            privacyPolicyLink,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down again, focus should reach the 'Privacy Policy' entry"
        )

        let openSourceLink = waitForSettingsControl(
            app: app,
            identifier: "settings.about.opensource.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should show the 'Open Source Licenses' entry"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            openSourceLink,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down again, focus should reach the 'Open Source Licenses' entry"
        )

        attachScreenshot(app: app, name: "tvos-settings-about-page-bottom-focus-dark")

        XCUIRemote.shared.press(.up)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            privacyPolicyLink,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "Moving back up from 'Open Source Licenses', focus should return reliably to the 'Privacy Policy' entry"
        )
    }

    @MainActor
    func testTVOSSettingsPrivacyPolicyEntryOpensBundledPage() throws {

        let app = try launchIntoSlideShow(
            languageCode: "zh-Hans",
            localeIdentifier: "zh_CN"
        )
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.about",
            downStepsFromPlayback: SettingsNavigation.aboutSteps,
            failureMessage: "Settings home should reliably reach the 'About' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        let appInfoSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.appInfo.section",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the About page, the top 'App Info' focus area should be found first"
        )
        waitForButtonToGainFocus(
            appInfoSection,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the About page, the first focus should land on the 'App Info' section"
        )

        let privacyPolicyLink = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should show the 'Privacy Policy' entry"
        )

        for _ in 0..<3 {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.22)
        }

        waitForButtonToGainFocus(
            privacyPolicyLink,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "In the lower half of the About page, focus should land reliably on the 'Privacy Policy' entry"
        )

        XCUIRemote.shared.press(.select)

        let chineseLanguageButton = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.language.zh.button",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Privacy policy page should show the 'Chinese' language button"
        )
        let englishLanguageButton = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.language.en.button",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Privacy policy page should show the 'English' language button"
        )
        let firstPolicySection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.section.0",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Privacy policy page should show at least the first body section"
        )
        XCTAssertTrue(
            firstPolicySection.label.contains("适用范围"),
            "tvOS privacy policy page should show the Chinese text first, not only the English version"
        )

        waitForButtonToGainFocus(
            chineseLanguageButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "On the privacy policy page, default focus should land directly on the 'Chinese' language button"
        )

        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            firstPolicySection,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down from the language button, focus should enter the privacy policy text"
        )

        attachScreenshot(app: app, name: "tvos-settings-privacy-policy-page-dark")

        XCUIRemote.shared.press(.up)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            chineseLanguageButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving back up from the text, focus should return to the current language button"
        )

        XCUIRemote.shared.press(.right)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            englishLanguageButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving right from the Chinese button, focus should reach the English button"
        )

        XCUIRemote.shared.press(.select)
        waitForFocusVisualSettle(seconds: 0.22)

        let englishFirstPolicySection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.section.0",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After choosing English, the privacy policy page should still show the first body section"
        )
        XCTAssertTrue(
            englishFirstPolicySection.label.contains("Scope"),
            "After choosing English, the first section should switch to English instead of staying in Chinese"
        )

        let tablePolicySection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.section.2",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "The privacy policy data processing section should remain a separate focusable section"
        )

        for _ in 0..<3 {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.22)
        }

        waitForButtonToGainFocus(
            tablePolicySection,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down again, focus should reach the section with the data processing table"
        )

        attachScreenshot(app: app, name: "tvos-settings-privacy-policy-table-section-dark")
    }

    @MainActor
    func testTVOSSettingsAccessProtectionScreenshotDark() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.accessProtection",
            downStepsFromPlayback: SettingsNavigation.accessProtectionSteps,
            failureMessage: "Settings home should reliably reach the 'Access Protection' entry with direction keys"
        )

        XCUIRemote.shared.press(.select)
        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In dark mode, opening 'Access Protection' should show the PIN input entry"
        )
        waitForButtonToGainFocus(
            enablePinInput,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "In dark mode, on the access protection page default focus should be on the 'Set PIN' input entry"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-access-protection-page-dark")
    }

    @MainActor
    func testTVOSSettingsServerPageScreenshotLight() throws {
        let app = try launchIntoSlideShow(colorScheme: "light")
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.server",
            downStepsFromPlayback: SettingsNavigation.serverSteps,
            failureMessage:
                "In light mode, the settings home should reliably reach the 'Server' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.server.hero.summary",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "In light mode, the server page should show the connection status summary in the Hero area"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "server.apiKey.help.button", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "In light mode, the server page should show the API Key help entry"
        )

        _ = waitForSettingsControl(
            app: app,
            identifier: "firstboot.serverURL.row",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In light mode, the server page should show the server URL input row"
        )
        let serverURLField = waitForSettingsControl(
            app: app,
            identifier: "firstboot.serverURL.field",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In light mode, the server page should expose the server URL text field itself"
        )
        waitForButtonToGainFocus(
            serverURLField,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In light mode, on the server page default focus should be on the server URL field"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-server-page-light")
    }

    @MainActor
    func testTVOSSettingsServerPageEnglishLocalizationScreenshotLight() throws {

        let app = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.server",
            downStepsFromPlayback: SettingsNavigation.serverSteps,
            failureMessage: "In English, the settings home should reliably reach the 'Server' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        let serverURLField = waitForSettingsControl(
            app: app,
            identifier: "firstboot.serverURL.field",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In English, the server page should expose the server URL text field itself"
        )
        waitForButtonToGainFocus(
            serverURLField,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In English, on the server page default focus should be on the server URL field"
        )

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "server.apiKey.help.button", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "In English, the server page should show the API Key help entry"
        )
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: app, label: "Test Connection", timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "In English, the action buttons should still show English text"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-server-page-english-light")
    }

    @MainActor
    func testTVOSSettingsCachePageScreenshotLight() throws {
        let app = try launchIntoSlideShow(colorScheme: "light")
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.cache",
            downStepsFromPlayback: SettingsNavigation.cacheSteps,
            failureMessage:
                "In light mode, settings home should reliably reach the 'Cache Management' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.cache.disk.row", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "In light mode, the cache page should show the metrics area"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-cache-page-light")
    }

    @MainActor
    func testTVOSSettingsAboutPageScreenshotLight() throws {
        let app = try launchIntoSlideShow(colorScheme: "light")
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.about",
            downStepsFromPlayback: SettingsNavigation.aboutSteps,
            failureMessage:
                "In light mode, the settings home should reliably reach the 'About' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.version.row", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "In light mode, the About page should show the version info"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.about.unofficialNotice.hint",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "In light mode, the About page should show the unofficial notice"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-about-page-light")
    }

    @MainActor
    func testTVOSSettingsOpenSourceLicensesPageScreenshotDark() throws {

        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.about",
            downStepsFromPlayback: SettingsNavigation.aboutSteps,
            failureMessage: "Settings home should reliably reach the 'About' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        let openSourceLink = waitForSettingsControl(
            app: app,
            identifier: "settings.about.opensource.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should show the 'Open Source Licenses' entry"
        )
        let appInfoSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.appInfo.section",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should expose the 'App Info' focus area"
        )
        let unofficialNoticeSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.unofficialNotice.section",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should expose the 'Unofficial Notice' focus area"
        )
        let feedbackSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.feedback.section",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should expose the 'Feedback & Support' focus area"
        )
        let privacyPolicyLink = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "About page should show the 'Privacy Policy' entry"
        )
        waitForButtonToGainFocus(
            appInfoSection,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the About page, default focus should land on the 'App Info' section"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            unofficialNoticeSection,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down from 'App Info', focus should reach the 'Unofficial Notice' section"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            feedbackSection,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down again, focus should reach the 'Feedback & Support' section"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            privacyPolicyLink,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down again, focus should reach the 'Privacy Policy' entry"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            openSourceLink,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Moving down from 'Privacy Policy' should reliably focus the 'Open Source Licenses' entry"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-about-open-source-entry-dark")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.about.opensource.sdwebimage.summary",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds
            ),
            "Open source licenses page should show the SDWebImage component info"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.about.opensource.sdwebimageswiftui.summary",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds
            ),
            "Open source licenses page should show the SDWebImageSwiftUI component info"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.about.opensource.sharedLicense",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds
            ),
            "Open source licenses page should show the shared license text"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-open-source-page-dark")
    }

    @MainActor
    func testTVOSEnglishAcceptanceSettingsPagesScreenshots() throws {

        let playbackApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openSettingsFromSlideShow(app: playbackApp)
        _ = waitForSettingsHomeItem(
            app: playbackApp,
            identifier: "settings.item.playback",
            downStepsFromPlayback: SettingsNavigation.playbackSteps,
            failureMessage: "In English, the tvOS settings home should show Playback Settings"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: playbackApp, name: "english-tvos-settings-root")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: playbackApp, identifier: "settings.playback.autoPlay.link",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "English playback settings page should show the Autoplay entry"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: playbackApp, name: "english-tvos-settings-playback")
        playbackApp.terminate()

        let accessProtectionApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openSettingsFromSlideShow(app: accessProtectionApp)
        _ = waitForSettingsHomeItem(
            app: accessProtectionApp,
            identifier: "settings.item.accessProtection",
            downStepsFromPlayback: SettingsNavigation.accessProtectionSteps,
            failureMessage: "In English, the settings home should be able to open Access Protection"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: accessProtectionApp, label: "Access protection is disabled",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "English access protection page should show the disabled state"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: accessProtectionApp, name: "english-tvos-settings-access-protection")
        accessProtectionApp.terminate()

        let serverApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openSettingsFromSlideShow(app: serverApp)
        _ = waitForSettingsHomeItem(
            app: serverApp,
            identifier: "settings.item.server",
            downStepsFromPlayback: SettingsNavigation.serverSteps,
            failureMessage: "In English, the settings home should be able to open Server"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: serverApp, identifier: "server.apiKey.help.button",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "English server page should show the API Key help entry"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: serverApp, name: "english-tvos-settings-server")
        serverApp.terminate()

        let cacheApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openSettingsFromSlideShow(app: cacheApp)
        _ = waitForSettingsHomeItem(
            app: cacheApp,
            identifier: "settings.item.cache",
            downStepsFromPlayback: SettingsNavigation.cacheSteps,
            failureMessage: "In English, the settings home should be able to open Cache Management"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: cacheApp, identifier: "settings.cache.disk.row",
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "English cache page should show the disk cache metric"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: cacheApp, name: "english-tvos-settings-cache")
    }

    @MainActor
    func testTVOSEnglishAcceptanceAboutPrivacyAndOpenSourceScreenshots() throws {

        let app = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.about",
            downStepsFromPlayback: SettingsNavigation.aboutSteps,
            failureMessage: "In English, the settings home should be able to open About"
        )
        XCUIRemote.shared.press(.select)

        let appInfoSection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.appInfo.section",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should show the App Information section"
        )
        waitForButtonToGainFocus(
            appInfoSection,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the English About page, the first focus should land on App Information"
        )
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: app, label: "App Information", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "English About page should show App Information"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "english-tvos-settings-about")

        let privacyPolicyLink = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should show the Privacy Policy entry"
        )
        for _ in 0..<3 {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.22)
        }
        waitForButtonToGainFocus(
            privacyPolicyLink,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should let focus move to Privacy Policy"
        )
        attachScreenshot(app: app, name: "english-tvos-settings-about-bottom")
        XCUIRemote.shared.press(.select)

        let chineseLanguageButton = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.language.zh.button",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Privacy policy page should show the Chinese language button"
        )
        let englishLanguageButton = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.language.en.button",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Privacy policy page should show the English language button"
        )
        let chineseLanguageValue = accessibilityValueString(for: chineseLanguageButton)
        let englishLanguageValue = accessibilityValueString(for: englishLanguageButton)
        XCTAssertTrue(
            englishLanguageValue.contains("Selected") && englishLanguageValue.contains("Not Selected") == false,
            "In English, the English button should be selected by default on the privacy policy page"
        )
        XCTAssertTrue(
            chineseLanguageValue.contains("Not Selected") || chineseLanguageValue.contains("未选中"),
            "In English, the Chinese button should not still be selected on the privacy policy page"
        )

        let englishFirstPolicySection = waitForSettingsControl(
            app: app,
            identifier: "settings.about.privacyPolicy.section.0",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In English, the privacy policy page should show the English text right away"
        )
        XCTAssertTrue(
            englishFirstPolicySection.label.contains("Scope"),
            "The English privacy policy page should show Scope as its first section by default, not the Chinese text"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "english-tvos-settings-privacy-policy")
        app.terminate()

        let openSourceApp = try launchIntoSlideShow(
            colorScheme: "light",
            languageCode: "en",
            localeIdentifier: "en_US"
        )
        openSettingsFromSlideShow(app: openSourceApp)
        _ = waitForSettingsHomeItem(
            app: openSourceApp,
            identifier: "settings.item.about",
            downStepsFromPlayback: SettingsNavigation.aboutSteps,
            failureMessage: "In English, the settings home should be able to open About again"
        )
        XCUIRemote.shared.press(.select)

        let openSourceAppInfoSection = waitForSettingsControl(
            app: openSourceApp,
            identifier: "settings.about.appInfo.section",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should expose the App Information section"
        )
        let openSourceUnofficialSection = waitForSettingsControl(
            app: openSourceApp,
            identifier: "settings.about.unofficialNotice.section",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should expose the Unofficial Notice section"
        )
        let openSourceFeedbackSection = waitForSettingsControl(
            app: openSourceApp,
            identifier: "settings.about.feedback.section",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should expose the Feedback & Support section"
        )
        let openSourcePrivacyLink = waitForSettingsControl(
            app: openSourceApp,
            identifier: "settings.about.privacyPolicy.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should show the Privacy Policy entry"
        )
        let openSourceLink = waitForSettingsControl(
            app: openSourceApp,
            identifier: "settings.about.opensource.link",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should show the Open Source Licenses entry"
        )
        waitForButtonToGainFocus(
            openSourceAppInfoSection,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page default focus should land on App Information"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            openSourceUnofficialSection,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should let focus go from App Information to Unofficial Notice"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            openSourceFeedbackSection,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should let focus go from Unofficial Notice to Feedback & Support"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            openSourcePrivacyLink,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should let focus go from Feedback & Support to Privacy Policy"
        )
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        waitForButtonToGainFocus(
            openSourceLink,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "English About page should let focus move to Open Source Licenses"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: openSourceApp, label: "Open Source Licenses", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "English open source licenses page should show Open Source Licenses"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: openSourceApp, name: "english-tvos-settings-open-source")
    }

    @MainActor
    func testTVOSFullFlowModeSelectionToAccessProtectionCanReachTargetPage() throws {

        let app = try launchIntoFilterSummary()

        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startPlaybackButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Filter summary page should show the 'Start Playback' button")

        if startPlaybackButton.hasFocus == false {
            for _ in 0..<8 {
                XCUIRemote.shared.press(.down)
                RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.remotePressSettleSeconds))
                if startPlaybackButton.hasFocus {
                    break
                }
            }
        }

        XCTAssertTrue(startPlaybackButton.hasFocus, "Focus should move reliably to the 'Start Playback' button")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 18),
            "Starting playback from filter summary should open playback with the control bar settings button"
        )

        openSettingsFromSlideShow(app: app)
        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.accessProtection",
            downStepsFromPlayback: SettingsNavigation.accessProtectionSteps,
            failureMessage: "Settings home should reliably reach the 'Access Protection' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.pin.input.enable", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "On the access protection page, the 'Set PIN' input entry should be shown"
        )
    }

    @MainActor
    func testTVOSFullFlowPinGateBlocksSettingsUntilPinValidated() throws {

        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.accessProtection",
            downStepsFromPlayback: SettingsNavigation.accessProtectionSteps,
            failureMessage: "Settings home should reliably reach the 'Access Protection' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Set PIN' input entry"
        )
        let enablePinConfirmInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enableConfirm",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Confirm PIN' input entry"
        )
        let enableProtectionButton = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.enable.button",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Enable Access Protection' button"
        )

        waitForButtonToGainFocus(
            enablePinInput,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "On the access protection page, default focus should land on the 'Set PIN' input entry"
        )
        XCUIRemote.shared.press(.select)
        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Set PIN")

        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            enablePinConfirmInput,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After filling 'Set PIN', moving down should focus the 'Confirm PIN' input entry"
        )
        XCUIRemote.shared.press(.select)
        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Confirm PIN")

        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            enableProtectionButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "After entering and confirming the PIN, moving down should focus the 'Enable Access Protection' button"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.pin.disable.button", timeout: WaitTiming.controlAppearanceTimeoutSeconds
            ),
            "After access protection is enabled, the page should switch to the 'Disable Access Protection' controls"
        )

        exitSettingsToSlideShow(app: app)
        openSettingsFromSlideShow(app: app)

        let pinCloseButton = app.buttons["pinEntry.close.button"]
        XCTAssertTrue(
            pinCloseButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "With access protection enabled, opening settings again should first show the PIN check sheet"
        )

        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Settings unlock")
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "settings.item.playback", timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "After the correct PIN, the settings home should open"
        )
    }

    @MainActor
    func testTVOSAlbumCardAccessibilityFramesIgnoreCoverShape() throws {
        let app = try launchIntoFilterSummary()
        openAlbumFilter(from: app)
        waitForAlbumFilterReady(app: app)

        try AlbumCardSnapshot.assertFramesIgnoreCoverShape(in: app)
    }

}

private extension FilterSummaryTVOSVisualUITests {
    func requireTVOSDestination(file: StaticString = #filePath, line: UInt = #line) throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            throw XCTSkip(
                "The current target is not tvOS (detected: \(UIDevice.current.model)); skipping tvOS UI tests.")
        }
    }

    func launchApp(
        shouldResetState: Bool,
        shouldSeedFilterSelection: Bool = false,
        colorScheme: String? = nil,
        dynamicTypeSize: String? = nil,
        shouldDisablePlaybackEntryHint: Bool = true,
        shouldUseLongPersonNames: Bool = false,
        shouldForceAutoPlayOff: Bool = false,
        exifDiagnosticAlbumID: String? = nil,
        languageCode: String? = nil,
        localeIdentifier: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        if shouldResetState {
            app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        }
        if shouldSeedFilterSelection {
            app.launchEnvironment["UI_TEST_SEED_FILTER_SELECTION"] = "1"
        }
        if let colorScheme {
            app.launchEnvironment["UI_TEST_COLOR_SCHEME"] = colorScheme
        }
        if let dynamicTypeSize {

            app.launchEnvironment["UI_TEST_DYNAMIC_TYPE_SIZE"] = dynamicTypeSize
        }
        if shouldDisablePlaybackEntryHint {

            app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        }
        if shouldUseLongPersonNames {

            app.launchEnvironment["UI_TEST_FORCE_LONG_PERSON_NAMES"] = "1"
        }
        if shouldForceAutoPlayOff {

            app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        }
        if let exifDiagnosticAlbumID {

            app.launchEnvironment["UI_TEST_EXIF_DIAGNOSTIC_ALBUM_ID"] = exifDiagnosticAlbumID
        }
        if let languageCode, let localeIdentifier {

            app.launchArguments += [
                "-AppleLanguages", "(\(languageCode))",
                "-AppleLocale", localeIdentifier
            ]
        }
        return app
    }

    @MainActor
    func launchIntoFilterSummary(
        colorScheme: String = "dark",
        dynamicTypeSize: String? = nil,
        shouldDisablePlaybackEntryHint: Bool = true,
        shouldUseLongPersonNames: Bool = false,
        shouldForceAutoPlayOff: Bool = false,
        exifDiagnosticAlbumID: String? = nil,
        shouldPrepareFilterSummaryVisuals: Bool = true,
        languageCode: String? = nil,
        localeIdentifier: String? = nil,
        extraLaunchEnvironment: [String: String] = [:]
    ) throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = launchApp(
            shouldResetState: true,
            shouldSeedFilterSelection: true,
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            shouldDisablePlaybackEntryHint: shouldDisablePlaybackEntryHint,
            shouldUseLongPersonNames: shouldUseLongPersonNames,
            shouldForceAutoPlayOff: shouldForceAutoPlayOff,
            exifDiagnosticAlbumID: exifDiagnosticAlbumID,
            languageCode: languageCode,
            localeIdentifier: localeIdentifier
        )
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        if shouldPrepareFilterSummaryVisuals {
            try requireServerAlbumAndPerson()
            app.launchEnvironment["UI_TEST_PREPARE_FILTER_SUMMARY_VISUAL_SELECTIONS"] = "1"
        }
        for (key, value) in extraLaunchEnvironment {
            app.launchEnvironment[key] = value
        }
        app.launch()

        let expectedOnboardingTitles = expectedLocalizedTextCandidates(
            languageCode: languageCode,
            chinese: "首次设置向导",
            english: "Setup Wizard"
        )
        let expectedModeSelectionPageTitles = expectedLocalizedTextCandidates(
            languageCode: languageCode,
            chinese: "选择播放方式",
            english: "Choose Playback Mode"
        )
        let expectedFilterSummaryPageTitles = expectedLocalizedTextCandidates(
            languageCode: languageCode,
            chinese: "设置照片范围",
            english: "Set Photo Range"
        )

        assertModeSelectionInlineOnboardingHeader(
            app: app,
            expectedModeSelectionOnboardingTitles: expectedOnboardingTitles,
            expectedModeSelectionPageTitles: expectedModeSelectionPageTitles
        )

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: WaitTiming.connectionTimeoutSeconds),
            "After injecting the test server config, the app should go straight to the mode selection page")
        startFilteredFlowFromModeSelection(app: app)

        if shouldPrepareFilterSummaryVisuals {
            assertFilterSummaryMinimalOnboardingHeader(
                app: app,
                expectedFilterSummaryOnboardingTitles: expectedOnboardingTitles,
                expectedFilterSummaryPageTitles: expectedFilterSummaryPageTitles
            )
        } else {
            XCTAssertTrue(
                app.buttons["filterSummary.startPlayback.button"].waitForExistence(
                    timeout: WaitTiming.screenTransitionTimeoutSeconds),
                "Without visual prep, the filter summary page should still open and show the Start Playback button"
            )
        }

        let albumButton = app.buttons["filterSummary.album.button"]
        let peopleButton = app.buttons["filterSummary.person.button"]
        XCTAssertTrue(albumButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds))
        XCTAssertTrue(peopleButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds))
        return app
    }

    @MainActor
    func launchIntoModeSelection(
        colorScheme: String = "dark",
        dynamicTypeSize: String? = nil,
        languageCode: String? = nil,
        localeIdentifier: String? = nil
    ) throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = launchApp(
            shouldResetState: true,
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            languageCode: languageCode,
            localeIdentifier: localeIdentifier
        )
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launch()

        let expectedOnboardingTitles = expectedLocalizedTextCandidates(
            languageCode: languageCode,
            chinese: "首次设置向导",
            english: "Setup Wizard"
        )
        let expectedModeSelectionPageTitles = expectedLocalizedTextCandidates(
            languageCode: languageCode,
            chinese: "选择播放方式",
            english: "Choose Playback Mode"
        )

        assertModeSelectionInlineOnboardingHeader(
            app: app,
            expectedModeSelectionOnboardingTitles: expectedOnboardingTitles,
            expectedModeSelectionPageTitles: expectedModeSelectionPageTitles
        )

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: WaitTiming.connectionTimeoutSeconds),
            "After injecting the test server config, the app should go straight to the mode selection page")
        return app
    }

    func startFilteredFlowFromModeSelection(app: XCUIApplication) {
        let modeFilteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(modeFilteredButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)

        let modeContinueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(modeContinueButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(modeContinueButton.isEnabled)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            app.buttons["filterSummary.startPlayback.button"].waitForExistence(
                timeout: WaitTiming.screenTransitionTimeoutSeconds))
    }

    @MainActor
    func launchIntoSlideShow(
        colorScheme: String = "dark",
        dynamicTypeSize: String? = nil,
        shouldDisablePlaybackEntryHint: Bool = true,
        shouldForceAutoPlayOff: Bool = false,
        exifDiagnosticAlbumID: String? = nil,
        shouldPrepareFilterSummaryVisuals: Bool = true,
        languageCode: String? = nil,
        localeIdentifier: String? = nil,
        extraLaunchEnvironment: [String: String] = [:]
    ) throws -> XCUIApplication {
        let app = try launchIntoFilterSummary(
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            shouldDisablePlaybackEntryHint: shouldDisablePlaybackEntryHint,
            shouldForceAutoPlayOff: shouldForceAutoPlayOff,
            exifDiagnosticAlbumID: exifDiagnosticAlbumID,
            shouldPrepareFilterSummaryVisuals: shouldPrepareFilterSummaryVisuals,
            languageCode: languageCode,
            localeIdentifier: localeIdentifier,
            extraLaunchEnvironment: extraLaunchEnvironment
        )
        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startPlaybackButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Filter summary page should show the 'Start Playback' button")

        if startPlaybackButton.hasFocus == false {
            // tvOS UI tests cannot tap directly; move focus first, then press Select.

            for _ in 0..<8 {
                XCUIRemote.shared.press(.down)
                RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.remotePressSettleSeconds))
                if startPlaybackButton.hasFocus {
                    break
                }
            }
        }

        XCTAssertTrue(
            startPlaybackButton.hasFocus,
            "On the filter summary page, focus should be able to move to the 'Start Playback' button")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 18),
            "After starting playback, the playback page should open and show the control bar"
        )
        return app
    }

    @MainActor
    func captureTVOSExifDiagnosticSlides(
        app: XCUIApplication,
        expectedCount: Int,
        screenshotNamePrefix: String = "tvos-exif-diagnostic"
    ) {
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: WaitTiming.screenTransitionTimeoutSeconds),
            "The tvOS playback page should show the Play/Pause button")
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.settingsChangeTimeoutSeconds) {
                ((playPauseButton.value as? String) ?? "").lowercased() == "play"
            },
            "Autoplay should be off in tvOS EXIF diagnostic mode so photos do not advance during screenshots"
        )

        for index in 0..<expectedCount {
            XCTAssertTrue(
                waitForTVOSExifToneReady(app: app, timeout: WaitTiming.navigationTimeoutSeconds),
                "EXIF text color sampling should be done before the screenshot of photo \(index + 1)"
            )

            let toneLabel = currentTVOSExifToneDebugLabel(app: app)
            attachScreenshot(
                app: app,
                name: "\(screenshotNamePrefix)-\(String(format: "%02d", index + 1))-\(toneLabel)"
            )

            guard index < expectedCount - 1 else { continue }

            let indexProbe = app.otherElements["slideshow.control.indexProbe"]
            let currentIndexValue = indexProbe.exists ? accessibilityValueString(for: indexProbe) : ""
            let currentDateLabel = currentTVOSExifDateLabel(app: app)
            ensureTVOSSlideshowControlBarVisible(app: app)
            moveFocusToTVOSSlideshowNextButton(app: app)
            XCUIRemote.shared.press(.select)

            if !currentIndexValue.isEmpty {
                XCTAssertTrue(
                    waitUntil(timeout: WaitTiming.controlAppearanceTimeoutSeconds) {
                        self.accessibilityValueString(for: indexProbe) != currentIndexValue
                    },
                    "After next, the playback index probe should change so the same photo is not captured twice"
                )
            } else if let currentDateLabel {
                XCTAssertTrue(
                    waitUntil(timeout: WaitTiming.controlAppearanceTimeoutSeconds) {
                        self.currentTVOSExifDateLabel(app: app) != currentDateLabel
                    },
                    "After next, the EXIF date at the top should change so the same photo is not captured twice"
                )
            } else {
                RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.screenSettleSeconds))
            }
        }
    }

    func waitForTVOSExifToneReady(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let readyFlag = app.descendants(matching: .any)["slideshow.exifForegroundTone.ready"]
        return readyFlag.waitForExistence(timeout: timeout)
    }

    func currentTVOSExifToneDebugLabel(app: XCUIApplication) -> String {
        let toneFlag = app.descendants(matching: .any)["slideshow.exifForegroundTone.flag"]
        XCTAssertTrue(
            toneFlag.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "tvOS playback page should expose the current EXIF text color diagnostic flag")

        let candidates = [
            toneFlag.label,
            toneFlag.value as? String ?? ""
        ]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "unknownTone"
    }

    func currentTVOSExifDateLabel(app: XCUIApplication) -> String? {

        let pattern = #"^\d{4}-\d{2}-\d{2}$"#
        // ui-label-lookup: This predicate validates displayed EXIF date formatting.
        let predicate = NSPredicate(format: "label MATCHES %@", pattern)
        let match = app.staticTexts.matching(predicate).firstMatch
        return match.exists ? match.label : nil
    }

    @MainActor
    func ensureTVOSSlideshowControlBarVisible(app: XCUIApplication) {
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        if playPauseButton.exists { return }

        XCUIRemote.shared.press(.up)
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "Once hidden, the control bar should wake again with a direction key"
        )
    }

    @MainActor
    func moveFocusToTVOSSlideshowNextButton(app: XCUIApplication) {
        let nextButton = app.buttons["slideshow.control.next.button"]
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "Playback page should show the next button")

        for _ in 0..<4 {
            if nextButton.hasFocus || accessibilityValueString(for: nextButton).contains("focused") {
                return
            }
            XCUIRemote.shared.press(.right)
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.focusSettleSeconds))
        }

        waitForButtonToGainFocus(
            nextButton,
            timeout: WaitTiming.shortInteractionTimeoutSeconds,
            failureMessage: "During per-photo EXIF screenshots, focus should move to the next button"
        )
    }

    @MainActor
    func enterRandomPlaybackFromModeSelection(app: XCUIApplication) throws {
        let randomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(
            randomButton.waitForExistence(timeout: WaitTiming.connectionTimeoutSeconds),
            "After injecting the public fixture, the app must reach the mode selection page")
        if randomButton.hasFocus == false {
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.focusSettleSeconds))
        }
        XCUIRemote.shared.press(.select)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "After choosing random playback, the Continue button must be shown")
        XCTAssertTrue(continueButton.isEnabled, "After choosing random playback, the Continue button must be enabled")
        for _ in 0..<2 where continueButton.hasFocus == false {
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.focusSettleSeconds))
        }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["slideshow.control.playPause.button"].waitForExistence(timeout: 30),
            "The control bar must appear after random playback starts"
        )
    }

    @MainActor
    func assertControlBarCanWakeFromHiddenState(
        app: XCUIApplication,
        scenarioName: String,
        screenshotName: String,
        trigger: (XCUIApplication) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "\(scenarioName): the control bar should be visible after entering the playback page",
            file: file,
            line: line
        )

        waitForElementToDisappear(
            settingsButton,
            timeout: WaitTiming.screenTransitionTimeoutSeconds,
            failureMessage:
                "\(scenarioName): the control bar should hide on its own before waking from hidden can be verified",
            file: file,
            line: line
        )
        let wakeReceiver = app.descendants(matching: .any)["slideshow.hiddenWakeReceiver"]
        XCTAssertTrue(
            wakeReceiver.waitForExistence(timeout: WaitTiming.stateChangeTimeoutSeconds)
                || settingsButton.exists == false,
            "\(scenarioName): the wake receiver should appear after hiding",
            file: file,
            line: line
        )
        let focusDeadline = Date().addingTimeInterval(4)
        while Date() < focusDeadline, wakeReceiver.exists, wakeReceiver.hasFocus == false {
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.focusPollSeconds))
        }

        let beforePNG = app.screenshot().pngRepresentation
        let beforeAttachment = XCTAttachment(data: beforePNG, uniformTypeIdentifier: "public.png")
        beforeAttachment.name = "\(screenshotName)-before"
        beforeAttachment.lifetime = .keepAlways
        add(beforeAttachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(beforePNG, name: "\(screenshotName)-before")
        trigger(app)

        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "\(scenarioName): the hidden control bar should wake successfully",
            file: file,
            line: line
        )
        let afterPNG = app.screenshot().pngRepresentation
        let afterAttachment = XCTAttachment(data: afterPNG, uniformTypeIdentifier: "public.png")
        afterAttachment.name = "\(screenshotName)-after"
        afterAttachment.lifetime = .keepAlways
        add(afterAttachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(afterPNG, name: "\(screenshotName)-after")
    }

    @MainActor
    func openSettingsFromSlideShow(app: XCUIApplication) {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: WaitTiming.navigationTimeoutSeconds),
            "Playback page should show the settings button")

        for _ in 0..<5 {
            if settingsButton.hasFocus { break }
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.remotePressSettleSeconds))
        }

        waitForButtonToGainFocus(
            settingsButton,
            timeout: WaitTiming.settingsChangeTimeoutSeconds,
            failureMessage: "Before opening settings, focus should return reliably to the leftmost settings button"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForAnySettingsSurface(app: app, timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Pressing Select on the settings button should open the settings page")
    }

    @MainActor
    func exitSettingsToSlideShow(app: XCUIApplication, maxMenuPresses: Int = 5) {
        for _ in 0..<maxMenuPresses {
            if app.buttons["slideshow.control.settings.button"].exists {
                return
            }
            XCUIRemote.shared.press(.menu)
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.navigationFocusSettleSeconds))
        }

        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.controlAppearanceTimeoutSeconds) {
                if app.buttons["slideshow.control.settings.button"].exists {
                    return true
                }
                XCUIRemote.shared.press(.down)
                RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.focusSettleSeconds))
                return app.buttons["slideshow.control.settings.button"].exists
            },
            "Should be able to return from settings to playback and wake the control bar"
        )
    }

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
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Settings home should show the 'Playback Settings' entry",
            file: file,
            line: line
        )

        for _ in 0..<8 {
            if isSettingsControlFocused(playbackItem) {
                break
            }
            XCUIRemote.shared.press(.up)
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.remotePressSettleSeconds))
        }

        waitForButtonToGainFocus(
            playbackItem,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Settings home should be able to bring focus back to the 'Playback Settings' entry",
            file: file,
            line: line
        )

        // Normalize focus, then take a fixed number of steps, so we never start from a random spot.

        for _ in 0..<downStepsFromPlayback {
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.remotePressSettleSeconds))
        }

        let target = waitForSettingsControl(
            app: app,
            identifier: identifier,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: failureMessage,
            file: file,
            line: line
        )

        waitForButtonToGainFocus(
            target,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
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
        RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.selectionPollSeconds))
    }

    @MainActor
    func moveFocusToModeContinueButton() {
        XCUIRemote.shared.press(.down)
        RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.selectionPollSeconds))
    }

    @MainActor
    func moveFocusToPeopleCard() {
        XCUIRemote.shared.press(.right)
        RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.snapshotPollSeconds))
    }

    @MainActor
    func moveFocusToBackButton() {
        XCUIRemote.shared.press(.right)
        RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.selectionPollSeconds))
        XCUIRemote.shared.press(.right)
        RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.selectionPollSeconds))
        XCUIRemote.shared.press(.down)
        RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.selectionPollSeconds))
    }

    @MainActor
    func moveFocusToStartButton() {

        moveFocusToBackButton()
        XCUIRemote.shared.press(.up)
        RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.selectionPollSeconds))
    }

    @MainActor
    func openAlbumFilter(from app: XCUIApplication) {
        let albumButton = app.buttons["filterSummary.album.button"]
        XCTAssertTrue(albumButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    func openPersonFilter(from app: XCUIApplication) {
        let peopleButton = app.buttons["filterSummary.person.button"]
        XCTAssertTrue(peopleButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))
        XCUIRemote.shared.press(.right)
        RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.transitionPollSeconds))
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    func waitForAlbumFilterReady(app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let backButton = app.buttons["albumFilter.back.button"]
        XCTAssertTrue(
            backButton.waitForExistence(timeout: WaitTiming.screenTransitionTimeoutSeconds),
            "Album filter page should show the back button", file: file,
            line: line)
        let firstAlbumCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "albumFilter.album.")
        ).firstMatch
        XCTAssertTrue(
            firstAlbumCard.waitForExistence(timeout: WaitTiming.screenTransitionTimeoutSeconds),
            "Album filter page should render at least one focusable card",
            file: file, line: line)
    }

    @MainActor
    func waitForPersonFilterReady(app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let backButton = app.buttons["personFilter.back.button"]
        XCTAssertTrue(
            backButton.waitForExistence(timeout: WaitTiming.screenTransitionTimeoutSeconds),
            "Person filter page should show the back button", file: file,
            line: line)
        let firstPersonCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "personFilter.person.")
        ).firstMatch
        XCTAssertTrue(
            firstPersonCard.waitForExistence(timeout: WaitTiming.screenTransitionTimeoutSeconds),
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
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "Album filter page should focus the first card by default before the scroll-to-bottom screenshot"
        )

        var lastFocusedIndex = focusedAlbumCardIndex(in: app) ?? 0
        var stableMoveCount = 0

        for _ in 0..<maxSteps {
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.albumFocusSettleSeconds))

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
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.pollIntervalSeconds))
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
            readinessLabel.waitForExistence(timeout: WaitTiming.screenTransitionTimeoutSeconds),
            "A readable UI test readiness marker should be exposed: \(identifier)", file: file, line: line)

        waitForFocusVisualSettle(seconds: 1.2)
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
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.pollIntervalSeconds))
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
            timeout: WaitTiming.screenTransitionTimeoutSeconds,
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

    private func manifestField(_ key: String, in manifest: String) -> String? {
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
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.pollIntervalSeconds))
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
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.shortFocusSettleSeconds))
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
            digitOneButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "\(operationName): the opened PIN sheet should show the number pad",
            file: file,
            line: line
        )

        waitForButtonToGainFocus(
            digitOneButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "\(operationName): when the PIN sheet opens, default focus should be on digit 1",
            file: file,
            line: line
        )

        for _ in 0..<AccessProtection.pinDigitCount {
            XCUIRemote.shared.press(.select)
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.focusPollSeconds))
        }

        waitForElementToDisappear(
            closeButton,
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "\(operationName): after 6 digits are entered, the PIN sheet should close on its own",
            file: file,
            line: line
        )
    }

    func settingsControlCandidates(app: XCUIApplication, identifier: String) -> [XCUIElement] {

        [
            app.buttons[identifier],
            app.otherElements[identifier],
            app.staticTexts[identifier],
            app.textFields[identifier],
            app.secureTextFields[identifier]
        ]
    }

    func waitForElementWithLabelExists(
        app: XCUIApplication,
        label: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {

            // ui-label-lookup: This helper is reserved for assertions about displayed copy and localization.
            if app.buttons[label].exists
                // ui-label-lookup: This helper is reserved for assertions about displayed copy and localization.
                || app.otherElements[label].exists
                // ui-label-lookup: This helper is reserved for assertions about displayed copy and localization.
                || app.staticTexts[label].exists
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                || app.alerts[label].exists
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                || app.alerts.buttons[label].exists
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                || app.alerts.staticTexts[label].exists
            {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.pollIntervalSeconds))
        }
        // ui-label-lookup: This helper is reserved for assertions about displayed copy and localization.
        return app.buttons[label].exists
            // ui-label-lookup: This helper is reserved for assertions about displayed copy and localization.
            || app.otherElements[label].exists
            // ui-label-lookup: This helper is reserved for assertions about displayed copy and localization.
            || app.staticTexts[label].exists
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            || app.alerts[label].exists
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            || app.alerts.buttons[label].exists
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            || app.alerts.staticTexts[label].exists
    }

    @MainActor
    func assertTVOSServerSettingsAPIKeyHelpSheet(
        app: XCUIApplication,
        context: String,
        shouldVerifySimplifiedChineseContent: Bool = false,
        screenshotName: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        _ = waitForSettingsControl(
            app: app,
            identifier: "server.apiKey.help.button",
            timeout: WaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "\(context) should show the API Key help entry",
            file: file,
            line: line
        )

        let sheet = app.descendants(matching: .any)["server.apiKey.help.sheet"]
        // Focus starts on the server URL: API Key -> Test Connection -> Help.

        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.22)
        XCUIRemote.shared.press(.left)
        waitForFocusVisualSettle(seconds: 0.22)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            sheet.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "\(context) should open the API Key help sheet after the help entry is selected", file: file, line: line)
        if shouldVerifySimplifiedChineseContent {
            let title = app.staticTexts["server.apiKey.help.sheet"]
            let stepsTitle = app.staticTexts["server.apiKey.help.section.list.number.title"]
            let permissionsTitle = app.staticTexts["server.apiKey.help.section.checklist.title"]
            let securityTitle = app.staticTexts["server.apiKey.help.section.key.fill.title"]
            XCTAssertTrue(
                title.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
                "\(context) help sheet should show the title", file: file, line: line)
            // ui-label-lookup: These assertions verify translated help copy after identifier lookup.
            XCTAssertEqual(title.label, "如何创建 Immich API Key", file: file, line: line)
            XCTAssertTrue(
                stepsTitle.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
                "\(context) help sheet should show the creation steps",
                file: file, line: line)
            XCTAssertEqual(stepsTitle.label, "创建步骤", file: file, line: line)
            XCTAssertTrue(
                permissionsTitle.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
                "\(context) help sheet should show the permissions section",
                file: file, line: line)
            XCTAssertEqual(permissionsTitle.label, "需要勾选的权限", file: file, line: line)
            if !securityTitle.waitForExistence(timeout: WaitTiming.briefElementTimeoutSeconds) {
                XCUIRemote.shared.press(.down)
                waitForFocusVisualSettle(seconds: 0.22)
            }
            XCTAssertTrue(
                securityTitle.waitForExistence(timeout: WaitTiming.readbackTimeoutSeconds),
                "\(context) help sheet should show the security reminder",
                file: file, line: line)
            XCTAssertEqual(securityTitle.label, "安全提醒", file: file, line: line)
        }

        if let screenshotName {
            attachScreenshot(app: app, name: screenshotName)
        }

        _ = waitForSettingsControl(
            app: app,
            identifier: "server.apiKey.help.close.button",
            timeout: WaitTiming.shortInteractionTimeoutSeconds,
            failureMessage: "\(context) help sheet should have a close button",
            file: file,
            line: line
        )
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(
            sheet.waitForExistence(timeout: WaitTiming.briefElementTimeoutSeconds),
            "\(context) should not stay on the help sheet after closing",
            file: file, line: line)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "firstboot.serverURL.row", timeout: WaitTiming.shortInteractionTimeoutSeconds)
                || waitForSettingsControlExists(
                    app: app, identifier: "firstboot.serverURL.field",
                    timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "\(context) should return to the server settings form after closing the help sheet",
            file: file,
            line: line
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app, identifier: "firstboot.apiKey.row", timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "\(context) should return to the API Key input row after closing the help sheet",
            file: file,
            line: line
        )
    }

    func waitForSettingsControlExists(
        app: XCUIApplication,
        identifier: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if settingsControlCandidates(app: app, identifier: identifier).contains(where: \.exists) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.pollIntervalSeconds))
        }
        return settingsControlCandidates(app: app, identifier: identifier).contains(where: \.exists)
    }

    func waitForSettingsControl(
        app: XCUIApplication,
        identifier: String,
        timeout: TimeInterval,
        failureMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let matchedElement = settingsControlCandidates(app: app, identifier: identifier).first(where: \.exists) {
                return matchedElement
            }
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.pollIntervalSeconds))
        }

        XCTFail(failureMessage, file: file, line: line)
        return app.otherElements[identifier]
    }

    func attachScreenshot(app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        saveRuntimeScreenshot(screenshot, name: name)
    }

    func saveRuntimeScreenshot(_ screenshot: XCUIScreenshot, name: String) {

        let directory = URL(fileURLWithPath: "/private/tmp/immichSlides_Screenshots")
        let safeName = name.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let fileURL = directory.appendingPathComponent("\(safeName).png")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: fileURL, options: .atomic)
        } catch {
            XCTFail("Failed to write runtime screenshot: \(fileURL.path), error: \(error.localizedDescription)")
        }
    }

    func assertModeSelectionInlineOnboardingHeader(
        app: XCUIApplication,
        expectedModeSelectionOnboardingTitles: [String] = ["首次设置向导", "Setup Wizard"],
        expectedModeSelectionPageTitles: [String] = ["选择播放方式", "Choose Playback Mode"]
    ) {

        let onboardingTitle = app.staticTexts["mode.onboarding.title"]
        XCTAssertTrue(
            onboardingTitle.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "Mode selection page should keep using the minimal capsule to show the user is still in first-time setup")
        assertText(
            onboardingTitle.label,
            matchesAnyOf: expectedModeSelectionOnboardingTitles,
            failureMessage:
                "The wizard capsule at the top left of the mode selection page should show the correct localized title"
        )
        assertOnboardingCapsuleIsTopLeading(onboardingTitle, pageName: "Mode selection page")

        let pageTitle = app.staticTexts["mode.page.title"]
        XCTAssertTrue(
            pageTitle.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "Mode selection main title should describe this step's task, not repeat the wizard capsule's flow level"
        )
        assertText(
            pageTitle.label,
            matchesAnyOf: expectedModeSelectionPageTitles,
            failureMessage: "The mode selection page main title should show the task title for the current language"
        )
    }

    func assertFilterSummaryMinimalOnboardingHeader(
        app: XCUIApplication,
        expectedFilterSummaryOnboardingTitles: [String] = ["首次设置向导", "Setup Wizard"],
        expectedFilterSummaryPageTitles: [String] = ["设置照片范围", "Set Photo Range"]
    ) {

        let onboardingTitle = app.staticTexts["filterSummary.onboarding.title"]
        XCTAssertTrue(
            onboardingTitle.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "Filter summary page should show the minimal capsule to indicate the user is still in first-time setup")
        assertText(
            onboardingTitle.label,
            matchesAnyOf: expectedFilterSummaryOnboardingTitles,
            failureMessage:
                "The wizard capsule at the top left of the filter summary page should show the correct localized title"
        )
        assertOnboardingCapsuleIsTopLeading(onboardingTitle, pageName: "Filter summary page")

        let pageTitle = app.staticTexts["filterSummary.page.title"]
        XCTAssertTrue(
            pageTitle.waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "Filter summary main title should describe this step's task, not repeat the top-left wizard's meaning"
        )
        assertText(
            pageTitle.label,
            matchesAnyOf: expectedFilterSummaryPageTitles,
            failureMessage: "The filter summary page main title should show the task title for the current language"
        )
    }

    func expectedLocalizedTextCandidates(
        languageCode: String?,
        chinese: String,
        english: String
    ) -> [String] {

        switch languageCode {
        case "en":
            return [english]
        case "ja", "ja_JP", "ja-JP":
            return japaneseTextCandidates(for: chinese)
        case "es", "es_ES", "es-ES":
            return spanishTextCandidates(for: chinese)
        case let code? where code.hasPrefix("zh-Hant"):
            return traditionalChineseTextCandidates(for: chinese)
        case "zh", "zh-Hans", "zh_CN", "zh-CN":
            return [chinese]
        default:
            return [chinese, english]
        }
    }

    func traditionalChineseTextCandidates(for simplifiedText: String) -> [String] {

        switch simplifiedText {
        case "首次设置向导":
            return ["首次設定精靈"]
        case "选择播放方式":
            return ["選擇播放方式"]
        case "设置照片范围":
            return ["設定相片範圍", "設定照片範圍"]
        default:
            return [simplifiedText]
        }
    }

    func japaneseTextCandidates(for simplifiedText: String) -> [String] {

        switch simplifiedText {
        case "首次设置向导":
            return ["初期設定ウィザード"]
        case "选择播放方式":
            return ["再生方法を選択"]
        case "设置照片范围":
            return ["写真範囲を設定"]
        default:
            return [simplifiedText]
        }
    }

    func spanishTextCandidates(for simplifiedText: String) -> [String] {

        switch simplifiedText {
        case "首次设置向导":
            return ["Asistente inicial"]
        case "选择播放方式":
            return ["Elegir modo de reproducción"]
        case "设置照片范围":
            return ["Rango de fotos"]
        default:
            return [simplifiedText]
        }
    }

    func assertText(
        _ actualText: String,
        matchesAnyOf expectedTexts: [String],
        failureMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            expectedTexts.contains(actualText),
            "\(failureMessage). Got: \(actualText), allowed: \(expectedTexts.joined(separator: " / "))",
            file: file,
            line: line
        )
    }

    func assertOnboardingCapsuleIsTopLeading(_ element: XCUIElement, pageName: String) {

        XCTAssertLessThan(
            element.frame.minX, CapsuleGeometry.maximumLeadingPositionPoints,
            "\(pageName): the first-time setup capsule should stay inside the top-left safe area")
        XCTAssertLessThan(
            element.frame.minY, CapsuleGeometry.maximumTopPositionPoints,
            "\(pageName): the first-time setup capsule should stay inside the top-left safe area")
    }

    @MainActor
    func waitForFocusVisualSettle(seconds: TimeInterval = 0.45) {

        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    func waitForPlaybackEntryHintAnimationToSettle() {

        waitForFocusVisualSettle(seconds: 1.2)
    }
}
#endif
