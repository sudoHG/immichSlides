import Foundation
import XCTest

#if os(iOS)
extension FilterSummaryIOSVisualUITests {
    @MainActor
    func launchIntoOnboardingFirstBoot(
        colorScheme: String,
        dynamicTypeSize: String? = nil,
        shouldForceEnglishLocalization: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil,
        shouldDisableDebugFillConfigButton: Bool = true
    ) -> XCUIApplication {

        let app: XCUIApplication
        if let acceptanceLocale {
            app = makeLocalizedLaunchApp(
                colorScheme: colorScheme,
                acceptanceLocale: acceptanceLocale,
                dynamicTypeSize: dynamicTypeSize,
                shouldDisableDebugFillConfigButton: shouldDisableDebugFillConfigButton
            )
        } else if shouldForceEnglishLocalization {
            app = makeLaunchApp(
                colorScheme: colorScheme,
                shouldForceEnglishLocalization: true,
                dynamicTypeSize: dynamicTypeSize,
                shouldDisableDebugFillConfigButton: shouldDisableDebugFillConfigButton
            )
        } else {
            app = makeChineseLaunchApp(
                colorScheme: colorScheme,
                dynamicTypeSize: dynamicTypeSize,
                shouldDisableDebugFillConfigButton: shouldDisableDebugFillConfigButton
            )
        }
        app.launch()
        return app
    }

    @MainActor
    func launchIntoOnboardingModeSelection(
        colorScheme: String,
        dynamicTypeSize: String? = nil,
        shouldForceEnglishLocalization: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil
    ) throws -> XCUIApplication {

        let app: XCUIApplication
        if let acceptanceLocale {
            app = makeLocalizedLaunchApp(
                colorScheme: colorScheme,
                acceptanceLocale: acceptanceLocale,
                dynamicTypeSize: dynamicTypeSize
            )
        } else if shouldForceEnglishLocalization {
            app = makeLaunchApp(
                colorScheme: colorScheme,
                shouldForceEnglishLocalization: true,
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
            continueButton.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.connectionTimeoutSeconds),
            "After injecting the test server config, the app should go straight to the mode selection page")
        return app
    }

