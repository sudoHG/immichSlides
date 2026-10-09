//
//  FilterSummaryIOSVisualUITests.swift
//  immichSlidesUITests
//
//  iOS FilterSummary runtime visual audit
//

import Foundation
import XCTest

enum FilterSummaryIOSVisualUITestsCalibration {
    static let maximumTipGapPoints: CGFloat = 12
    static let titlePositionTolerancePoints: CGFloat = 12
    static let singleLineBannerHeightFraction: CGFloat = 0.46
}

enum FilterSummaryIOSVisualUITestsWaitTiming {
    // Resolve infrastructure budgets once before passing them to the existing polling helpers.
    static let briefElementTimeoutSeconds = TestWait.seconds(.infrastructure(1))
    static let connectionTimeoutSeconds = TestWait.seconds(.infrastructure(15))
    static let controlAppearanceTimeoutSeconds = TestWait.seconds(.infrastructure(8))
    static let elementAppearanceTimeoutSeconds = TestWait.seconds(.infrastructure(5))
    static let navigationTimeoutSeconds = TestWait.seconds(.infrastructure(10))
    static let playbackControlTimeoutSeconds = TestWait.seconds(.infrastructure(20))
    static let readbackTimeoutSeconds = TestWait.seconds(.infrastructure(2))
    static let screenTransitionTimeoutSeconds = TestWait.seconds(.infrastructure(12))
    static let settingsChangeTimeoutSeconds = TestWait.seconds(.infrastructure(6))
    static let stateChangeTimeoutSeconds = TestWait.seconds(.infrastructure(4))

    // Opening the licenses page is a responsiveness promise, independent of runner speed.
    static let shortInteractionTimeoutSeconds = TestWait.seconds(.product(3))

    // Poll cadence and screenshot settling spans stay fixed when infrastructure budgets scale.
    static let controlSettleSeconds = TestWait.seconds(.product(0.35))
    static let playbackEntrySettleSeconds = TestWait.seconds(.product(0.6))
    static let pollIntervalSeconds = TestWait.seconds(.product(0.1))
    static let readbackPollSeconds = TestWait.seconds(.product(0.2))
    static let screenSettleSeconds = TestWait.seconds(.product(0.8))
    static let selectionPollSeconds = TestWait.seconds(.product(0.25))
    static let snapshotPollSeconds = TestWait.seconds(.product(0.5))
    static let transitionPollSeconds = TestWait.seconds(.product(0.4))
}

#if os(iOS)
final class FilterSummaryIOSVisualUITests: XCTestCase {
    let exifSamplingOverlayDiagnosticRunFlag = "IMMICHSLIDES_RUN_EXIF_SAMPLING_DIAGNOSTIC"

    struct LocalizedAcceptanceLocale {
        let screenshotPrefix: String
        let languageCode: String
        let localeIdentifier: String
        let wizardTitle: String
        let firstBootTitle: String
        let modeSelectionTitle: String
        let filterSummaryTitle: String
        let playbackSettingsTitle: String
        let accessProtectionDisabledTitle: String
        let appInfoTitle: String
        let privacyPolicyTitle: String
        let filterEditorTitle: String
        let albumFilterTitle: String
        let personFilterTitle: String
        let openSourceTitle: String

        static let hongKong = LocalizedAcceptanceLocale(
            screenshotPrefix: "zh-Hant-HK",
            languageCode: "zh-Hant-HK",
            localeIdentifier: "zh_HK",
            wizardTitle: "首次設定精靈",
            firstBootTitle: "連線到 Immich 伺服器",
            modeSelectionTitle: "選擇播放方式",
            filterSummaryTitle: "設定相片範圍",
            playbackSettingsTitle: "播放設定",
            accessProtectionDisabledTitle: "目前狀態：未開啟",
            appInfoTitle: "App 資訊",
            privacyPolicyTitle: "私隱政策",
            filterEditorTitle: "編輯篩選條件",
            albumFilterTitle: "篩選相簿",
            personFilterTitle: "篩選人物",
            openSourceTitle: "開源授權"
        )

        static let taiwan = LocalizedAcceptanceLocale(
            screenshotPrefix: "zh-Hant-TW",
            languageCode: "zh-Hant-TW",
            localeIdentifier: "zh_TW",
            wizardTitle: "首次設定精靈",
            firstBootTitle: "連線到 Immich 伺服器",
            modeSelectionTitle: "選擇播放方式",
            filterSummaryTitle: "設定照片範圍",
            playbackSettingsTitle: "播放設定",
            accessProtectionDisabledTitle: "目前狀態：未開啟",
            appInfoTitle: "App 資訊",
            privacyPolicyTitle: "隱私權政策",
            filterEditorTitle: "編輯篩選條件",
            albumFilterTitle: "篩選相簿",
            personFilterTitle: "篩選人物",
            openSourceTitle: "開源授權"
        )

