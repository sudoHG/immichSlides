//
//  FilterSummaryIOSVisualUITests.swift
//  immichSlidesUITests
//
//  iOS FilterSummary runtime visual audit
//

import Foundation
import XCTest

#if os(iOS)
final class FilterSummaryIOSVisualUITests: XCTestCase {
    private let exifSamplingOverlayDiagnosticRunFlag = "IMMICHSLIDES_RUN_EXIF_SAMPLING_DIAGNOSTIC"

    struct LocalizedAcceptanceLocale {
        let screenshotPrefix: String
        let languageCode: String
        let localeIdentifier: String
        let wizardTitle: String
        let firstBootTitle: String
        let modeSelectionTitle: String
        let filterSummaryTitle: String
        let playbackSettingsTitle: String
        let accessProtectionTitle: String
        let accessProtectionDisabledTitle: String
        let serverTitle: String
        let cacheTitle: String
        let aboutTitle: String
        let appInfoTitle: String
        let privacyPolicyTitle: String
        let filterEditorTitle: String
        let albumFilterTitle: String
        let personFilterTitle: String
        let openSourceTitle: String
        let selectAllTitle: String

        static let hongKong = LocalizedAcceptanceLocale(
            screenshotPrefix: "zh-Hant-HK",
            languageCode: "zh-Hant-HK",
            localeIdentifier: "zh_HK",
            wizardTitle: "首次設定精靈",
            firstBootTitle: "連線到 Immich 伺服器",
            modeSelectionTitle: "選擇播放方式",
            filterSummaryTitle: "設定相片範圍",
            playbackSettingsTitle: "播放設定",
            accessProtectionTitle: "存取保護",
            accessProtectionDisabledTitle: "目前狀態：未開啟",
            serverTitle: "伺服器",
            cacheTitle: "快取管理",
            aboutTitle: "關於 App",
            appInfoTitle: "App 資訊",
            privacyPolicyTitle: "私隱政策",
            filterEditorTitle: "編輯篩選條件",
            albumFilterTitle: "篩選相簿",
            personFilterTitle: "篩選人物",
            openSourceTitle: "開源授權",
            selectAllTitle: "全選"
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
            accessProtectionTitle: "存取保護",
            accessProtectionDisabledTitle: "目前狀態：未開啟",
            serverTitle: "伺服器",
            cacheTitle: "快取管理",
            aboutTitle: "關於 App",
            appInfoTitle: "App 資訊",
            privacyPolicyTitle: "隱私權政策",
            filterEditorTitle: "編輯篩選條件",
            albumFilterTitle: "篩選相簿",
            personFilterTitle: "篩選人物",
            openSourceTitle: "開源授權",
            selectAllTitle: "全選"
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
            accessProtectionTitle: "アクセス保護",
            accessProtectionDisabledTitle: "ステータス: オフ",
            serverTitle: "サーバー",
            cacheTitle: "キャッシュ管理",
            aboutTitle: "App情報",
            appInfoTitle: "App 情報",
            privacyPolicyTitle: "プライバシーポリシー",
            filterEditorTitle: "フィルターを編集",
            albumFilterTitle: "アルバムをフィルター",
            personFilterTitle: "人物をフィルター",
            openSourceTitle: "オープンソースライセンス",
            selectAllTitle: "すべて選択"
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
            accessProtectionTitle: "Protección de acceso",
            accessProtectionDisabledTitle: "Estado: inactivo",
            serverTitle: "Servidor",
            cacheTitle: "Gestión de caché",
            aboutTitle: "Acerca de",
            appInfoTitle: "Información de la app",
            privacyPolicyTitle: "Política de privacidad",
            filterEditorTitle: "Editar filtros",
            albumFilterTitle: "Filtrar álbumes",
            personFilterTitle: "Filtrar personas",
            openSourceTitle: "Licencias de código abierto",
            selectAllTitle: "Seleccionar todo"
        )
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try requireIOSDestination()

        XCUIDevice.shared.orientation = .portrait
    }