    @MainActor
    func launchIntoOnboardingFilterSummary(
        colorScheme: String,
        dynamicTypeSize: String? = nil,
        shouldForceEnglishLocalization: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil
    ) throws -> XCUIApplication {

        let app = try launchIntoOnboardingModeSelection(
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            shouldForceEnglishLocalization: shouldForceEnglishLocalization,
            acceptanceLocale: acceptanceLocale
        )

        let modeFilteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(
            modeFilteredButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        modeFilteredButton.tap()

        let modeContinueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            modeContinueButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(modeContinueButton.isEnabled)
        modeContinueButton.tap()

        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startPlaybackButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.screenTransitionTimeoutSeconds))
        XCTAssertTrue(
            app.buttons["filterSummary.album.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.navigationTimeoutSeconds))
        XCTAssertTrue(
            app.buttons["filterSummary.person.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.navigationTimeoutSeconds))
        assertFilterSummaryUsesOnlyTopBackButton(app: app)

        // Short wait so the screenshot does not catch a mid-transition frame.
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.playbackEntrySettleSeconds))
        return app
    }

    func requireIOSDestination() throws {
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
        shouldForceEnglishLocalization: Bool = false,
        dynamicTypeSize: String? = nil,
        shouldDisablePlaybackEntryHint: Bool = true,
        shouldDisableDebugFillConfigButton: Bool = true,
        shouldForceAutoPlayOff: Bool = false,
        shouldShowExifSamplingDebugOverlay: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_COLOR_SCHEME"] = colorScheme
        if shouldDisableDebugFillConfigButton {

            app.launchEnvironment["UI_TEST_DISABLE_DEBUG_FILL_APIKEY_BUTTON"] = "1"
        }
        if shouldDisablePlaybackEntryHint {
            app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        }
        if shouldForceAutoPlayOff {

            app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        }
        if shouldShowExifSamplingDebugOverlay {

            app.launchEnvironment["UI_TEST_SHOW_EXIF_SAMPLING_DEBUG"] = "1"
        }
        if let dynamicTypeSize {

            app.launchEnvironment["UI_TEST_DYNAMIC_TYPE_SIZE"] = dynamicTypeSize
        }
        if shouldForceEnglishLocalization {

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
        shouldDisablePlaybackEntryHint: Bool = true,
        shouldDisableDebugFillConfigButton: Bool = true,
        shouldForceAutoPlayOff: Bool = false,
        shouldShowExifSamplingDebugOverlay: Bool = false
    ) -> XCUIApplication {

        let app = makeLaunchApp(
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            shouldDisablePlaybackEntryHint: shouldDisablePlaybackEntryHint,
            shouldDisableDebugFillConfigButton: shouldDisableDebugFillConfigButton,
            shouldForceAutoPlayOff: shouldForceAutoPlayOff,
            shouldShowExifSamplingDebugOverlay: shouldShowExifSamplingDebugOverlay
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
        shouldDisablePlaybackEntryHint: Bool = true,
        shouldDisableDebugFillConfigButton: Bool = true,
        shouldForceAutoPlayOff: Bool = false,
        shouldShowExifSamplingDebugOverlay: Bool = false
    ) -> XCUIApplication {

        let app = makeLaunchApp(
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            shouldDisablePlaybackEntryHint: shouldDisablePlaybackEntryHint,
            shouldDisableDebugFillConfigButton: shouldDisableDebugFillConfigButton,
            shouldForceAutoPlayOff: shouldForceAutoPlayOff,
            shouldShowExifSamplingDebugOverlay: shouldShowExifSamplingDebugOverlay
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
        shouldForceEnglishLocalization: Bool = false,
        dynamicTypeSize: String? = nil,
        shouldDisablePlaybackEntryHint: Bool = true,
        shouldPrepareFilterEditorVisuals: Bool = false,
        shouldForceAutoPlayOff: Bool = false,
        shouldShowExifSamplingDebugOverlay: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil
    ) throws -> XCUIApplication {

        let app: XCUIApplication
        if let acceptanceLocale {
            app = makeLocalizedLaunchApp(
                colorScheme: colorScheme,
                acceptanceLocale: acceptanceLocale,
                dynamicTypeSize: dynamicTypeSize,
                shouldDisablePlaybackEntryHint: shouldDisablePlaybackEntryHint,
                shouldForceAutoPlayOff: shouldForceAutoPlayOff,
                shouldShowExifSamplingDebugOverlay: shouldShowExifSamplingDebugOverlay
            )
        } else if shouldForceEnglishLocalization {
            app = makeLaunchApp(
                colorScheme: colorScheme,
                shouldForceEnglishLocalization: true,
                dynamicTypeSize: dynamicTypeSize,
                shouldDisablePlaybackEntryHint: shouldDisablePlaybackEntryHint,
                shouldForceAutoPlayOff: shouldForceAutoPlayOff,
                shouldShowExifSamplingDebugOverlay: shouldShowExifSamplingDebugOverlay
            )
        } else {

            app = makeChineseLaunchApp(
                colorScheme: colorScheme,
                dynamicTypeSize: dynamicTypeSize,
                shouldDisablePlaybackEntryHint: shouldDisablePlaybackEntryHint,
                shouldForceAutoPlayOff: shouldForceAutoPlayOff,
                shouldShowExifSamplingDebugOverlay: shouldShowExifSamplingDebugOverlay
            )
        }
        let config = try requireTestServerConfig()
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        try requireServerAlbumAndPerson()
        app.launchEnvironment["UI_TEST_PREPARE_FILTER_SUMMARY_VISUAL_SELECTIONS"] = "1"
        if shouldPrepareFilterEditorVisuals {
            app.launchEnvironment["UI_TEST_PREPARE_FILTER_EDITOR_VISUAL_SELECTIONS"] = "1"
        }
        app.launch()

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.connectionTimeoutSeconds),
            "After injecting the test server config, the app should go straight to the mode selection page")
        startFilteredFlowFromModeSelection(app: app)

        let albumButton = app.buttons["filterSummary.album.button"]
        let peopleButton = app.buttons["filterSummary.person.button"]
        XCTAssertTrue(
            albumButton.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.navigationTimeoutSeconds))
        XCTAssertTrue(
            peopleButton.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.navigationTimeoutSeconds))
        assertFilterSummaryUsesOnlyTopBackButton(app: app)
        return app
    }