        static let japanese = LocalizedAcceptanceLocale(
            screenshotPrefix: "ja",
            languageCode: "ja",
            localeIdentifier: "ja_JP",
            wizardTitle: "初期設定ウィザード",
            firstBootTitle: "Immich サーバーに接続",
            modeSelectionTitle: "再生方法を選択",
            filterSummaryTitle: "写真範囲を設定",
            playbackSettingsTitle: "再生設定",
            accessProtectionDisabledTitle: "ステータス: オフ",
            appInfoTitle: "App 情報",
            privacyPolicyTitle: "プライバシーポリシー",
            filterEditorTitle: "フィルターを編集",
            albumFilterTitle: "アルバムをフィルター",
            personFilterTitle: "人物をフィルター",
            openSourceTitle: "オープンソースライセンス"
        )

        static let spanish = LocalizedAcceptanceLocale(
            screenshotPrefix: "es",
            languageCode: "es",
            localeIdentifier: "es_ES",
            wizardTitle: "Asistente inicial",
            firstBootTitle: "Conectar al servidor Immich",
            modeSelectionTitle: "Elegir modo de reproducción",
            filterSummaryTitle: "Rango de fotos",
            playbackSettingsTitle: "Ajustes de reproducción",
            accessProtectionDisabledTitle: "Estado: inactivo",
            appInfoTitle: "Información de la app",
            privacyPolicyTitle: "Política de privacidad",
            filterEditorTitle: "Editar filtros",
            albumFilterTitle: "Filtrar álbumes",
            personFilterTitle: "Filtrar personas",
            openSourceTitle: "Licencias de código abierto"
        )
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try requireIOSDestination()

        XCUIDevice.shared.orientation = .portrait
    }

