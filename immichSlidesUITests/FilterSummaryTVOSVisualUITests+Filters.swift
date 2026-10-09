import XCTest

#if os(tvOS)
extension FilterSummaryTVOSVisualUITests {
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
            filteredButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Mode selection page should show the 'Filtered slideshow' card"
        )
        XCTAssertTrue(
            continueButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Mode selection page should show the 'Continue' button")

        moveFocusToFilteredModeCard()
        XCUIRemote.shared.press(.select)
        waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.22)))
        moveFocusToModeContinueButton()

        for _ in 0..<3 {
            XCUIRemote.shared.press(.up)
            waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.22)))
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.22)))
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
        waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.22)))
        moveFocusToModeContinueButton()

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds),
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
            waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.22)))
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: TestWait.seconds(.product(0.22)))
        }

        let backButton = app.buttons["filterSummary.backToMode.button"]
        let peopleButton = app.buttons["filterSummary.person.button"]

        XCTAssertTrue(
            backButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds),
            "After repeated switching, the 'Back to mode selection' button should still exist")
        XCTAssertTrue(
            peopleButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds),
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
            continueButton.waitForExistence(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.connectionTimeoutSeconds),
            "After injecting the test server config, the app should go straight to the mode selection page")
        startFilteredFlowFromModeSelection(app: app)

        openAlbumFilter(from: app)
        XCTAssertTrue(
            // ui-label-lookup: This lookup asserts the displayed empty album copy.
            waitForElementWithLabelExists(
                app: app, label: "Immich 中还没有相册哦～快去添加一些试试吧！",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Empty album page should show the empty-state text, confirming the no-albums branch was reached"
        )
        let albumBackButton = app.buttons["albumFilter.back.button"]
        XCTAssertTrue(
            albumBackButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Empty album page should show the back button")
        waitForButtonToGainFocus(
            albumBackButton, timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "The back button on the empty album page should be able to get tvOS focus")
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-empty-album-filter-back-focused")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            app.buttons["filterSummary.person.button"].waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After pressing Select to go back from the empty album page, the filter summary page should be shown again"
        )

        openPersonFilter(from: app)
        XCTAssertTrue(
            // ui-label-lookup: This lookup asserts the displayed empty people copy.
            waitForElementWithLabelExists(
                app: app, label: "Immich 中还没有人物",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Empty person page should show the empty-state text, confirming the no-people branch was reached"
        )
        let personBackButton = app.buttons["personFilter.back.button"]
        XCTAssertTrue(
            personBackButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Empty person page should show the back button")
        waitForButtonToGainFocus(
            personBackButton, timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "The back button on the empty person page should be able to get tvOS focus")
        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-empty-person-filter-back-focused")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            app.buttons["filterSummary.album.button"].waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
        waitForAnyAlbumTopBarButtonToGainFocus(
            app: app, timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds)
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
            firstCard.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Album filter page should render at least the first album card")
        XCTAssertTrue(
            secondCard.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Album filter page should render at least a second album card to verify horizontal focus movement")

        waitForElementToGainFocus(
            firstCard,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "When the album filter page opens, default focus should land on the first album card"
        )

        XCUIRemote.shared.press(.right)
        waitForElementToGainFocus(
            secondCard,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
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
            secondCard.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Album filter page should render at least a second album card")

        XCUIRemote.shared.press(.right)
        waitForElementToGainFocus(
            secondCard,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After moving right, focus should land on the second album card"
        )

        XCUIRemote.shared.press(.select)
        // ui-label-lookup: This checks the localized accessibility value for selected and focused state.
        waitForElementValue(
            secondCard,
            expectedValue: "已选中，已聚焦",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
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
            secondCard.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Album filter page should render at least a second album card")

        XCUIRemote.shared.press(.right)
        waitForElementToGainFocus(
            secondCard,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After moving right, focus should land on the second album card"
        )

        XCUIRemote.shared.press(.up)
        waitForAnyAlbumTopBarButtonToGainFocus(
            app: app, timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds)
    }

    @MainActor
    func testTVOSAlbumFilterUpFromThirdCardCanReachTopBar() throws {
        let app = try launchIntoFilterSummary()
        openAlbumFilter(from: app)
        waitForAlbumFilterReady(app: app)

        let thirdCard = try albumCardInServerOrder(at: 2, in: app)
        XCTAssertTrue(
            thirdCard.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Album filter page should render at least a third album card")

        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        waitForElementToGainFocus(
            thirdCard,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After moving right twice, focus should land on the third album card"
        )

        XCUIRemote.shared.press(.up)
        waitForAnyAlbumTopBarButtonToGainFocus(
            app: app, timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds)
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
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
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
            firstCard.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Person filter page should render at least the first person card")

        waitForElementToGainFocus(
            firstCard,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "When the person filter page opens, default focus should land on the first person card"
        )

        XCUIRemote.shared.press(.playPause)
        // ui-label-lookup: This checks the localized accessibility value for selected solo playback state.
        waitForElementValue(
            firstCard,
            expectedValue: "已选中，单人模式，已聚焦",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
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
            firstCard.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "English person filter page should render at least the first person card")

        waitForElementToGainFocus(
            firstCard,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage:
                "When the English person filter page opens, default focus should land on the first person card"
        )

        XCUIRemote.shared.press(.playPause)
        waitForElementValue(
            firstCard,
            expectedValue: "Selected, Solo Mode, Focused",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
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
            firstCard.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Person filter page should render at least the first primary person card")
        XCTAssertTrue(
            secondCard.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Person filter page should render at least a second primary person card to verify horizontal focus movement"
        )

        waitForElementToGainFocus(
            firstCard,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage:
                "When the person filter page opens, default focus should land on the first primary person card"
        )

        XCUIRemote.shared.press(.right)
        waitForElementToGainFocus(
            secondCard,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
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
            secondCard.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Person filter page should render at least a second person card")

        XCUIRemote.shared.press(.right)
        waitForElementToGainFocus(
            secondCard,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After moving right, focus should land on the second person card"
        )

        XCUIRemote.shared.press(.select)
        // ui-label-lookup: This checks the localized accessibility value for selected and focused state.
        waitForElementValue(
            secondCard,
            expectedValue: "已选中，普通模式，已聚焦",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage:
                "Pressing Select on the second person card should add that person to the filter and keep normal mode"
        )
    }
}
extension FilterSummaryTVOSVisualUITests {

}
#endif