    @MainActor
    func launchIntoRandomSlideShow(
        colorScheme: String,
        dynamicTypeSize: String? = nil,
        shouldDisablePlaybackEntryHint: Bool = true,
        shouldForceAutoPlayOff: Bool = false,
        shouldShowExifSamplingDebugOverlay: Bool = false
    ) throws -> XCUIApplication {

        let app = makeChineseLaunchApp(
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            shouldDisablePlaybackEntryHint: shouldDisablePlaybackEntryHint,
            shouldForceAutoPlayOff: shouldForceAutoPlayOff,
            shouldShowExifSamplingDebugOverlay: shouldShowExifSamplingDebugOverlay
        )

        let config = try requireTestServerConfig()
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey

        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launch()

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.connectionTimeoutSeconds),
            "After injecting the test server config, the app should go straight to the mode selection page"
        )

        startRandomPlaybackFromModeSelection(app: app)

        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "After random playback opens the playback page, the play/pause button should be visible"
        )

        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.playbackEntrySettleSeconds))
        return app
    }

    func assertFilterSummaryUsesOnlyTopBackButton(
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {

        let globalBackButton = app.buttons["global.back.button"]
        XCTAssertTrue(
            globalBackButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
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
            wizardTitle.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The top of the page should show the shared setup wizard header",
            file: file,
            line: line
        )
        XCTAssertEqual(wizardTitle.label, expectedWizardTitle, file: file, line: line)

        let pageTitle = app.staticTexts[pageTitleIdentifier]
        XCTAssertTrue(
            pageTitle.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
            banner.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
            "On first entering the playback page, the one-time tip bubble should appear",
            file: file,
            line: line
        )
        XCTAssertTrue(
            title.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.readbackTimeoutSeconds),
            "The tip should show its main text",
            file: file,
            line: line
        )
        XCTAssertEqual(title.label, expectedTitle, file: file, line: line)
        XCTAssertTrue(
            action.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.readbackTimeoutSeconds),
            "The tip should show the action hint",
            file: file,
            line: line
        )
        XCTAssertEqual(action.label, expectedAction, file: file, line: line)
        XCTAssertTrue(
            keycap.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.readbackTimeoutSeconds),
            "The tip should show the dismiss target as a separate keycap",
            file: file,
            line: line
        )
        XCTAssertEqual(keycap.label, expectedKeycap, file: file, line: line)
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.stateChangeTimeoutSeconds),
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
            FilterSummaryIOSVisualUITestsCalibration.maximumTipGapPoints,
            "The tip's tail should sit right above the settings button, not float. gap=\(bubbleToSettingsGap), banner=\(bannerFrame), settings=\(settingsButtonFrame)",
            file: file,
            line: line
        )

        let maxSingleLineHeight =
            banner.frame.height * FilterSummaryIOSVisualUITestsCalibration.singleLineBannerHeightFraction
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
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.pollIntervalSeconds))
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
            title.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
            FilterSummaryIOSVisualUITestsCalibration.titlePositionTolerancePoints,
            "\(pageName) main title vertical position should match step 1",
            file: file,
            line: line
        )
    }

    @MainActor
    func launchIntoSlideShow(
        colorScheme: String,
        shouldForceEnglishLocalization: Bool = false,
        dynamicTypeSize: String? = nil,
        shouldDisablePlaybackEntryHint: Bool = true,
        shouldPrepareFilterEditorVisuals: Bool = false,
        shouldForceAutoPlayOff: Bool = false,
        shouldShowExifSamplingDebugOverlay: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil
    ) throws -> XCUIApplication {

        let app = try launchIntoFilterSummary(
            colorScheme: colorScheme,
            shouldForceEnglishLocalization: shouldForceEnglishLocalization,
            dynamicTypeSize: dynamicTypeSize,
            shouldDisablePlaybackEntryHint: shouldDisablePlaybackEntryHint,
            shouldPrepareFilterEditorVisuals: shouldPrepareFilterEditorVisuals,
            shouldForceAutoPlayOff: shouldForceAutoPlayOff,
            shouldShowExifSamplingDebugOverlay: shouldShowExifSamplingDebugOverlay,
            acceptanceLocale: acceptanceLocale
        )
        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startPlaybackButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Filter summary page should show the 'Start Playback' button")
        // Start stays disabled until the page has loaded and selected the first album from the server.
        waitForReadinessMarker(app: app, identifier: "filterSummary.visual.ready")
        XCTAssertTrue(
            startPlaybackButton.isEnabled, "The 'Start Playback' button on the filter summary page should be enabled")
        startPlaybackButton.tap()

        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.playbackControlTimeoutSeconds),
            "After starting playback, the playback page should open and show the control bar")

        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Playback page should show the play/pause button")

        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.playbackEntrySettleSeconds))
        return app
    }

    @MainActor
    func launchIntoFilterEditor(
        colorScheme: String,
        dynamicTypeSize: String? = nil,
        shouldForceAutoPlayOff: Bool = false,
        shouldPrepareFilterEditorVisuals: Bool = true,
        shouldShowExifSamplingDebugOverlay: Bool = false,
        shouldForceEnglishLocalization: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil
    ) throws -> XCUIApplication {

        let app = try launchIntoSlideShow(
            colorScheme: colorScheme,
            shouldForceEnglishLocalization: shouldForceEnglishLocalization,
            dynamicTypeSize: dynamicTypeSize,
            shouldPrepareFilterEditorVisuals: shouldPrepareFilterEditorVisuals,
            shouldForceAutoPlayOff: shouldForceAutoPlayOff,
            shouldShowExifSamplingDebugOverlay: shouldShowExifSamplingDebugOverlay,
            acceptanceLocale: acceptanceLocale
        )

        openSettingsFromSlideShow(app: app)
        openSettingsSection(
            app: app,
            sectionID: "settings.item.playback"
        )

        let filterConfigButton = app.buttons["settings.playback.filterConfig.button"]
        XCTAssertTrue(
            filterConfigButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Playback settings page should show the 'Edit Filters' entry"
        )
        XCTAssertTrue(
            waitForElementToBecomeHittable(
                filterConfigButton, app: app,
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.elementAppearanceTimeoutSeconds),
            "The 'Edit Filters' entry on the playback settings page should scroll into a tappable position"
        )
        tapElement(filterConfigButton)

        let albumEntry = app.buttons["filter.editor.album.entry"]
        let personEntry = app.buttons["filter.editor.person.entry"]
        XCTAssertTrue(
            albumEntry.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Filter editor should show the album entry")
        XCTAssertTrue(
            personEntry.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Filter editor should show the people entry")

        if shouldPrepareFilterEditorVisuals {
            waitForReadinessMarker(app: app, identifier: "filterEditor.visual.ready")
        }
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.snapshotPollSeconds))
        return app
    }

    @MainActor
    func launchIntoAlbumFilterFromSummary() throws -> XCUIApplication {
        let app = try launchIntoFilterSummary(colorScheme: "dark")
        let albumButton = app.buttons["filterSummary.album.button"]
        XCTAssertTrue(
            albumButton.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.navigationTimeoutSeconds))
        tapElement(albumButton)
        XCTAssertTrue(
            app.buttons["albumFilter.back.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.connectionTimeoutSeconds))
        return app
    }

    @MainActor
    func launchIntoAlbumFilterPage(
        colorScheme: String,
        dynamicTypeSize: String?,
        shouldForceEnglishLocalization: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil
    ) throws -> XCUIApplication {
        let app = try launchIntoFilterEditor(
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            shouldPrepareFilterEditorVisuals: acceptanceLocale == nil && shouldForceEnglishLocalization == false,
            shouldForceEnglishLocalization: shouldForceEnglishLocalization,
            acceptanceLocale: acceptanceLocale
        )

        setOrientation(.portrait, app: app, waitForTitleIdentifier: "filterEditor.page.title")

        let albumEntry = app.buttons["filter.editor.album.entry"]
        XCTAssertTrue(
            albumEntry.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Filter editor should show the album entry")
        tapElement(albumEntry)

        assertInAlbumFilterEditorPage(
            app: app,
            shouldForceEnglishLocalization: shouldForceEnglishLocalization,
            expectedTitleText: acceptanceLocale?.albumFilterTitle
        )
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.snapshotPollSeconds))
        return app
    }

    @MainActor
    func launchIntoPersonFilterPage(
        colorScheme: String,
        dynamicTypeSize: String?,
        shouldForceEnglishLocalization: Bool = false,
        acceptanceLocale: LocalizedAcceptanceLocale? = nil
    ) throws -> XCUIApplication {
        let app = try launchIntoFilterEditor(
            colorScheme: colorScheme,
            dynamicTypeSize: dynamicTypeSize,
            shouldPrepareFilterEditorVisuals: acceptanceLocale == nil && shouldForceEnglishLocalization == false,
            shouldForceEnglishLocalization: shouldForceEnglishLocalization,
            acceptanceLocale: acceptanceLocale
        )

        setOrientation(.portrait, app: app, waitForTitleIdentifier: "filterEditor.page.title")

        let personEntry = app.buttons["filter.editor.person.entry"]
        XCTAssertTrue(
            personEntry.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
            "Filter editor should show the people entry")
        tapElement(personEntry)

        assertInPersonFilterEditorPage(
            app: app,
            shouldForceEnglishLocalization: shouldForceEnglishLocalization,
            expectedTitleText: acceptanceLocale?.personFilterTitle
        )
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.snapshotPollSeconds))
        return app
    }
}
#endif