    func isEnvironmentFlagEnabled(_ name: String) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let rawValue = env[name] ?? env["TEST_RUNNER_\(name)"] else {
            return false
        }
        let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["1", "true", "yes"].contains(normalizedValue)
    }

    @MainActor
    func testIOSFirstBootOnboardingHeaderScreenshot() throws {

        let app = launchIntoOnboardingFirstBoot(colorScheme: "dark")

        assertOnboardingHeader(
            app: app,
            expectedPageTitle: "连接 Immich 服务器",
            pageTitleIdentifier: "firstboot.page.title"
        )

        attachScreenshot(app: app, name: "ios-firstboot-onboarding-\(currentDeviceTag())")
    }

    @MainActor
    func testIOSFirstBootDebugFillConfigButtonFillsFieldsWhenEnabled() throws {

        let app = launchIntoOnboardingFirstBoot(
            colorScheme: "dark",
            shouldDisableDebugFillConfigButton: false
        )
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After resetting state, the app should return to the first-launch server setup page.")

        guard
            let fillButton = waitForDebugFillConfigElement(
                in: app, timeout: FilterSummaryIOSVisualUITestsWaitTiming.stateChangeTimeoutSeconds)
        else {
            attachScreenshot(app: app, name: "ios-firstboot-debug-fill-missing-\(currentDeviceTag())")
            throw XCTSkip("This build does not show the debug fill button; skipping the tap check.")
        }

        let expectedServerURL =
            ProcessInfo.processInfo.environment["EXPECTED_DEBUG_FILL_SERVER_URL"]
            ?? TestServerConfiguration.current?.serverURL
            ?? "https://debug.example.com/api"

        fillButton.tap()

        // Boolean compare: a failure must not print the expected URL, which can come from private configuration.
        XCTAssertTrue(
            (serverField.value as? String) == expectedServerURL,
            "The debug fill button should fill the expected server URL."
        )

        let apiField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiField.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.stateChangeTimeoutSeconds))
        let apiFieldValue = apiField.value as? String ?? ""
        XCTAssertFalse(
            apiFieldValue.isEmpty, "After tapping the debug button, the API Key field should no longer be empty.")
        XCTAssertNotEqual(
            apiFieldValue, "请输入 API Key",
            "After tapping the debug button, the API Key field should no longer show the placeholder text.")

        attachScreenshot(app: app, name: "ios-firstboot-debug-fill-after-tap-\(currentDeviceTag())")
    }

    @MainActor
    func testIOSFirstBootOnboardingHeaderScreenshotLight() throws {

        let app = launchIntoOnboardingFirstBoot(colorScheme: "light")

        assertOnboardingHeader(
            app: app,
            expectedPageTitle: "连接 Immich 服务器",
            pageTitleIdentifier: "firstboot.page.title"
        )

        attachScreenshot(app: app, name: "ios-firstboot-onboarding-light-\(currentDeviceTag())")
    }

    @MainActor
    func testIOSFirstBootOnboardingHeaderScreenshotAccessibility() throws {

        let app = launchIntoOnboardingFirstBoot(
            colorScheme: "dark",
            dynamicTypeSize: "accessibility5"
        )

        assertOnboardingHeader(
            app: app,
            expectedPageTitle: "连接 Immich 服务器",
            pageTitleIdentifier: "firstboot.page.title"
        )

        attachScreenshot(
            app: app,
            name: "ios-firstboot-onboarding-accessibility-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSFirstBootOnboardingHeaderScreenshotLandscape() throws {

        defer { XCUIDevice.shared.orientation = .portrait }

        let app = launchIntoOnboardingFirstBoot(colorScheme: "dark")
        setOrientation(.landscapeLeft, app: app, waitForTitleIdentifier: "firstboot.page.title")

        assertOnboardingHeader(
            app: app,
            expectedPageTitle: "连接 Immich 服务器",
            pageTitleIdentifier: "firstboot.page.title"
        )

        attachScreenshot(app: app, name: "ios-firstboot-onboarding-landscape-\(currentDeviceTag())")
    }

    @MainActor
    func testIOSModeSelectionOnboardingHeaderScreenshot() throws {

        let app = try launchIntoOnboardingModeSelection(colorScheme: "dark")

        assertOnboardingHeader(
            app: app,
            expectedPageTitle: "选择播放方式",
            pageTitleIdentifier: "mode.page.title"
        )

        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(
            app.buttons["mode.filtered.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))

        attachScreenshot(app: app, name: "ios-mode-selection-onboarding-\(currentDeviceTag())")
    }

    @MainActor
    func testIOSModeSelectionOnboardingHeaderScreenshotLight() throws {

        let app = try launchIntoOnboardingModeSelection(colorScheme: "light")

        assertOnboardingHeader(
            app: app,
            expectedPageTitle: "选择播放方式",
            pageTitleIdentifier: "mode.page.title"
        )

        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(
            app.buttons["mode.filtered.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))

        attachScreenshot(app: app, name: "ios-mode-selection-onboarding-light-\(currentDeviceTag())")
    }

    @MainActor
    func testIOSModeSelectionOnboardingHeaderScreenshotAccessibility() throws {

        let app = try launchIntoOnboardingModeSelection(
            colorScheme: "dark",
            dynamicTypeSize: "accessibility5"
        )

        assertOnboardingHeader(
            app: app,
            expectedPageTitle: "选择播放方式",
            pageTitleIdentifier: "mode.page.title"
        )

        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(
            app.buttons["mode.filtered.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))

        attachScreenshot(
            app: app,
            name: "ios-mode-selection-onboarding-accessibility-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSModeSelectionOnboardingHeaderScreenshotLandscape() throws {

        defer { XCUIDevice.shared.orientation = .portrait }

        let app = try launchIntoOnboardingModeSelection(colorScheme: "dark")
        setOrientation(.landscapeLeft, app: app, waitForTitleIdentifier: "mode.page.title")

        assertOnboardingHeader(
            app: app,
            expectedPageTitle: "选择播放方式",
            pageTitleIdentifier: "mode.page.title"
        )

        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(
            app.buttons["mode.filtered.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))

        attachScreenshot(app: app, name: "ios-mode-selection-onboarding-landscape-\(currentDeviceTag())")
    }

    @MainActor
    func testIOSFilterSummaryOnboardingHeaderScreenshot() throws {

        let app = try launchIntoOnboardingFilterSummary(colorScheme: "dark")
        assertOnboardingHeader(
            app: app,
            expectedPageTitle: "设置照片范围",
            pageTitleIdentifier: "filterSummary.page.title"
        )

        attachScreenshot(app: app, name: "ios-filter-summary-onboarding-\(currentDeviceTag())")
    }

    @MainActor
    func testIOSFilterSummaryOnboardingHeaderScreenshotLight() throws {

        let app = try launchIntoOnboardingFilterSummary(colorScheme: "light")
        assertOnboardingHeader(
            app: app,
            expectedPageTitle: "设置照片范围",
            pageTitleIdentifier: "filterSummary.page.title"
        )

        attachScreenshot(app: app, name: "ios-filter-summary-onboarding-light-\(currentDeviceTag())")
    }

    @MainActor
    func testIOSFilterSummaryOnboardingHeaderScreenshotAccessibility() throws {

        let app = try launchIntoOnboardingFilterSummary(
            colorScheme: "dark",
            dynamicTypeSize: "accessibility5"
        )
        assertOnboardingHeader(
            app: app,
            expectedPageTitle: "设置照片范围",
            pageTitleIdentifier: "filterSummary.page.title"
        )

        attachScreenshot(
            app: app,
            name: "ios-filter-summary-onboarding-accessibility-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSFilterSummaryOnboardingHeaderScreenshotLandscape() throws {

        defer { XCUIDevice.shared.orientation = .portrait }

        let app = try launchIntoOnboardingFilterSummary(colorScheme: "dark")
        setOrientation(.landscapeLeft, app: app, waitForTitleIdentifier: "filterSummary.page.title")

        assertOnboardingHeader(
            app: app,
            expectedPageTitle: "设置照片范围",
            pageTitleIdentifier: "filterSummary.page.title"
        )

        attachScreenshot(app: app, name: "ios-filter-summary-onboarding-landscape-\(currentDeviceTag())")
    }

    @MainActor
    func testIOSOnboardingMainTitleFramesStayAlignedPortrait() throws {

        let firstBootApp = launchIntoOnboardingFirstBoot(colorScheme: "dark")
        let firstBootTitleFrame = titleFrame(
            app: firstBootApp,
            identifier: "firstboot.page.title"
        )
        firstBootApp.terminate()

        let modeSelectionApp = try launchIntoOnboardingModeSelection(colorScheme: "dark")
        let modeTitleFrame = titleFrame(
            app: modeSelectionApp,
            identifier: "mode.page.title"
        )
        modeSelectionApp.terminate()

        let filterSummaryApp = try launchIntoOnboardingFilterSummary(colorScheme: "dark")
        let filterTitleFrame = titleFrame(
            app: filterSummaryApp,
            identifier: "filterSummary.page.title"
        )
        filterSummaryApp.terminate()

        assertTitleFrame(
            modeTitleFrame,
            alignsWith: firstBootTitleFrame,
            pageName: "Mode selection page"
        )
        assertTitleFrame(
            filterTitleFrame,
            alignsWith: firstBootTitleFrame,
            pageName: "Filter summary page"
        )
    }

    @MainActor
    func testIOSFilterSummaryVisualScreenshot() throws {
        let app = try launchIntoFilterSummary(colorScheme: "dark")

        waitForReadinessMarker(app: app, identifier: "filterSummary.visual.ready")
        attachScreenshot(app: app, name: "ios-filter-summary-visual")
    }

    @MainActor
    func testIOSFilterSummaryVisualScreenshotLight() throws {
        let app = try launchIntoFilterSummary(colorScheme: "light")

        waitForReadinessMarker(app: app, identifier: "filterSummary.visual.ready")
        attachScreenshot(app: app, name: "ios-filter-summary-visual-light")
    }

    // iPhone portrait baseline: check first for squeezed buttons or a covered title.

    @MainActor
    func testIOSFilterSummaryVisualScreenshotIPhonePortrait() throws {
        let app = try launchIntoFilterSummary(colorScheme: "dark")

        setOrientation(.portrait, app: app)
        waitForReadinessMarker(app: app, identifier: "filterSummary.visual.ready")
        attachScreenshot(app: app, name: "ios-filter-summary-visual-iphone-portrait")
    }

    // iPhone landscape baseline: most likely to expose problems from compressing the layout the iPad way.

    @MainActor
    func testIOSFilterSummaryVisualScreenshotIPhoneLandscape() throws {
        let app = try launchIntoFilterSummary(colorScheme: "dark")

        setOrientation(.landscapeLeft, app: app)
        waitForReadinessMarker(app: app, identifier: "filterSummary.visual.ready")
        attachScreenshot(app: app, name: "ios-filter-summary-visual-iphone-landscape")
    }

    @MainActor
    func testIOSFilterEditorVisualScreenshot() throws {
        let app = try launchIntoFilterEditor(colorScheme: "dark")
        attachScreenshot(app: app, name: "ios-filter-editor-visual-\(currentDeviceTag())")
    }

    @MainActor
    func testIOSFilterEditorVisualScreenshotLight() throws {
        let app = try launchIntoFilterEditor(colorScheme: "light")
        attachScreenshot(app: app, name: "ios-filter-editor-visual-light-\(currentDeviceTag())")
    }

    @MainActor
    func testIOSFilterEditorVisualScreenshotAccessibility() throws {
        let app = try launchIntoFilterEditor(
            colorScheme: "dark",
            dynamicTypeSize: "accessibility5"
        )
        attachScreenshot(app: app, name: "ios-filter-editor-visual-accessibility-\(currentDeviceTag())")
    }

    @MainActor
    func testIOSFilterEditorVisualScreenshotLandscape() throws {
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = try launchIntoFilterEditor(colorScheme: "dark")
        setOrientation(.landscapeLeft, app: app, waitForTitleIdentifier: "filterEditor.page.title")
        attachScreenshot(app: app, name: "ios-filter-editor-visual-landscape-\(currentDeviceTag())")
    }

    @MainActor
    func testIOSAlbumFilterTopBarIPhonePortraitScreenshotDark() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom == .pad,
            "The iPhone portrait top bar visual subset does not apply to iPad; the core iPad filter tests still run separately."
        )
        let app = try launchIntoAlbumFilterPage(
            colorScheme: "dark",
            dynamicTypeSize: nil
        )

        assertCompactPhoneFilterTopBar(
            app: app,
            expectedTitle: "筛选相册",
            filterPageIdentifierPrefix: "albumFilter"
        )
        attachScreenshot(app: app, name: "ios-album-filter-topbar-iphone-portrait-dark")
    }

    @MainActor
    func testIOSAlbumFilterTopBarIPhonePortraitScreenshotLight() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom == .pad,
            "The iPhone portrait top bar visual subset does not apply to iPad; the core iPad filter tests still run separately."
        )
        let app = try launchIntoAlbumFilterPage(
            colorScheme: "light",
            dynamicTypeSize: nil
        )

        assertCompactPhoneFilterTopBar(
            app: app,
            expectedTitle: "筛选相册",
            filterPageIdentifierPrefix: "albumFilter"
        )
        attachScreenshot(app: app, name: "ios-album-filter-topbar-iphone-portrait-light")
    }

    @MainActor
    func testIOSAlbumFilterTopBarIPhonePortraitScreenshotAccessibility() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom == .pad,
            "The iPhone portrait top bar visual subset does not apply to iPad; the core iPad filter tests still run separately."
        )
        let app = try launchIntoAlbumFilterPage(
            colorScheme: "dark",
            dynamicTypeSize: "accessibility5"
        )

        assertCompactPhoneFilterTopBar(
            app: app,
            expectedTitle: "筛选相册",
            filterPageIdentifierPrefix: "albumFilter"
        )
        attachScreenshot(app: app, name: "ios-album-filter-topbar-iphone-portrait-accessibility")
    }

    @MainActor
    func testIOSPersonFilterTopBarIPhonePortraitScreenshotDark() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom == .pad,
            "The iPhone portrait top bar visual subset does not apply to iPad; the core iPad filter tests still run separately."
        )
        let app = try launchIntoPersonFilterPage(
            colorScheme: "dark",
            dynamicTypeSize: nil
        )

        assertCompactPhoneFilterTopBar(
            app: app,
            expectedTitle: "筛选人物",
            filterPageIdentifierPrefix: "personFilter"
        )
        attachScreenshot(app: app, name: "ios-person-filter-topbar-iphone-portrait-dark")
    }

    @MainActor
    func testIOSPersonFilterTopBarIPhonePortraitScreenshotLight() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom == .pad,
            "The iPhone portrait top bar visual subset does not apply to iPad; the core iPad filter tests still run separately."
        )
        let app = try launchIntoPersonFilterPage(
            colorScheme: "light",
            dynamicTypeSize: nil
        )

        assertCompactPhoneFilterTopBar(
            app: app,
            expectedTitle: "筛选人物",
            filterPageIdentifierPrefix: "personFilter"
        )
        attachScreenshot(app: app, name: "ios-person-filter-topbar-iphone-portrait-light")
    }

    @MainActor
    func testIOSPersonFilterTopBarIPhonePortraitScreenshotAccessibility() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom == .pad,
            "The iPhone portrait top bar visual subset does not apply to iPad; the core iPad filter tests still run separately."
        )
        let app = try launchIntoPersonFilterPage(
            colorScheme: "dark",
            dynamicTypeSize: "accessibility5"
        )

        assertCompactPhoneFilterTopBar(
            app: app,
            expectedTitle: "筛选人物",
            filterPageIdentifierPrefix: "personFilter"
        )
        attachScreenshot(app: app, name: "ios-person-filter-topbar-iphone-portrait-accessibility")
    }
}

extension XCUIElement {
    func filterSummaryIOSVisualUITestsClearAndType(text: String) {

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
