import Foundation
import XCTest

#if os(iOS)
extension FilterSummaryIOSVisualUITests {
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
            shouldForceAutoPlayOff: true,
            shouldPrepareFilterEditorVisuals: false,
            // Double and triple Smart Fill scenes deliberately show no EXIF overlay, so the tone marker only exists on single-photo scenes.
            extraLaunchEnvironment: ["UI_TEST_FORCE_PLAYBACK_DISPLAY_MODE": "singlePhoto"]
        )

        try configureExifDiagnosticFilters(app: app)

        let doneButton = app.buttons["filter.editor.done.button"]
        XCTAssertTrue(
            doneButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Filter editor top bar should show the 'Done' button")
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
            !isEnvironmentFlagEnabled(exifSamplingOverlayDiagnosticRunFlag),
            "EXIF sampling overlay diagnostic screenshots are not part of regular UI regression by default; set \(exifSamplingOverlayDiagnosticRunFlag)=1 to run them explicitly."
        )
        let photoCount = try requireExifDiagnosticAlbumAssetCount()

        let app = try launchIntoFilterEditor(
            colorScheme: "light",
            shouldForceAutoPlayOff: true,
            shouldPrepareFilterEditorVisuals: false,
            shouldShowExifSamplingDebugOverlay: true
        )

        try configureExifDiagnosticFilters(app: app)

        let doneButton = app.buttons["filter.editor.done.button"]
        XCTAssertTrue(
            doneButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Filter editor top bar should show the 'Done' button")
        tapElement(doneButton)

        returnToSlideShowFromSettings(app: app)
        captureExifDiagnosticSlides(
            app: app,
            expectedCount: photoCount,
            screenshotNamePrefix: "ios-exif-sampling-overlay-diagnostic",
            shouldWaitForSamplingOverlay: true
        )
    }

    @MainActor
    func testIOSSlideShowPlaybackEntryHintScreenshot() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "dark",
            shouldDisablePlaybackEntryHint: false
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
            shouldDisablePlaybackEntryHint: false
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
            shouldDisablePlaybackEntryHint: false
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
            shouldDisablePlaybackEntryHint: false
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
            shouldForceEnglishLocalization: true,
            shouldDisablePlaybackEntryHint: false
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
            shouldDisablePlaybackEntryHint: false,
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
            shouldDisablePlaybackEntryHint: false
        )
        let entryHintBanner = app.otherElements["slideshow.entryHint.banner"]

        XCTAssertTrue(
            entryHintBanner.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "On first entering the playback page, the one-time tip should appear first"
        )

        openSettingsFromSlideShow(app: app)
        returnToSlideShowFromSettings(app: app)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: TestWait.seconds(.infrastructure(18))),
            "After returning from settings, the app should be back on the playback page"
        )
        XCTAssertFalse(
            entryHintBanner.waitForExistence(timeout: TestWait.seconds(.product(2))),
            "The one-time tip should not reappear when returning from settings to the playback page in the same first-launch flow"
        )
    }

    @MainActor
    func testIOSSlideShowPlaybackEntryHintDismissesByTappingBubble() throws {
        let app = try launchIntoSlideShow(
            colorScheme: "dark",
            shouldDisablePlaybackEntryHint: false
        )
        let entryHintBanner = app.otherElements["slideshow.entryHint.banner"]
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]

        XCTAssertTrue(
            entryHintBanner.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "On first entering the playback page, the one-time tip should appear first"
        )
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.stateChangeTimeoutSeconds),
            "Playback page should show the play button in the control bar"
        )

        playPauseButton.tap()
        XCTAssertTrue(
            entryHintBanner.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.briefElementTimeoutSeconds),
            "Tapping a control bar button should not hide the bubble"
        )

        entryHintBanner.tap()
        waitForPlaybackEntryHintToDisappear(entryHintBanner)
        XCTAssertFalse(entryHintBanner.exists, "Tapping the tip bubble itself should hide the bubble")
    }
}
extension FilterSummaryIOSVisualUITests {

}
#endif