    func environmentFlagEnabled(_ name: String) -> Bool {
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
            disableDebugFillConfigButton: false
        )
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForExistence(timeout: 8),
            "After resetting state, the app should return to the first-launch server setup page.")

        guard let fillButton = waitForDebugFillConfigElement(in: app, timeout: 4) else {
            attachScreenshot(app: app, name: "ios-firstboot-debug-fill-missing-\(currentDeviceTag())")
            throw XCTSkip("This build does not show the debug fill button; skipping the tap check.")
        }

        let expectedServerURL =
            ProcessInfo.processInfo.environment["EXPECTED_DEBUG_FILL_SERVER_URL"]
            ?? TestServerConfiguration.current?.serverURL
            ?? "https://debug.example.com/api"

        fillButton.tap()

        XCTAssertEqual(serverField.value as? String, expectedServerURL)

        let apiField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiField.waitForExistence(timeout: 4))
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

        XCTAssertTrue(app.buttons["mode.random.button"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["mode.filtered.button"].waitForExistence(timeout: 8))

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

        XCTAssertTrue(app.buttons["mode.random.button"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["mode.filtered.button"].waitForExistence(timeout: 8))

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

        XCTAssertTrue(app.buttons["mode.random.button"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["mode.filtered.button"].waitForExistence(timeout: 8))

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

        XCTAssertTrue(app.buttons["mode.random.button"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["mode.filtered.button"].waitForExistence(timeout: 8))

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

    @MainActor
    func testIOSSlideShowVisualScreenshot() throws {
        let app = try launchIntoSlideShow(colorScheme: "dark")
        attachScreenshot(app: app, name: "ios-slideshow-visual")
    }

    @MainActor
    func testIOSSlideShowVisualScreenshotLight() throws {
        let app = try launchIntoSlideShow(colorScheme: "light")
        attachScreenshot(app: app, name: "ios-slideshow-visual-light")
    }

    @MainActor
    func testIOSExifAlbumDiagnosticScreenshots() throws {
        let photoCount = try requireExifDiagnosticAlbumAssetCount()

        let app = try launchIntoFilterEditor(
            colorScheme: "light",
            forceAutoPlayOff: true,
            prepareFilterEditorVisuals: false
        )

        try configureExifDiagnosticFilters(app: app)

        let doneButton = app.buttons["filter.editor.done.button"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 8), "Filter editor top bar should show the 'Done' button")
        tapElement(doneButton)

        returnToSlideShowFromSettings(app: app)
        captureExifDiagnosticSlides(
            app: app,
            expectedCount: photoCount
        )
    }

    @MainActor
    func testIOSExifAlbumSamplingOverlayDiagnosticScreenshots() throws {
        try XCTSkipIf(
            !environmentFlagEnabled(exifSamplingOverlayDiagnosticRunFlag),
            "EXIF sampling overlay diagnostic screenshots are not part of regular UI regression by default; set \(exifSamplingOverlayDiagnosticRunFlag)=1 to run them explicitly."
        )
        let photoCount = try requireExifDiagnosticAlbumAssetCount()

        let app = try launchIntoFilterEditor(
            colorScheme: "light",
            forceAutoPlayOff: true,
            prepareFilterEditorVisuals: false,
            showExifSamplingDebugOverlay: true
        )

        try configureExifDiagnosticFilters(app: app)

        let doneButton = app.buttons["filter.editor.done.button"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 8), "Filter editor top bar should show the 'Done' button")
        tapElement(doneButton)

        returnToSlideShowFromSettings(app: app)
        captureExifDiagnosticSlides(
            app: app,
            expectedCount: photoCount,
            screenshotNamePrefix: "ios-exif-sampling-overlay-diagnostic",
            waitForSamplingOverlay: true
        )
    }

    @MainActor
    func testIOSSlideShowPlaybackEntryHintScreenshot() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "dark",
            disablePlaybackEntryHint: false
        )

        assertPlaybackEntryHint(
            app: app,
            expectedTitle: "在这里调整照片播放范围和速度",
            expectedAction: "点击 气泡 隐藏提示",
            expectedKeycap: "气泡"
        )

        attachScreenshot(
            app: app,
            name: "ios-slideshow-entry-hint-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSlideShowPlaybackEntryHintScreenshotLight() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "light",
            disablePlaybackEntryHint: false
        )

        assertPlaybackEntryHint(
            app: app,
            expectedTitle: "在这里调整照片播放范围和速度",
            expectedAction: "点击 气泡 隐藏提示",
            expectedKeycap: "气泡"
        )

        attachScreenshot(
            app: app,
            name: "ios-slideshow-entry-hint-light-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSlideShowPlaybackEntryHintScreenshotAccessibility() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "dark",
            dynamicTypeSize: "accessibility5",
            disablePlaybackEntryHint: false
        )

        assertPlaybackEntryHint(
            app: app,
            expectedTitle: "在这里调整照片播放范围和速度",
            expectedAction: "点击 气泡 隐藏提示",
            expectedKeycap: "气泡"
        )

        attachScreenshot(
            app: app,
            name: "ios-slideshow-entry-hint-accessibility-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSlideShowPlaybackEntryHintScreenshotLandscape() throws {
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = try launchIntoSlideShow(
            colorScheme: "dark",
            disablePlaybackEntryHint: false
        )
        setOrientation(
            .landscapeLeft,
            app: app,
            waitForElementIdentifier: "slideshow.control.settings.button"
        )

        assertPlaybackEntryHint(
            app: app,
            expectedTitle: "在这里调整照片播放范围和速度",
            expectedAction: "点击 气泡 隐藏提示",
            expectedKeycap: "气泡"
        )

        attachScreenshot(
            app: app,
            name: "ios-slideshow-entry-hint-landscape-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSlideShowPlaybackEntryHintEnglishScreenshot() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "dark",
            forceEnglishLocalization: true,
            disablePlaybackEntryHint: false
        )

        assertPlaybackEntryHint(
            app: app,
            expectedTitle: "Adjust photo range and speed here",
            expectedAction: "Tap bubble to hide this tip",
            expectedKeycap: "bubble"
        )

        attachScreenshot(
            app: app,
            name: "ios-slideshow-entry-hint-en-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSlideShowPlaybackEntryHintJapaneseScreenshot() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "dark",
            disablePlaybackEntryHint: false,
            acceptanceLocale: .japanese
        )

        assertPlaybackEntryHint(
            app: app,
            expectedTitle: "ここで写真の範囲と速度を調整します",
            expectedAction: "吹き出しをタップしてヒントを閉じます",
            expectedKeycap: "吹き出し"
        )

        attachScreenshot(
            app: app,
            name: "ja-ios-slideshow-entry-hint-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSlideShowPlaybackEntryHintShowsOnlyOncePerOnboardingFlow() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "dark",
            disablePlaybackEntryHint: false
        )
        let entryHintBanner = app.otherElements["slideshow.entryHint.banner"]

        XCTAssertTrue(
            entryHintBanner.waitForExistence(timeout: 6),
            "On first entering the playback page, the one-time tip should appear first"
        )

        openSettingsFromSlideShow(app: app)
        returnToSlideShowFromSettings(app: app)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 18),
            "After returning from settings, the app should be back on the playback page"
        )
        XCTAssertFalse(
            entryHintBanner.waitForExistence(timeout: 2),
            "The one-time tip should not reappear when returning from settings to the playback page in the same first-launch flow"
        )
    }

    @MainActor
    func testIOSSlideShowPlaybackEntryHintDismissesByTappingBubble() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "dark",
            disablePlaybackEntryHint: false
        )
        let entryHintBanner = app.otherElements["slideshow.entryHint.banner"]
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]

        XCTAssertTrue(
            entryHintBanner.waitForExistence(timeout: 6),
            "On first entering the playback page, the one-time tip should appear first"
        )
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: 4), "Playback page should show the play button in the control bar"
        )

        playPauseButton.tap()
        XCTAssertTrue(
            entryHintBanner.waitForExistence(timeout: 1),
            "Tapping a control bar button should not hide the bubble"
        )

        entryHintBanner.tap()
        waitForPlaybackEntryHintToDisappear(entryHintBanner)
        XCTAssertFalse(entryHintBanner.exists, "Tapping the tip bubble itself should hide the bubble")
    }

    @MainActor
    func testIOSSettingsRootLocalizationEnglishScreenshot() throws {

        let app = try launchIntoSlideShow(
            colorScheme: "dark",
            forceEnglishLocalization: true
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
            serverURLField.waitForExistence(timeout: 8), "Server settings page should show the server URL field")
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 8), "Server settings page should show the API Key field")
        XCTAssertTrue(
            testButton.waitForExistence(timeout: 8), "Server settings page should show the 'Test Connection' button")
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 8), "Server settings page should show the 'Save Settings' button")

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
            serverURLField.waitForExistence(timeout: 8), "Server settings page should show the server URL field")
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 8), "Server settings page should show the API Key field")
        XCTAssertTrue(
            testButton.waitForExistence(timeout: 8), "Server settings page should show the 'Test Connection' button")
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 8), "Server settings page should show the 'Save Settings' button")

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
            playbackModePicker.waitForExistence(timeout: 8),
            "Playback settings page should show the default playback mode segmented picker")

        let filteredModeSegment = playbackModePicker.buttons.element(boundBy: 1)
        XCTAssertTrue(
            filteredModeSegment.waitForExistence(timeout: 5),
            "Playback settings page should show the 'Filtered Playback' option")
        tapElement(filteredModeSegment)

        XCTAssertNotNil(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            waitForAnyElement(
                app: app,
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                labels: ["无法切换到筛选播放", "Can't Switch to Filtered Playback"],
                timeout: 8
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
            serverURLField.waitForExistence(timeout: 8), "Server settings page should show the server URL field")
        tapElement(serverURLField)
        serverURLField.clearAndType(text: "foo://invalid-host")

        let testConnectionButton = app.buttons["firstboot.testConnection.button"]
        XCTAssertTrue(
            testConnectionButton.waitForExistence(timeout: 8),
            "Server settings page should show the test connection button")
        dismissKeyboardIfNeeded(app: app)
        tapElement(testConnectionButton)

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let serverErrorAlert = waitForAnyElement(
            app: app,
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            labels: ["连接测试失败", "Connection test failed", "Connection Test Failed"],
            timeout: 8
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
            clearDiskButton.waitForExistence(timeout: 8),
            "Cache management page should show the clear disk cache button")
        tapElement(clearDiskButton)

        XCTAssertNotNil(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            waitForAnyElement(
                app: app,
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                labels: ["确认清理磁盘缓存", "Confirm Disk Cache Clear"],
                timeout: 8
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
        XCTAssertTrue(clearDiskButton.waitForExistence(timeout: 8))
        tapElement(clearDiskButton)
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 8))

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        XCTAssertNil(waitForAnyElement(app: app, labels: ["unrelated alert sentinel"], timeout: 0.2))
        XCTAssertNotNil(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            waitForAnyElement(
                app: app,
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                labels: ["确认清理磁盘缓存", "Confirm Disk Cache Clear"],
                timeout: 2
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
            anyElement(app: app, withLabel: "应用名称").waitForExistence(timeout: 8),
            "In landscape, the About page should still show the app name"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        attachScreenshot(
            app: app,
            name: "ios-settings-about-page-landscape-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSSettingsAboutPageEnglishLocalizationScreenshotLight() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "light",
            forceEnglishLocalization: true
        )

        openSettingsFromSlideShow(app: app)
        openSettingsAboutPage(app: app, forceEnglishLocalization: true)
        assertSettingsAboutPageLoaded(app: app, forceEnglishLocalization: true)

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
            openSourceLink.waitForExistence(timeout: 8), "About page should show the 'Open Source Licenses' entry")

        attachScreenshot(
            app: app,
            name: "ios-settings-about-open-source-entry-light-\(currentDeviceTag())"
        )
        openSourceLink.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "settings.about.opensource.page")
                .firstMatch
                .waitForExistence(timeout: 3),
            "Tapping should open the open source licenses detail page"
        )
        XCTAssertTrue(
            anyElement(app: app, withLabel: "SDWebImage").waitForExistence(timeout: 8),
            "Open source licenses page should show the SDWebImage card"
        )
        XCTAssertTrue(
            anyElement(app: app, withLabel: "SDWebImageSwiftUI").waitForExistence(timeout: 8),
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
            openSourceLink.waitForExistence(timeout: 8), "About page should show the 'Open Source Licenses' entry")
        tapElement(openSourceLink)

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "settings.about.opensource.page")
                .firstMatch
                .waitForExistence(timeout: 3),
            "Tapping should open the open source licenses detail page"
        )

        openSettingsSection(app: app, sectionID: "settings.item.server")

        XCTAssertTrue(
            app.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 8),
            "After tapping 'Server' in the left sidebar from the open source licenses page, the right detail pane should switch to server settings immediately"
        )

        attachScreenshot(
            app: app,
            name: "ios-settings-open-source-sidebar-recovery-light-\(currentDeviceTag())"
        )
    }

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
            prepareFilterEditorVisuals: false,
            acceptanceLocale: locale
        )
        XCTAssertTrue(
            waitForLocalizedElement(
                filterEditorApp,
                identifier: "filterEditor.page.title",
                label: locale.filterEditorTitle,
                timeout: 8
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
                timeout: 8
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
            settingsApp.buttons["settings.playback.filterConfig.button"].waitForExistence(timeout: 8),
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
                .waitForExistence(timeout: 8),
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
            settingsApp.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 8),
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
            settingsApp.buttons["settings.cache.clearDisk.button"].waitForExistence(timeout: 8),
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
            anyElement(app: aboutApp, withLabel: locale.appInfoTitle).waitForExistence(timeout: 8),
            "Localized About page should show the App info section"
        )
        XCTAssertTrue(
            anyElement(app: aboutApp, withLabel: locale.privacyPolicyTitle).waitForExistence(timeout: 8),
            "Localized About page should show the privacy policy entry text for the target locale"
        )
        attachScreenshot(
            app: aboutApp,
            name: "\(locale.screenshotPrefix)-ios-settings-about-\(currentDeviceTag())"
        )

        openOpenSourceLicensesFromAbout(app: aboutApp)
        XCTAssertTrue(
            anyElement(app: aboutApp, withLabel: locale.openSourceTitle).waitForExistence(timeout: 8),
            "Localized open source licenses page should show text for the target locale"
        )
        attachScreenshot(
            app: aboutApp,
            name: "\(locale.screenshotPrefix)-ios-settings-open-source-\(currentDeviceTag())"
        )
    }

    @MainActor
    func runIOSLocalizedAcceptance(locale: LocalizedAcceptanceLocale) throws {

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
        filterSummaryApp.terminate()

        let filterEditorApp = try launchIntoFilterEditor(
            colorScheme: "light",
            prepareFilterEditorVisuals: false,
            acceptanceLocale: locale
        )
        XCTAssertTrue(
            waitForLocalizedElement(
                filterEditorApp,
                identifier: "filterEditor.page.title",
                label: locale.filterEditorTitle,
                timeout: 8
            ),
            "In the localized environment, the filter editor should show text for the target locale"
        )
        attachScreenshot(
            app: filterEditorApp,
            name: "\(locale.screenshotPrefix)-ios-filter-editor-\(currentDeviceTag())"
        )
        filterEditorApp.terminate()

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
        personApp.terminate()

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
                timeout: 8
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
            settingsApp.buttons["settings.playback.filterConfig.button"].waitForExistence(timeout: 8),
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
                .waitForExistence(timeout: 8),
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
            settingsApp.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 8),
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
            settingsApp.buttons["settings.cache.clearDisk.button"].waitForExistence(timeout: 8),
            "Localized cache management page should show the clear disk cache button"
        )
        attachScreenshot(
            app: settingsApp,
            name: "\(locale.screenshotPrefix)-ios-settings-cache-\(currentDeviceTag())"
        )

        openSettingsSection(
            app: settingsApp,
            sectionID: "settings.item.about"
        )
        XCTAssertTrue(
            anyElement(app: settingsApp, withLabel: locale.appInfoTitle).waitForExistence(timeout: 8),
            "Localized About page should show the App info section"
        )
        XCTAssertTrue(
            anyElement(app: settingsApp, withLabel: locale.privacyPolicyTitle).waitForExistence(timeout: 8),
            "Localized About page should show the privacy policy entry text for the target locale"
        )
        attachScreenshot(
            app: settingsApp,
            name: "\(locale.screenshotPrefix)-ios-settings-about-\(currentDeviceTag())"
        )

        openOpenSourceLicensesFromAbout(app: settingsApp)
        XCTAssertTrue(
            anyElement(app: settingsApp, withLabel: locale.openSourceTitle).waitForExistence(timeout: 8),
            "Localized open source licenses page should show text for the target locale"
        )
        attachScreenshot(
            app: settingsApp,
            name: "\(locale.screenshotPrefix)-ios-settings-open-source-\(currentDeviceTag())"
        )
    }

    @MainActor
    func testIOSEnglishAcceptanceFirstBootScreenshot() throws {

        let app = launchIntoOnboardingFirstBoot(
            colorScheme: "light",
            forceEnglishLocalization: true
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
            forceEnglishLocalization: true
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
            forceEnglishLocalization: true
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
            prepareFilterEditorVisuals: false,
            forceEnglishLocalization: true
        )
        XCTAssertTrue(
            anyElement(app: app, withLabel: "Edit Filters").waitForExistence(timeout: 8),
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
            forceEnglishLocalization: true
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
            forceEnglishLocalization: true
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
            forceEnglishLocalization: true
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
            forceEnglishLocalization: true
        )

        openSettingsFromSlideShow(app: app)

        openSettingsSection(app: app, sectionID: "settings.item.playback")
        XCTAssertTrue(
            anyElement(app: app, withLabel: "Autoplay").waitForExistence(timeout: 8),
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
            forceEnglishLocalization: true
        )

        openSettingsFromSlideShow(app: app)

        openSettingsSection(app: app, sectionID: "settings.item.server")
        XCTAssertTrue(
            app.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 8),
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
            forceEnglishLocalization: true
        )

        openSettingsFromSlideShow(app: app)

        openSettingsSection(app: app, sectionID: "settings.item.cache")
        XCTAssertTrue(
            app.buttons["settings.cache.clearDisk.button"].waitForExistence(timeout: 8),
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
            forceEnglishLocalization: true
        )

        openSettingsFromSlideShow(app: app)

        openSettingsAboutPage(app: app, forceEnglishLocalization: true)
        assertSettingsAboutPageLoaded(app: app, forceEnglishLocalization: true)
        attachScreenshot(
            app: app,
            name: "english-ios-settings-about-\(currentDeviceTag())"
        )

        openOpenSourceLicensesFromAbout(app: app)
        XCTAssertTrue(
            anyElement(app: app, withLabel: "Open Source Licenses").waitForExistence(timeout: 8),
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

private extension FilterSummaryIOSVisualUITests {
    @MainActor
    func launchIntoOnboardingFirstBoot(
        colorScheme: String,
        dynamicTypeSize: String? = nil,
        forceEnglishLocalization: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil,
        disableDebugFillConfigButton: Bool = true
    ) -> XCUIApplication {

        let app: XCUIApplication
        if let acceptanceLocale {
            app = makeLocalizedLaunchApp(
                colorScheme: colorScheme,
                acceptanceLocale: acceptanceLocale,
                dynamicTypeSize: dynamicTypeSize,
                disableDebugFillConfigButton: disableDebugFillConfigButton
            )
        } else if forceEnglishLocalization {
            app = makeLaunchApp(
                colorScheme: colorScheme,
                forceEnglishLocalization: true,
                dynamicTypeSize: dynamicTypeSize,
                disableDebugFillConfigButton: disableDebugFillConfigButton
            )
        } else {
            app = makeChineseLaunchApp(
                colorScheme: colorScheme,
                dynamicTypeSize: dynamicTypeSize,
                disableDebugFillConfigButton: disableDebugFillConfigButton
            )
        }
        app.launch()
        return app
    }

    @MainActor
    func launchIntoOnboardingModeSelection(
        colorScheme: String,
        dynamicTypeSize: String? = nil,
        forceEnglishLocalization: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil
    ) throws -> XCUIApplication {

        let app: XCUIApplication
        if let acceptanceLocale {
            app = makeLocalizedLaunchApp(
                colorScheme: colorScheme,
                acceptanceLocale: acceptanceLocale,
                dynamicTypeSize: dynamicTypeSize
            )
        } else if forceEnglishLocalization {
            app = makeLaunchApp(
                colorScheme: colorScheme,
                forceEnglishLocalization: true,
                dynamicTypeSize: dynamicTypeSize
            )
        } else {
            app = makeChineseLaunchApp(
                colorScheme: colorScheme,
                dynamicTypeSize: dynamicTypeSize
            )
        }
        let config = try requireTestServerConfig()
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launch()

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 15),
            "After injecting the test server config, the app should go straight to the mode selection page")
        return app
    }

    @MainActor
    func launchIntoOnboardingFilterSummary(
        colorScheme: String,
        dynamicTypeSize: String? = nil,
        forceEnglishLocalization: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil
    ) throws -> XCUIApplication {

        let app = try launchIntoOnboardingModeSelection(
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            forceEnglishLocalization: forceEnglishLocalization,
            acceptanceLocale: acceptanceLocale
        )

        let modeFilteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(modeFilteredButton.waitForExistence(timeout: 8))
        modeFilteredButton.tap()

        let modeContinueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(modeContinueButton.waitForExistence(timeout: 8))
        XCTAssertTrue(modeContinueButton.isEnabled)
        modeContinueButton.tap()

        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(startPlaybackButton.waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["filterSummary.album.button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["filterSummary.person.button"].waitForExistence(timeout: 10))
        assertFilterSummaryUsesOnlyTopBackButton(app: app)

        // Short wait so the screenshot does not catch a mid-transition frame.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        return app
    }

    func requireIOSDestination(file: StaticString = #filePath, line: UInt = #line) throws {
        let userInterfaceIdiom = UIDevice.current.userInterfaceIdiom
        guard userInterfaceIdiom != .tv else {
            throw XCTSkip("The current run destination is tvOS; skipping the iOS FilterSummary visual audit tests.")
        }
    }

    func waitForDebugFillConfigElement(in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement? {

        let candidates = [
            app.buttons["firstboot.fillConfig.button"],
            app.descendants(matching: .any)["firstboot.fillConfig.button"]
        ]
        let perCandidateTimeout = max(0.5, timeout / Double(candidates.count))

        for candidate in candidates {
            if candidate.waitForExistence(timeout: perCandidateTimeout) {
                return candidate
            }
        }

        return nil
    }

    func makeLaunchApp(
        colorScheme: String,
        forceEnglishLocalization: Bool = false,
        dynamicTypeSize: String? = nil,
        disablePlaybackEntryHint: Bool = true,
        disableDebugFillConfigButton: Bool = true,
        forceAutoPlayOff: Bool = false,
        showExifSamplingDebugOverlay: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_COLOR_SCHEME"] = colorScheme
        if disableDebugFillConfigButton {

            app.launchEnvironment["UI_TEST_DISABLE_DEBUG_FILL_APIKEY_BUTTON"] = "1"
        }
        if disablePlaybackEntryHint {
            app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        }
        if forceAutoPlayOff {

            app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        }
        if showExifSamplingDebugOverlay {

            app.launchEnvironment["UI_TEST_SHOW_EXIF_SAMPLING_DEBUG"] = "1"
        }
        if let dynamicTypeSize {

            app.launchEnvironment["UI_TEST_DYNAMIC_TYPE_SIZE"] = dynamicTypeSize
        }
        if forceEnglishLocalization {

            app.launchArguments += [
                "-AppleLanguages", "(en)",
                "-AppleLocale", "en_US"
            ]
        }
        return app
    }

    func makeChineseLaunchApp(
        colorScheme: String,
        dynamicTypeSize: String? = nil,
        disablePlaybackEntryHint: Bool = true,
        disableDebugFillConfigButton: Bool = true,
        forceAutoPlayOff: Bool = false,
        showExifSamplingDebugOverlay: Bool = false
    ) -> XCUIApplication {

        let app = makeLaunchApp(
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            disablePlaybackEntryHint: disablePlaybackEntryHint,
            disableDebugFillConfigButton: disableDebugFillConfigButton,
            forceAutoPlayOff: forceAutoPlayOff,
            showExifSamplingDebugOverlay: showExifSamplingDebugOverlay
        )
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN"
        ]
        return app
    }

    func makeLocalizedLaunchApp(
        colorScheme: String,
        acceptanceLocale: LocalizedAcceptanceLocale,
        dynamicTypeSize: String? = nil,
        disablePlaybackEntryHint: Bool = true,
        disableDebugFillConfigButton: Bool = true,
        forceAutoPlayOff: Bool = false,
        showExifSamplingDebugOverlay: Bool = false
    ) -> XCUIApplication {

        let app = makeLaunchApp(
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            disablePlaybackEntryHint: disablePlaybackEntryHint,
            disableDebugFillConfigButton: disableDebugFillConfigButton,
            forceAutoPlayOff: forceAutoPlayOff,
            showExifSamplingDebugOverlay: showExifSamplingDebugOverlay
        )
        app.launchArguments += [
            "-AppleLanguages", "(\(acceptanceLocale.languageCode))",
            "-AppleLocale", acceptanceLocale.localeIdentifier
        ]
        return app
    }

    @MainActor
    func launchIntoFilterSummary(
        colorScheme: String,
        forceEnglishLocalization: Bool = false,
        dynamicTypeSize: String? = nil,
        disablePlaybackEntryHint: Bool = true,
        prepareFilterEditorVisuals: Bool = false,
        forceAutoPlayOff: Bool = false,
        showExifSamplingDebugOverlay: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil
    ) throws -> XCUIApplication {

        let app: XCUIApplication
        if let acceptanceLocale {
            app = makeLocalizedLaunchApp(
                colorScheme: colorScheme,
                acceptanceLocale: acceptanceLocale,
                dynamicTypeSize: dynamicTypeSize,
                disablePlaybackEntryHint: disablePlaybackEntryHint,
                forceAutoPlayOff: forceAutoPlayOff,
                showExifSamplingDebugOverlay: showExifSamplingDebugOverlay
            )
        } else if forceEnglishLocalization {
            app = makeLaunchApp(
                colorScheme: colorScheme,
                forceEnglishLocalization: true,
                dynamicTypeSize: dynamicTypeSize,
                disablePlaybackEntryHint: disablePlaybackEntryHint,
                forceAutoPlayOff: forceAutoPlayOff,
                showExifSamplingDebugOverlay: showExifSamplingDebugOverlay
            )
        } else {

            app = makeChineseLaunchApp(
                colorScheme: colorScheme,
                dynamicTypeSize: dynamicTypeSize,
                disablePlaybackEntryHint: disablePlaybackEntryHint,
                forceAutoPlayOff: forceAutoPlayOff,
                showExifSamplingDebugOverlay: showExifSamplingDebugOverlay
            )
        }
        let config = try requireTestServerConfig()
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        try requireServerAlbumAndPerson()
        app.launchEnvironment["UI_TEST_PREPARE_FILTER_SUMMARY_VISUAL_SELECTIONS"] = "1"
        if prepareFilterEditorVisuals {
            app.launchEnvironment["UI_TEST_PREPARE_FILTER_EDITOR_VISUAL_SELECTIONS"] = "1"
        }
        app.launch()

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 15),
            "After injecting the test server config, the app should go straight to the mode selection page")
        startFilteredFlowFromModeSelection(app: app)

        let albumButton = app.buttons["filterSummary.album.button"]
        let peopleButton = app.buttons["filterSummary.person.button"]
        XCTAssertTrue(albumButton.waitForExistence(timeout: 10))
        XCTAssertTrue(peopleButton.waitForExistence(timeout: 10))
        assertFilterSummaryUsesOnlyTopBackButton(app: app)
        return app
    }

    @MainActor
    func launchIntoRandomSlideShow(
        colorScheme: String,
        dynamicTypeSize: String? = nil,
        disablePlaybackEntryHint: Bool = true,
        forceAutoPlayOff: Bool = false,
        showExifSamplingDebugOverlay: Bool = false
    ) throws -> XCUIApplication {

        let app = makeChineseLaunchApp(
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            disablePlaybackEntryHint: disablePlaybackEntryHint,
            forceAutoPlayOff: forceAutoPlayOff,
            showExifSamplingDebugOverlay: showExifSamplingDebugOverlay
        )

        let config = try requireTestServerConfig()
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey

        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launch()

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 15),
            "After injecting the test server config, the app should go straight to the mode selection page"
        )

        startRandomPlaybackFromModeSelection(app: app)

        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: 10),
            "After random playback opens the playback page, the play/pause button should be visible"
        )

        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        return app
    }

    func assertFilterSummaryUsesOnlyTopBackButton(
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {

        let globalBackButton = app.buttons["global.back.button"]
        XCTAssertTrue(
            globalBackButton.waitForExistence(timeout: 6),
            "Filter summary page should keep the top-left back button",
            file: file,
            line: line
        )

        XCTAssertFalse(
            app.buttons["filterSummary.backToMode.button"].exists,
            "iOS filter summary page should no longer show the bottom 'Back to Mode Selection' button, so it does not duplicate the top-left back entry",
            file: file,
            line: line
        )
    }

    func assertOnboardingHeader(
        app: XCUIApplication,
        expectedWizardTitle: String = "首次设置向导",
        expectedPageTitle: String,
        pageTitleIdentifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {

        let wizardTitle = app.staticTexts["onboardingWizard.title"]
        XCTAssertTrue(
            wizardTitle.waitForExistence(timeout: 8),
            "The top of the page should show the shared setup wizard header",
            file: file,
            line: line
        )
        XCTAssertEqual(wizardTitle.label, expectedWizardTitle, file: file, line: line)

        let pageTitle = app.staticTexts[pageTitleIdentifier]
        XCTAssertTrue(
            pageTitle.waitForExistence(timeout: 8),
            "The page main title should clearly state the task of the current step",
            file: file,
            line: line
        )
        XCTAssertEqual(pageTitle.label, expectedPageTitle, file: file, line: line)

        XCTAssertFalse(
            wizardTitle.frame.intersects(pageTitle.frame),
            "The wizard header and the page main title should not overlap",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            wizardTitle.frame.minY,
            pageTitle.frame.minY,
            "The wizard header should sit above the page main title",
            file: file,
            line: line
        )
    }

    func assertPlaybackEntryHint(
        app: XCUIApplication,
        expectedTitle: String,
        expectedAction: String,
        expectedKeycap: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {

        let banner = app.otherElements["slideshow.entryHint.banner"]
        let title = app.staticTexts["slideshow.entryHint.title"]
        let action = app.otherElements["slideshow.entryHint.action"]
        let keycap = app.otherElements["slideshow.entryHint.keycap"]
        let settingsButton = app.buttons["slideshow.control.settings.button"]

        XCTAssertTrue(
            banner.waitForExistence(timeout: 6),
            "On first entering the playback page, the one-time tip bubble should appear",
            file: file,
            line: line
        )
        XCTAssertTrue(
            title.waitForExistence(timeout: 2),
            "The tip should show its main text",
            file: file,
            line: line
        )
        XCTAssertEqual(title.label, expectedTitle, file: file, line: line)
        XCTAssertTrue(
            action.waitForExistence(timeout: 2),
            "The tip should show the action hint",
            file: file,
            line: line
        )
        XCTAssertEqual(action.label, expectedAction, file: file, line: line)
        XCTAssertTrue(
            keycap.waitForExistence(timeout: 2),
            "The tip should show the dismiss target as a separate keycap",
            file: file,
            line: line
        )
        XCTAssertEqual(keycap.label, expectedKeycap, file: file, line: line)
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 4),
            "The playback page should keep the settings button; the tip must not break the entry itself",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            banner.frame.minY,
            settingsButton.frame.minY,
            "The tip should sit above the settings button, not cover it",
            file: file,
            line: line
        )
        let bannerFrame = banner.frame
        let settingsButtonFrame = settingsButton.frame
        XCTAssertFalse(
            bannerFrame.intersects(settingsButtonFrame),
            "The tip body card should not cover the settings button. banner=\(bannerFrame), settings=\(settingsButtonFrame)",
            file: file,
            line: line
        )

        let bubbleToSettingsGap = settingsButtonFrame.minY - bannerFrame.maxY
        XCTAssertGreaterThanOrEqual(
            bubbleToSettingsGap,
            0,
            "The tip should not cover the settings button. gap=\(bubbleToSettingsGap), banner=\(bannerFrame), settings=\(settingsButtonFrame)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            bubbleToSettingsGap,
            12,
            "The tip's tail should sit right above the settings button, not float. gap=\(bubbleToSettingsGap), banner=\(bannerFrame), settings=\(settingsButtonFrame)",
            file: file,
            line: line
        )

        let maxSingleLineHeight = banner.frame.height * 0.46
        XCTAssertLessThanOrEqual(
            title.frame.height,
            maxSingleLineHeight,
            "The tip title should stay on one line, not be squeezed onto two lines",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            action.frame.height,
            maxSingleLineHeight,
            "The tip action hint should stay on one line, not wrap onto two lines",
            file: file,
            line: line
        )

        let widestContentFrame = title.frame.width >= action.frame.width ? title.frame : action.frame
        let leadingInset = widestContentFrame.minX - banner.frame.minX
        let trailingInset = banner.frame.maxX - widestContentFrame.maxX
        XCTAssertLessThanOrEqual(
            abs(leadingInset - trailingInset),
            4,
            "The tip's left and right padding should match, with no extra space on the right",
            file: file,
            line: line
        )
    }

    func waitForPlaybackEntryHintToDisappear(
        _ entryHintBanner: XCUIElement,
        timeout: TimeInterval = 3
    ) {

        let deadline = Date().addingTimeInterval(timeout)
        while entryHintBanner.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    func titleFrame(
        app: XCUIApplication,
        identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGRect {
        let title = app.staticTexts[identifier]
        XCTAssertTrue(
            title.waitForExistence(timeout: 8),
            "Should be able to read the page main title position: \(identifier)",
            file: file,
            line: line
        )
        return title.frame
    }

    func assertTitleFrame(
        _ frame: CGRect,
        alignsWith baseline: CGRect,
        pageName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            abs(frame.minX - baseline.minX),
            4,
            "\(pageName) main title left edge should match step 1",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            abs(frame.minY - baseline.minY),
            12,
            "\(pageName) main title vertical position should match step 1",
            file: file,
            line: line
        )
    }

    @MainActor
    func launchIntoSlideShow(
        colorScheme: String,
        forceEnglishLocalization: Bool = false,
        dynamicTypeSize: String? = nil,
        disablePlaybackEntryHint: Bool = true,
        prepareFilterEditorVisuals: Bool = false,
        forceAutoPlayOff: Bool = false,
        showExifSamplingDebugOverlay: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil
    ) throws -> XCUIApplication {

        let app = try launchIntoFilterSummary(
            colorScheme: colorScheme,
            forceEnglishLocalization: forceEnglishLocalization,
            dynamicTypeSize: dynamicTypeSize,
            disablePlaybackEntryHint: disablePlaybackEntryHint,
            prepareFilterEditorVisuals: prepareFilterEditorVisuals,
            forceAutoPlayOff: forceAutoPlayOff,
            showExifSamplingDebugOverlay: showExifSamplingDebugOverlay,
            acceptanceLocale: acceptanceLocale
        )
        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startPlaybackButton.waitForExistence(timeout: 8),
            "Filter summary page should show the 'Start Playback' button")
        // Start stays disabled until the page has loaded and selected the first album from the server.
        waitForReadinessMarker(app: app, identifier: "filterSummary.visual.ready")
        XCTAssertTrue(
            startPlaybackButton.isEnabled, "The 'Start Playback' button on the filter summary page should be enabled")
        startPlaybackButton.tap()

        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 20),
            "After starting playback, the playback page should open and show the control bar")

        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(playPauseButton.waitForExistence(timeout: 10), "Playback page should show the play/pause button")

        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        return app
    }

    @MainActor
    func launchIntoFilterEditor(
        colorScheme: String,
        dynamicTypeSize: String? = nil,
        forceAutoPlayOff: Bool = false,
        prepareFilterEditorVisuals: Bool = true,
        showExifSamplingDebugOverlay: Bool = false,
        forceEnglishLocalization: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil
    ) throws -> XCUIApplication {

        let app = try launchIntoSlideShow(
            colorScheme: colorScheme,
            forceEnglishLocalization: forceEnglishLocalization,
            dynamicTypeSize: dynamicTypeSize,
            prepareFilterEditorVisuals: prepareFilterEditorVisuals,
            forceAutoPlayOff: forceAutoPlayOff,
            showExifSamplingDebugOverlay: showExifSamplingDebugOverlay,
            acceptanceLocale: acceptanceLocale
        )

        openSettingsFromSlideShow(app: app)
        openSettingsSection(
            app: app,
            sectionID: "settings.item.playback"
        )

        let filterConfigButton = app.buttons["settings.playback.filterConfig.button"]
        XCTAssertTrue(
            filterConfigButton.waitForExistence(timeout: 8),
            "Playback settings page should show the 'Edit Filters' entry"
        )
        XCTAssertTrue(
            waitForElementToBecomeHittable(filterConfigButton, app: app, timeout: 5),
            "The 'Edit Filters' entry on the playback settings page should scroll into a tappable position"
        )
        tapElement(filterConfigButton)

        let albumEntry = app.buttons["filter.editor.album.entry"]
        let personEntry = app.buttons["filter.editor.person.entry"]
        XCTAssertTrue(albumEntry.waitForExistence(timeout: 10), "Filter editor should show the album entry")
        XCTAssertTrue(personEntry.waitForExistence(timeout: 10), "Filter editor should show the people entry")

        if prepareFilterEditorVisuals {
            waitForReadinessMarker(app: app, identifier: "filterEditor.visual.ready")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        return app
    }

    @MainActor
    func launchIntoAlbumFilterFromSummary() throws -> XCUIApplication {
        let app = try launchIntoFilterSummary(colorScheme: "dark")
        let albumButton = app.buttons["filterSummary.album.button"]
        XCTAssertTrue(albumButton.waitForExistence(timeout: 10))
        tapElement(albumButton)
        XCTAssertTrue(app.buttons["albumFilter.back.button"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    func launchIntoAlbumFilterPage(
        colorScheme: String,
        dynamicTypeSize: String?,
        forceEnglishLocalization: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil
    ) throws -> XCUIApplication {
        let app = try launchIntoFilterEditor(
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            prepareFilterEditorVisuals: acceptanceLocale == nil && forceEnglishLocalization == false,
            forceEnglishLocalization: forceEnglishLocalization,
            acceptanceLocale: acceptanceLocale
        )

        setOrientation(.portrait, app: app, waitForTitleIdentifier: "filterEditor.page.title")

        let albumEntry = app.buttons["filter.editor.album.entry"]
        XCTAssertTrue(albumEntry.waitForExistence(timeout: 10), "Filter editor should show the album entry")
        tapElement(albumEntry)

        assertInAlbumFilterEditorPage(
            app: app,
            forceEnglishLocalization: forceEnglishLocalization,
            expectedTitleText: acceptanceLocale?.albumFilterTitle
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        return app
    }

    @MainActor
    func launchIntoPersonFilterPage(
        colorScheme: String,
        dynamicTypeSize: String?,
        forceEnglishLocalization: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil
    ) throws -> XCUIApplication {
        let app = try launchIntoFilterEditor(
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            prepareFilterEditorVisuals: acceptanceLocale == nil && forceEnglishLocalization == false,
            forceEnglishLocalization: forceEnglishLocalization,
            acceptanceLocale: acceptanceLocale
        )

        setOrientation(.portrait, app: app, waitForTitleIdentifier: "filterEditor.page.title")

        let personEntry = app.buttons["filter.editor.person.entry"]
        XCTAssertTrue(personEntry.waitForExistence(timeout: 10), "Filter editor should show the people entry")
        tapElement(personEntry)

        assertInPersonFilterEditorPage(
            app: app,
            forceEnglishLocalization: forceEnglishLocalization,
            expectedTitleText: acceptanceLocale?.personFilterTitle
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        return app
    }

    @MainActor
    func configureExifDiagnosticFilters(app: XCUIApplication) throws {

        clearAllPeopleSelections(app: app)
        try selectOnlyExifDiagnosticAlbum(app: app)

        let personEntry = app.buttons["filter.editor.person.entry"]
        XCTAssertTrue(
            personEntry.waitForExistence(timeout: 8),
            "After returning to the filter editor, the people entry should still be visible")

        let albumEntry = app.buttons["filter.editor.album.entry"]
        XCTAssertTrue(
            albumEntry.waitForExistence(timeout: 8),
            "After returning to the filter editor, the album entry should still be visible")
        attachScreenshot(app: app, name: "ios-exif-diagnostic-filter-configured")
    }

    @MainActor
    func clearAllPeopleSelections(app: XCUIApplication) {
        let personEntry = app.buttons["filter.editor.person.entry"]
        XCTAssertTrue(personEntry.waitForExistence(timeout: 8), "Filter editor should show the people entry")
        tapElement(personEntry)

        assertInPersonFilterEditorPage(app: app)

        let clearButton = app.buttons["personFilter.clear.button"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 8), "People filter page should show the clear button")
        tapElement(clearButton)

        let backButton = app.buttons["personFilter.back.button"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 8), "People filter page should show the back button")
        tapElement(backButton)
    }

    @MainActor
    func selectOnlyExifDiagnosticAlbum(app: XCUIApplication) throws {
        let albumEntry = app.buttons["filter.editor.album.entry"]
        XCTAssertTrue(albumEntry.waitForExistence(timeout: 8), "Filter editor should show the album entry")
        tapElement(albumEntry)

        assertInAlbumFilterEditorPage(app: app)

        let clearButton = app.buttons["albumFilter.clear.button"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 8), "Album filter page should show the clear button")
        tapElement(clearButton)

        let diagnosticAlbumButton = waitForAlbumFilterButton(
            app: app,
            albumID: exifDiagnosticAlbumID,
            timeout: 12
        )
        guard diagnosticAlbumButton.exists else {
            throw XCTSkip(
                "The test server has no EXIF panel diagnostic album; skipping this diagnostic screenshot, which depends on fixed test data."
            )
        }
        tapElement(diagnosticAlbumButton)

        let backButton = app.buttons["albumFilter.back.button"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 8), "Album filter page should show the back button")
        tapElement(backButton)
    }

    @MainActor
    func waitForAlbumFilterButton(
        app: XCUIApplication,
        albumID: String,
        timeout: TimeInterval
    ) -> XCUIElement {
        let albumButton = app.buttons["albumFilter.album.\(albumID).button"]
        let scrollView = app.scrollViews.firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if albumButton.exists {
                return albumButton
            }

            if scrollView.exists {
                scrollView.swipeUp()
            } else {
                app.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }

        return albumButton
    }

    @MainActor
    func captureExifDiagnosticSlides(
        app: XCUIApplication,
        expectedCount: Int,
        screenshotNamePrefix: String = "ios-exif-diagnostic",
        waitForSamplingOverlay: Bool = false
    ) {
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: 8),
            "After returning to the playback page, the play/pause button should be visible")
        XCTAssertTrue(
            waitUntil(timeout: 4) {
                ((playPauseButton.value as? String) ?? "").lowercased() == "play"
            },
            "In diagnostic mode autoplay should be off, and the middle control bar button should be in the 'play' state"
        )

        for index in 0..<expectedCount {
            XCTAssertTrue(
                waitForSlideshowSettingsButton(app: app, timeout: 8),
                "Before each screenshot, the playback control bar should wake up reliably"
            )

            if waitForSamplingOverlay {
                XCTAssertTrue(
                    waitForExifSamplingDebugOverlay(app: app, timeout: 8),
                    "In sampling-region diagnostic mode, the playback page should render the reconstructed sampling image, not stay in the loading state"
                )
            }
            let toneLabel = currentExifToneDebugLabel(app: app)
            attachScreenshot(
                app: app,
                name: "\(screenshotNamePrefix)-\(String(format: "%02d", index + 1))-\(toneLabel)"
            )

            guard index < expectedCount - 1 else { continue }

            if waitForSamplingOverlay {
                XCTAssertTrue(
                    waitForSlideshowSettingsButton(app: app, timeout: 8),
                    "The control bar may have auto-hidden while waiting for the sampling overlay; it should wake up again before tapping next"
                )
            }

            XCTAssertTrue(
                advanceToNextDistinctDiagnosticSlide(app: app),
                "After tapping next, the current photo should change, so the same photo is not captured twice"
            )
        }
    }

    func advanceToNextDistinctDiagnosticSlide(app: XCUIApplication) -> Bool {
        let previousAssetID = currentSlideshowAssetID(app: app)
        let previousDateLabel = currentExifDateLabel(app: app)

        for _ in 0..<3 {
            XCTAssertTrue(
                waitForSlideshowSettingsButton(app: app, timeout: 8),
                "Before retrying next, the playback control bar should wake up again"
            )
            let nextButton = app.buttons["slideshow.control.next.button"]
            XCTAssertTrue(nextButton.waitForExistence(timeout: 8), "Playback page should show the 'Next' button")
            tapElement(nextButton)

            if let previousAssetID {
                if waitUntil(
                    timeout: 8,
                    condition: {
                        guard let currentAssetID = self.currentSlideshowAssetID(app: app) else { return false }
                        return currentAssetID != previousAssetID
                    })
                {
                    return true
                }
            } else if let previousDateLabel {
                if waitUntil(
                    timeout: 8,
                    condition: {
                        self.currentExifDateLabel(app: app) != previousDateLabel
                    })
                {
                    return true
                }
            } else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                return true
            }
        }

        return false
    }

    func currentExifToneDebugLabel(app: XCUIApplication) -> String {
        let toneFlag = app.descendants(matching: .any)["slideshow.exifForegroundTone.flag"]
        XCTAssertTrue(
            toneFlag.waitForExistence(timeout: 6),
            "Playback page should expose the current EXIF text color diagnostic marker")

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

    func currentSlideshowAssetID(app: XCUIApplication) -> String? {
        let assetFlag = app.descendants(matching: .any)["slideshow.currentAssetId.flag"]
        guard assetFlag.waitForExistence(timeout: 4) else { return nil }

        let candidates = [
            assetFlag.label,
            assetFlag.value as? String ?? ""
        ]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != "no-asset" {
                return trimmed
            }
        }
        return nil
    }

    func waitForExifSamplingDebugOverlay(app: XCUIApplication, timeout: TimeInterval) -> Bool {

        let overlayReady = app.descendants(matching: .any)["slideshow.exifSamplingDebugOverlay.ready"]
        return overlayReady.waitForExistence(timeout: timeout)
    }

    func currentExifDateLabel(app: XCUIApplication) -> String? {

        let pattern = #"^\d{4}-\d{2}-\d{2}$"#
        // ui-label-lookup: This predicate validates the displayed EXIF date format.
        let predicate = NSPredicate(format: "label MATCHES %@", pattern)
        let match = app.staticTexts.matching(predicate).firstMatch
        return match.exists ? match.label : nil
    }

    @MainActor
    func openSettingsFromSlideShow(app: XCUIApplication) {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            waitForSlideshowSettingsButton(app: app, timeout: 12), "Playback page should show the settings button")

        tapElement(settingsButton)

        XCTAssertTrue(
            waitForAnySettingsRootEntry(app: app, timeout: 10),
            "After opening settings from the playback page, the settings list should be visible"
        )
    }

    func assertCompactPhoneFilterTopBar(
        app: XCUIApplication,
        expectedTitle: String,
        filterPageIdentifierPrefix: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {

        let backButton = app.buttons["\(filterPageIdentifierPrefix).back.button"]
        let selectAllButton = app.buttons["\(filterPageIdentifierPrefix).selectAll.button"]
        let clearButton = app.buttons["\(filterPageIdentifierPrefix).clear.button"]
        let title = app.staticTexts["filterTopBar.title"]
        let summary = app.descendants(matching: .any)["filterTopBar.summary"]

        XCTAssertTrue(
            backButton.waitForExistence(timeout: 8), "Top bar should still show the back button", file: file, line: line
        )
        XCTAssertTrue(
            selectAllButton.waitForExistence(timeout: 8), "Top bar should still show the select all button", file: file,
            line: line)
        XCTAssertTrue(
            clearButton.waitForExistence(timeout: 8), "Top bar should still show the clear button", file: file,
            line: line)
        XCTAssertTrue(
            title.waitForExistence(timeout: 8), "Top bar should still show the page title", file: file, line: line)
        // ui-label-lookup: The filter title is the localization assertion for this top bar.
        XCTAssertEqual(title.label, expectedTitle, file: file, line: line)

        XCTAssertFalse(
            summary.exists,
            "In iPhone portrait, the glass top bar should no longer show the summary line, so it does not crowd the buttons",
            file: file,
            line: line
        )

        XCTAssertFalse(
            title.frame.intersects(backButton.frame),
            "Page title should not overlap the back button",
            file: file,
            line: line
        )
        XCTAssertFalse(
            title.frame.intersects(selectAllButton.frame),
            "Page title should not overlap the select all button",
            file: file,
            line: line
        )
        XCTAssertFalse(
            title.frame.intersects(clearButton.frame),
            "Page title should not overlap the clear button",
            file: file,
            line: line
        )
    }

    func assertInAlbumFilterEditorPage(
        app: XCUIApplication,
        forceEnglishLocalization: Bool = false,
        expectedTitleText: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let titleText = expectedTitleText ?? (forceEnglishLocalization ? "Filter Albums" : "筛选相册")
        let title = app.staticTexts["filterTopBar.title"]
        let backButton = app.buttons["albumFilter.back.button"]
        let selectAllButton = app.buttons["albumFilter.selectAll.button"]
        let clearButton = app.buttons["albumFilter.clear.button"]

        XCTAssertTrue(
            title.waitForExistence(timeout: 8),
            "After entering the album filter page, the page title in the target language should be visible",
            file: file,
            line: line
        )
        // ui-label-lookup: The filter page title is the localization assertion for this page.
        XCTAssertEqual(title.label, titleText, file: file, line: line)
        XCTAssertTrue(
            backButton.exists || selectAllButton.exists || clearButton.exists,
            "Album filter top bar should show at least the back button or an action button",
            file: file,
            line: line
        )
    }

    func assertInPersonFilterEditorPage(
        app: XCUIApplication,
        forceEnglishLocalization: Bool = false,
        expectedTitleText: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let titleText = expectedTitleText ?? (forceEnglishLocalization ? "Filter People" : "筛选人物")
        let title = app.staticTexts["filterTopBar.title"]
        let backButton = app.buttons["personFilter.back.button"]
        let selectAllButton = app.buttons["personFilter.selectAll.button"]
        let clearButton = app.buttons["personFilter.clear.button"]

        XCTAssertTrue(
            title.waitForExistence(timeout: 8),
            "After entering the people filter page, the page title in the target language should be visible",
            file: file,
            line: line
        )
        // ui-label-lookup: The filter page title is the localization assertion for this page.
        XCTAssertEqual(title.label, titleText, file: file, line: line)
        XCTAssertTrue(
            backButton.exists || selectAllButton.exists || clearButton.exists,
            "People filter top bar should show at least the back button or an action button",
            file: file,
            line: line
        )
    }

    func openSettingsSection(app: XCUIApplication, sectionID: String) {

        for attempt in 0..<6 {
            let typedCandidates: [XCUIElement] = [
                app.buttons[sectionID],
                app.staticTexts[sectionID],
                app.otherElements[sectionID]
            ]

            for candidate in typedCandidates {
                if candidate.waitForExistence(timeout: 1) {
                    tapElement(candidate)
                    return
                }
            }

            let fallback = app.descendants(matching: .any).matching(identifier: sectionID).firstMatch
            if fallback.waitForExistence(timeout: 1) {
                tapElement(fallback)
                return
            }

            // ui-label-lookup: ToggleSidebar is the system-provided sidebar navigation control.
            let toggleSidebarButton = app.buttons["ToggleSidebar"]
            let sidebarIsCollapsed =
                toggleSidebarButton.exists && toggleSidebarButton.isHittable
                && isShowSidebarLabel(toggleSidebarButton.label)
            if sidebarIsCollapsed {
                toggleSidebarButton.tap()
                _ = waitForAnySettingsRootEntry(app: app, timeout: 1.5)
                continue
            }

            if !hasStableSettingsRootEntry(app: app),
                let navBack = preferredNavigationBackButton(app: app)
            {
                tapElement(navBack)
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                continue
            }

            if attempt % 2 == 0 {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
        }
    }

    @MainActor
    func openSettingsAboutPage(
        app: XCUIApplication,
        forceEnglishLocalization: Bool = false
    ) {
        openSettingsSection(
            app: app,
            sectionID: "settings.item.about"
        )
    }

    @MainActor
    // ui-label-lookup: This helper verifies the translated About page copy.
    func assertSettingsAboutPageLoaded(
        app: XCUIApplication,
        forceEnglishLocalization: Bool = false
    ) {
        let appInfoTitle = forceEnglishLocalization ? "App Information" : "应用信息"
        let appNameTitle = forceEnglishLocalization ? "App Name" : "应用名称"
        let versionTitle = forceEnglishLocalization ? "Version" : "版本号"
        let platformTitle = forceEnglishLocalization ? "Platform" : "运行平台"
        let unofficialNoticeTitle = forceEnglishLocalization ? "Unofficial Notice" : "非官方声明"
        let unofficialNoticeText =
            forceEnglishLocalization
            ? "immichSlides is an independently developed unofficial app. It is not the official Immich app and is not endorsed, sponsored, or approved by Immich."
            : "immichSlides 是独立开发的非官方应用，不是 Immich 官方应用，也未获得 Immich 官方背书、赞助或认可。"
        let feedbackTitle = forceEnglishLocalization ? "Feedback & Support" : "反馈与支持"
        let feedbackHintText =
            forceEnglishLocalization
            ? "To report an issue, note the version number and steps to reproduce."
            : "如需反馈问题，可先记录版本号与复现步骤。"
        let privacySectionTitle = forceEnglishLocalization ? "Privacy & Protection" : "隐私与保护"
        let privacyEntryTitle = forceEnglishLocalization ? "Privacy Policy" : "隐私政策"
        let privacyEntrySubtitle =
            forceEnglishLocalization
            ? "Open the full policy text in your browser."
            : "在浏览器中查看完整政策文本。"

        XCTAssertTrue(
            anyElement(app: app, withLabel: appInfoTitle).waitForExistence(timeout: 8),
            "About page should show the app information title")
        XCTAssertTrue(
            anyElement(app: app, withLabel: appNameTitle).waitForExistence(timeout: 8),
            "About page should show the app name title")
        XCTAssertTrue(
            anyElement(app: app, withLabel: versionTitle).waitForExistence(timeout: 8),
            "About page should show the version title")
        XCTAssertTrue(
            anyElement(app: app, withLabel: platformTitle).waitForExistence(timeout: 8),
            "About page should show the platform title")
        XCTAssertTrue(
            anyElement(app: app, withLabel: unofficialNoticeTitle).waitForExistence(timeout: 8),
            "About page should show the unofficial notice title")
        XCTAssertTrue(
            anyElement(app: app, withLabel: unofficialNoticeText).waitForExistence(timeout: 8),
            "About page should show the unofficial notice text")
        XCTAssertTrue(
            anyElement(app: app, withLabel: feedbackTitle).waitForExistence(timeout: 8),
            "About page should show the feedback and support title")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "settings.about.feedback.email.link")
                .firstMatch
                .waitForExistence(timeout: 8),
            "About page should show the real support email entry"
        )
        XCTAssertTrue(
            anyElement(app: app, withLabel: feedbackHintText).waitForExistence(timeout: 8),
            "About page should show the feedback hint")
        XCTAssertTrue(
            anyElement(app: app, withLabel: privacySectionTitle).waitForExistence(timeout: 8),
            "About page should show the privacy and protection title")
        XCTAssertTrue(
            anyElement(app: app, withLabel: privacyEntryTitle).waitForExistence(timeout: 8),
            "About page should show the privacy policy entry title")
        XCTAssertTrue(
            anyElement(app: app, withLabel: privacyEntrySubtitle).waitForExistence(timeout: 8),
            "About page should show the privacy policy entry description")

        if forceEnglishLocalization {

            XCTAssertTrue(
                anyElement(app: app, withLabel: "App Information").waitForExistence(timeout: 8),
                "English About page should show 'App Information'"
            )
            XCTAssertTrue(
                anyElement(app: app, withLabel: "Feedback & Support").waitForExistence(timeout: 8),
                "English About page should show 'Feedback & Support'"
            )
            XCTAssertTrue(
                anyElement(app: app, withLabel: "Unofficial Notice").waitForExistence(timeout: 8),
                "English About page should show 'Unofficial Notice'"
            )
            XCTAssertTrue(
                anyElement(app: app, withLabel: "Privacy & Protection").waitForExistence(timeout: 8),
                "English About page should show 'Privacy & Protection'"
            )
            XCTAssertTrue(
                anyElement(app: app, withLabel: "Privacy Policy").waitForExistence(timeout: 8),
                "English About page should show 'Privacy Policy'"
            )
            XCTAssertTrue(
                anyElement(
                    app: app,
                    withLabel: "View the current version, runtime environment, and feedback guidance."
                ).waitForExistence(timeout: 8),
                "English About page should show the new header description"
            )
        }
    }

    @MainActor
    func openOpenSourceLicensesFromAbout(
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {

        let openSourceLink = waitForOpenSourceLicensesLinkInAbout(app: app)
        XCTAssertNotNil(
            openSourceLink,
            "About page should show the 'Open Source Licenses' entry",
            file: file,
            line: line
        )

        if let openSourceLink {

            openSourceLink.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "settings.about.opensource.page")
                .firstMatch
                .waitForExistence(timeout: 3),
            "Tapping 'Open Source Licenses' should quickly open the open source licenses detail page",
            file: file,
            line: line
        )
    }

    @MainActor
    func returnToSettingsAboutFromOpenSourceLicenses(
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {

        let aboutBackButton = app.navigationBars.buttons["settings.about.opensource.back.button"].firstMatch
        if aboutBackButton.waitForExistence(timeout: 4) {
            tapElement(aboutBackButton)
        } else {

            let detailBackButton = app.navigationBars.buttons.allElementsBoundByIndex
                .filter { button in
                    button.exists && button.isHittable && button.identifier == "BackButton"
                }
                .last

            XCTAssertNotNil(
                detailBackButton,
                "Open source licenses page should show a navigation button in the right detail pane that returns to About",
                file: file,
                line: line
            )

            if let detailBackButton {
                tapElement(detailBackButton)
            }
        }

        XCTAssertNotNil(
            waitForOpenSourceLicensesLinkInAbout(app: app),
            "After going back from the open source licenses page, the About page's open source licenses entry should be visible again",
            file: file,
            line: line
        )
    }

    @MainActor
    func waitForOpenSourceLicensesLinkInAbout(app: XCUIApplication) -> XCUIElement? {

        for _ in 0..<5 {
            let openSourceButton = app.buttons["settings.about.opensource.link"]
            if openSourceButton.waitForExistence(timeout: 1), openSourceButton.isHittable {
                return openSourceButton
            }

            let openSourceLink = app.descendants(matching: .any)
                .matching(identifier: "settings.about.opensource.link")
                .firstMatch
            if openSourceLink.exists, openSourceLink.isHittable {
                return openSourceLink
            }

            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        return nil
    }

    @MainActor
    func returnToSlideShowFromSettings(app: XCUIApplication) {

        for _ in 0..<3 {
            if app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 2) {
                return
            }

            let backButton = app.navigationBars.buttons.firstMatch
            if backButton.exists && backButton.isHittable {
                backButton.tap()
                continue
            }
        }

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 5),
            "Could not return from settings to the playback page"
        )
    }

    func waitForSlideshowSettingsButton(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let button = app.buttons["slideshow.control.settings.button"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if button.exists && button.isHittable {
                return true
            }
            app.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return button.exists
    }

    func waitForElementToBecomeHittable(
        _ element: XCUIElement,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if element.exists && element.isHittable {
                return true
            }

            let scrollView = app.scrollViews.firstMatch
            if scrollView.exists {
                scrollView.swipeUp()
            } else {
                app.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        return element.exists && element.isHittable
    }

    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
            return
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
    func waitForAnyElement(
        app: XCUIApplication,
        labels: [String],
        timeout: TimeInterval
    ) -> XCUIElement? {
        func matchingContainer() -> XCUIElement? {
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            for container in [app.alerts.firstMatch, app.sheets.firstMatch] where container.exists {
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                if labels.contains(where: { container.label == $0 }) {
                    return container
                }
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                if labels.contains(where: { label in
                    // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                    container.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch.exists
                }) {
                    return container
                }
            }
            return nil
        }

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        _ = waitUntil(timeout: timeout) { matchingContainer() != nil }
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        return matchingContainer()
    }

    // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
    func tapFirstExistingButton(app: XCUIApplication, labels: [String]) {

        for label in labels {
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let button = app.buttons[label].firstMatch
            if button.exists {
                tapElement(button)
                return
            }
        }

        let availableLabels = labels.joined(separator: ", ")
        XCTFail("No tappable button found: \(availableLabels)")
    }

    func dismissKeyboardIfNeeded(app: XCUIApplication) {

        if app.keyboards.count == 0 { return }

        // ui-label-lookup: These labels address system keyboard action keys.
        let keyboardDismissButtonLabels = [
            "Return", "Done", "完成", "确定", "Next", "next", "Go", "Search"
        ]

        for label in keyboardDismissButtonLabels {
            // ui-label-lookup: Keyboard action keys are system-provided controls.
            let button = app.keyboards.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                if app.keyboards.count == 0 {
                    return
                }
            }
        }

        // On some OS versions the keyboard toolbar is not in the XCTest tree, so it cannot be the only check.

        let toolbarDoneButton = app.buttons["server.keyboard.done.button"]
        if toolbarDoneButton.exists && toolbarDoneButton.isHittable {
            toolbarDoneButton.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if app.keyboards.count == 0 {
                return
            }
        }

        let safeTopTapArea = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06))
        safeTopTapArea.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        if app.keyboards.count == 0 {
            return
        }

        let navigationBar = app.navigationBars.firstMatch
        if navigationBar.exists {
            navigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    func startRandomPlaybackFromModeSelection(app: XCUIApplication) {

        let modeRandomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(
            modeRandomButton.waitForExistence(timeout: 8),
            "Mode selection page should show the 'Shuffle All Photos' entry")
        tapElement(modeRandomButton)

        let modeContinueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            modeContinueButton.waitForExistence(timeout: 8), "Mode selection page should show the continue button")
        XCTAssertTrue(
            modeContinueButton.isEnabled, "After choosing random playback, the continue button should be enabled")
        tapElement(modeContinueButton)

        XCTAssertTrue(
            waitForSlideshowSettingsButton(app: app, timeout: 25),
            "After entering the playback page, the settings button should be visible"
        )
    }

    func startFilteredFlowFromModeSelection(app: XCUIApplication) {
        let modeFilteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(modeFilteredButton.waitForExistence(timeout: 8))
        modeFilteredButton.tap()

        let modeContinueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(modeContinueButton.waitForExistence(timeout: 8))
        XCTAssertTrue(modeContinueButton.isEnabled)
        modeContinueButton.tap()

        XCTAssertTrue(app.buttons["filterSummary.startPlayback.button"].waitForExistence(timeout: 12))
    }

    @MainActor
    func waitForReadinessMarker(
        app: XCUIApplication, identifier: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let readinessLabel = app.staticTexts[identifier]
        XCTAssertTrue(
            readinessLabel.waitForExistence(timeout: 12),
            "Should expose a readable UI test readiness marker: \(identifier)", file: file, line: line)

        // ui-label-lookup: This checks readiness marker copy after identifier lookup.
        let predicate = NSPredicate(format: "label == %@", "ready")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: readinessLabel)
        let result = XCTWaiter.wait(for: [expectation], timeout: 20)
        XCTAssertEqual(
            result, .completed, "Timed out waiting for the page to finish loading: \(identifier)", file: file,
            line: line)
    }

    func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
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

    func hasAnySettingsRootEntry(app: XCUIApplication) -> Bool {

        app.buttons["settings.item.playback"].exists || app.otherElements["settings.item.playback"].exists
            || app.staticTexts["settings.item.playback"].exists || app.buttons["settings.item.accessProtection"].exists
            || app.otherElements["settings.item.accessProtection"].exists
            || app.staticTexts["settings.item.accessProtection"].exists || app.buttons["settings.item.server"].exists
            || app.otherElements["settings.item.server"].exists || app.staticTexts["settings.item.server"].exists
            || app.buttons["settings.item.cache"].exists || app.otherElements["settings.item.cache"].exists
            || app.staticTexts["settings.item.cache"].exists || app.buttons["settings.item.about"].exists
            || app.otherElements["settings.item.about"].exists || app.staticTexts["settings.item.about"].exists
            || app.staticTexts["settings.playback.title"].exists
            || app.staticTexts["settings.cache.title"].exists
            || app.staticTexts["settings.about.title"].exists
    }

    func hasStableSettingsRootEntry(app: XCUIApplication) -> Bool {

        app.buttons["settings.item.playback"].exists || app.otherElements["settings.item.playback"].exists
            || app.staticTexts["settings.item.playback"].exists || app.buttons["settings.item.accessProtection"].exists
            || app.otherElements["settings.item.accessProtection"].exists
            || app.staticTexts["settings.item.accessProtection"].exists || app.buttons["settings.item.server"].exists
            || app.otherElements["settings.item.server"].exists || app.staticTexts["settings.item.server"].exists
            || app.buttons["settings.item.cache"].exists || app.otherElements["settings.item.cache"].exists
            || app.staticTexts["settings.item.cache"].exists || app.buttons["settings.item.about"].exists
            || app.otherElements["settings.item.about"].exists || app.staticTexts["settings.item.about"].exists
    }

    func preferredNavigationBackButton(app: XCUIApplication) -> XCUIElement? {

        let visibleNavigationButtons = app.navigationBars.buttons.allElementsBoundByIndex
            .filter { button in
                button.exists && button.isHittable
            }

        return
            visibleNavigationButtons
            .filter { $0.identifier == "BackButton" }
            .last ?? visibleNavigationButtons.last
    }

    func isShowSidebarLabel(_ label: String) -> Bool {

        // ui-label-lookup: These are localized system-provided sidebar labels.
        [
            "Show Sidebar",
            "显示边栏",
            "顯示側邊欄",
            "サイドバーを表示",
            "Mostrar barra lateral"
        ].contains(label)
    }

    func waitForAnySettingsRootEntry(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasAnySettingsRootEntry(app: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return hasAnySettingsRootEntry(app: app)
    }

    func assertEnglishSettingsRootLabels(app: XCUIApplication) {

        revealSettingsSidebarIfNeeded(app: app)

        XCTAssertTrue(
            waitForLocalizedElement(
                app,
                identifier: "settings.item.playback",
                label: "Playback Settings",
                timeout: 8
            ),
            "Settings page should show English 'Playback Settings'"
        )
        XCTAssertTrue(
            waitForLocalizedElement(
                app,
                identifier: "settings.item.accessProtection",
                label: "Access Protection",
                timeout: 8
            ),
            "Settings page should show English 'Access Protection'"
        )
        XCTAssertTrue(
            waitForLocalizedElement(
                app,
                identifier: "settings.item.cache",
                label: "Cache Management",
                timeout: 8
            ),
            "Settings page should show English 'Cache Management'"
        )
        XCTAssertTrue(
            waitForLocalizedElement(app, identifier: "settings.item.about", label: "About", timeout: 8),
            "Settings page should show English 'About'"
        )
    }

    func revealSettingsSidebarIfNeeded(app: XCUIApplication) {

        // ui-label-lookup: ToggleSidebar is the system-provided sidebar navigation control.
        let toggleSidebarButton = app.buttons["ToggleSidebar"]
        if toggleSidebarButton.exists,
            toggleSidebarButton.isHittable,
            isShowSidebarLabel(toggleSidebarButton.label)
        {
            toggleSidebarButton.tap()
            _ = waitForAnySettingsRootEntry(app: app, timeout: 2)
        }
    }

    func anyElement(app: XCUIApplication, withLabel label: String) -> XCUIElement {

        app.descendants(matching: .any)
            // ui-label-lookup: This helper is used only for visible copy and localization assertions.
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    func appElement(_ app: XCUIApplication, identifier: String) -> XCUIElement {

        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    func waitForLocalizedElement(
        _ app: XCUIApplication,
        identifier: String,
        label: String,
        timeout: TimeInterval
    ) -> Bool {

        waitUntil(timeout: timeout) {
            let identifiedElement = self.appElement(app, identifier: identifier)
            return identifiedElement.exists && identifiedElement.label == label
                // ui-label-lookup: Fallback preserves the explicit translated-copy assertion.
                || self.anyElement(app: app, withLabel: label).exists
        }
    }

    func currentDeviceTag() -> String {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return "ipad"
        case .phone:
            return "iphone"
        default:
            return "ios"
        }
    }

    @MainActor
    func setOrientation(_ orientation: UIDeviceOrientation, app: XCUIApplication) {
        XCUIDevice.shared.orientation = orientation

        // After rotating, wait until the main entry is visible again before taking a screenshot or tapping on.

        let albumButton = app.buttons["filterSummary.album.button"]
        XCTAssertTrue(albumButton.waitForExistence(timeout: 8))
        XCTAssertTrue(albumButton.isHittable || app.buttons["filterSummary.person.button"].waitForExistence(timeout: 2))
    }

    @MainActor
    func setOrientation(
        _ orientation: UIDeviceOrientation,
        app: XCUIApplication,
        waitForTitleIdentifier titleIdentifier: String
    ) {
        XCUIDevice.shared.orientation = orientation

        let title = app.staticTexts[titleIdentifier]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    @MainActor
    func setOrientation(
        _ orientation: UIDeviceOrientation,
        app: XCUIApplication,
        waitForElementIdentifier identifier: String
    ) {
        XCUIDevice.shared.orientation = orientation

        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
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
