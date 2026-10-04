//
//  FilterSummaryTVOSVisualUITests.swift
//  immichSlidesUITests
//
//  tvOS UI acceptance: onboarding, FilterSummary, playback, settings, PIN, privacy, licenses, and localization
//

import XCTest

enum FilterSummaryTVOSVisualUITestsCapsuleGeometry {
    static let maximumLeadingPositionPoints: CGFloat = 170
    static let maximumTopPositionPoints: CGFloat = 90
}

enum FilterSummaryTVOSVisualUITestsAccessProtection {
    static let pinDigitCount: Int = 6
}

enum FilterSummaryTVOSVisualUITestsSettingsNavigation {
    static let playbackSteps: Int = 0
    static let accessProtectionSteps: Int = 1
    static let serverSteps: Int = 2
    static let cacheSteps: Int = 3
    static let aboutSteps: Int = 4
}

enum FilterSummaryTVOSVisualUITestsWaitTiming {
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
            singularAlbumSummary.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Spanish summary for a single album should use the singular álbum"
        )
        XCTAssertTrue(
            singularPeopleSummary.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
                app: modeApp, label: locale.modeSelectionTitle,
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
                app: albumApp, label: locale.albumFilterTitle,
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
                app: personApp, label: locale.personFilterTitle,
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.playbackSteps,
            failureMessage: "Localized tvOS settings home should show Playback Settings"
        )
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: settingsApp, label: locale.playbackSettingsTitle,
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS settings home should show the Playback Settings entry"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: settingsApp, name: "\(locale.screenshotPrefix)-tvos-settings-root")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: settingsApp, identifier: "settings.playback.autoPlay.link",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.accessProtectionSteps,
            failureMessage: "Localized tvOS settings home should be able to open Access Protection"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: accessProtectionApp, label: locale.accessProtectionDisabledTitle,
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS access protection page should show the disabled state"
        )
        // UI-test mode exposes row values verbatim; they must still be localized, not catalog keys.
        let enableButton = accessProtectionApp.buttons["settings.pin.enable.button"]
        XCTAssertTrue(
            enableButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))
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
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.serverSteps,
            failureMessage: "Localized tvOS settings home should be able to open Server"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: serverApp, identifier: "server.apiKey.help.button",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.cacheSteps,
            failureMessage: "Localized tvOS settings home should be able to open Cache Management"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: cacheApp, identifier: "settings.cache.disk.row",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.aboutSteps,
            failureMessage: "Localized tvOS settings home should be able to open About"
        )
        XCUIRemote.shared.press(.select)

        let appInfoSection = waitForSettingsControl(
            app: aboutApp,
            identifier: "settings.about.appInfo.section",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page should show the App Info section"
        )
        waitForButtonToGainFocus(
            appInfoSection,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page default focus should land on App Info"
        )
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: aboutApp, label: locale.appInfoTitle,
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS About page should show the target locale text"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: aboutApp, name: "\(locale.screenshotPrefix)-tvos-settings-about")

        let privacyPolicyLink = waitForSettingsControl(
            app: aboutApp,
            identifier: "settings.about.privacyPolicy.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page should show the Privacy Policy entry"
        )
        for _ in 0..<3 {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.22)
        }
        waitForButtonToGainFocus(
            privacyPolicyLink,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page should let focus move to Privacy Policy"
        )
        attachScreenshot(app: aboutApp, name: "\(locale.screenshotPrefix)-tvos-settings-about-bottom")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: aboutApp, identifier: "settings.about.privacyPolicy.section.0",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.aboutSteps,
            failureMessage: "Localized tvOS settings home should be able to open About again"
        )
        XCUIRemote.shared.press(.select)

        let openSourceAppInfoSection = waitForSettingsControl(
            app: openSourceApp,
            identifier: "settings.about.appInfo.section",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page should show the App Info section"
        )
        waitForButtonToGainFocus(
            openSourceAppInfoSection,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page default focus should land on App Info"
        )

        let openSourceLink = waitForSettingsControl(
            app: openSourceApp,
            identifier: "settings.about.opensource.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page should show the Open Source Licenses entry"
        )
        for _ in 0..<4 {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.22)
        }
        waitForButtonToGainFocus(
            openSourceLink,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Localized tvOS About page should let focus move to Open Source Licenses"
        )
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForElementWithLabelExists(
                app: openSourceApp, label: locale.openSourceTitle,
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Localized tvOS open source licenses page should show the target locale text"
        )
        waitForFocusVisualSettle()
        attachScreenshot(app: openSourceApp, name: "\(locale.screenshotPrefix)-tvos-settings-open-source")
    }
}

#endif
