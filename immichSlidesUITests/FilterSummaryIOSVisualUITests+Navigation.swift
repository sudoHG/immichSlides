import Foundation
import XCTest

#if os(iOS)
extension FilterSummaryIOSVisualUITests {
    @MainActor
    func openSettingsFromSlideShow(app: XCUIApplication) {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            waitForSlideshowSettingsButton(
                app: app, timeout: FilterSummaryIOSVisualUITestsWaitTiming.screenTransitionTimeoutSeconds),
            "Playback page should show the settings button")

        tapElement(settingsButton)

        XCTAssertTrue(
            waitForAnySettingsRootEntry(
                app: app, timeout: FilterSummaryIOSVisualUITestsWaitTiming.navigationTimeoutSeconds),
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
            backButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Top bar should still show the back button", file: file, line: line
        )
        XCTAssertTrue(
            selectAllButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Top bar should still show the select all button", file: file,
            line: line)
        XCTAssertTrue(
            clearButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Top bar should still show the clear button", file: file,
            line: line)
        XCTAssertTrue(
            title.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Top bar should still show the page title", file: file, line: line)
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
        shouldForceEnglishLocalization: Bool = false,
        expectedTitleText: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let titleText = expectedTitleText ?? (shouldForceEnglishLocalization ? "Filter Albums" : "筛选相册")
        let title = app.staticTexts["filterTopBar.title"]
        let backButton = app.buttons["albumFilter.back.button"]
        let selectAllButton = app.buttons["albumFilter.selectAll.button"]
        let clearButton = app.buttons["albumFilter.clear.button"]

        XCTAssertTrue(
            title.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
        shouldForceEnglishLocalization: Bool = false,
        expectedTitleText: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let titleText = expectedTitleText ?? (shouldForceEnglishLocalization ? "Filter People" : "筛选人物")
        let title = app.staticTexts["filterTopBar.title"]
        let backButton = app.buttons["personFilter.back.button"]
        let selectAllButton = app.buttons["personFilter.selectAll.button"]
        let clearButton = app.buttons["personFilter.clear.button"]

        XCTAssertTrue(
            title.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
                if candidate.waitForExistence(
                    timeout: FilterSummaryIOSVisualUITestsWaitTiming.briefElementTimeoutSeconds)
                {
                    tapElement(candidate)
                    return
                }
            }

            let fallback = app.descendants(matching: .any).matching(identifier: sectionID).firstMatch
            if fallback.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.briefElementTimeoutSeconds) {
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
                RunLoop.current.run(
                    until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.readbackPollSeconds))
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
    func openSettingsAboutPage(app: XCUIApplication) {
        openSettingsSection(
            app: app,
            sectionID: "settings.item.about"
        )
    }

    @MainActor
    // ui-label-lookup: This helper verifies the translated About page copy.
    func assertSettingsAboutPageLoaded(
        app: XCUIApplication,
        shouldForceEnglishLocalization: Bool = false
    ) {
        let appInfoTitle = shouldForceEnglishLocalization ? "App Information" : "应用信息"
        let appNameTitle = shouldForceEnglishLocalization ? "App Name" : "应用名称"
        let versionTitle = shouldForceEnglishLocalization ? "Version" : "版本号"
        let platformTitle = shouldForceEnglishLocalization ? "Platform" : "运行平台"
        let unofficialNoticeTitle = shouldForceEnglishLocalization ? "Unofficial Notice" : "非官方声明"
        let unofficialNoticeText =
            shouldForceEnglishLocalization
            ? "immichSlides is an independently developed unofficial app. It is not the official Immich app and is not endorsed, sponsored, or approved by Immich."
            : "immichSlides 是独立开发的非官方应用，不是 Immich 官方应用，也未获得 Immich 官方背书、赞助或认可。"
        let feedbackTitle = shouldForceEnglishLocalization ? "Feedback & Support" : "反馈与支持"
        let feedbackHintText =
            shouldForceEnglishLocalization
            ? "To report an issue, note the version number and steps to reproduce."
            : "如需反馈问题，可先记录版本号与复现步骤。"
        let privacySectionTitle = shouldForceEnglishLocalization ? "Privacy & Protection" : "隐私与保护"
        let privacyEntryTitle = shouldForceEnglishLocalization ? "Privacy Policy" : "隐私政策"
        let privacyEntrySubtitle =
            shouldForceEnglishLocalization
            ? "Open the full policy text in your browser."
            : "在浏览器中查看完整政策文本。"

        XCTAssertTrue(
            anyElement(app: app, withLabel: appInfoTitle).waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the app information title")
        XCTAssertTrue(
            anyElement(app: app, withLabel: appNameTitle).waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the app name title")
        XCTAssertTrue(
            anyElement(app: app, withLabel: versionTitle).waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the version title")
        XCTAssertTrue(
            anyElement(app: app, withLabel: platformTitle).waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the platform title")
        XCTAssertTrue(
            anyElement(app: app, withLabel: unofficialNoticeTitle).waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the unofficial notice title")
        XCTAssertTrue(
            anyElement(app: app, withLabel: unofficialNoticeText).waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the unofficial notice text")
        XCTAssertTrue(
            anyElement(app: app, withLabel: feedbackTitle).waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the feedback and support title")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "settings.about.feedback.email.link")
                .firstMatch
                .waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the real support email entry"
        )
        XCTAssertTrue(
            anyElement(app: app, withLabel: feedbackHintText).waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the feedback hint")
        XCTAssertTrue(
            anyElement(app: app, withLabel: privacySectionTitle).waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the privacy and protection title")
        XCTAssertTrue(
            anyElement(app: app, withLabel: privacyEntryTitle).waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the privacy policy entry title")
        XCTAssertTrue(
            anyElement(app: app, withLabel: privacyEntrySubtitle).waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "About page should show the privacy policy entry description")

        if shouldForceEnglishLocalization {

            XCTAssertTrue(
                anyElement(app: app, withLabel: "App Information").waitForExistence(
                    timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
                "English About page should show 'App Information'"
            )
            XCTAssertTrue(
                anyElement(app: app, withLabel: "Feedback & Support").waitForExistence(
                    timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
                "English About page should show 'Feedback & Support'"
            )
            XCTAssertTrue(
                anyElement(app: app, withLabel: "Unofficial Notice").waitForExistence(
                    timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
                "English About page should show 'Unofficial Notice'"
            )
            XCTAssertTrue(
                anyElement(app: app, withLabel: "Privacy & Protection").waitForExistence(
                    timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
                "English About page should show 'Privacy & Protection'"
            )
            XCTAssertTrue(
                anyElement(app: app, withLabel: "Privacy Policy").waitForExistence(
                    timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
                "English About page should show 'Privacy Policy'"
            )
            XCTAssertTrue(
                anyElement(
                    app: app,
                    withLabel: "View the current version, runtime environment, and feedback guidance."
                ).waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
                .waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.shortInteractionTimeoutSeconds),
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
        if aboutBackButton.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.stateChangeTimeoutSeconds)
        {
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
            if openSourceButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.briefElementTimeoutSeconds),
                openSourceButton.isHittable
            {
                return openSourceButton
            }

            let openSourceLink = app.descendants(matching: .any)
                .matching(identifier: "settings.about.opensource.link")
                .firstMatch
            if openSourceLink.exists, openSourceLink.isHittable {
                return openSourceLink
            }

            app.swipeUp()
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.snapshotPollSeconds))
        }

        return nil
    }

    @MainActor
    func returnToSlideShowFromSettings(app: XCUIApplication) {

        for _ in 0..<3 {
            if app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.readbackTimeoutSeconds)
            {
                return
            }

            let backButton = app.navigationBars.buttons.firstMatch
            if backButton.exists && backButton.isHittable {
                backButton.tap()
                continue
            }
        }

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.elementAppearanceTimeoutSeconds),
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
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.readbackPollSeconds))
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
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.selectionPollSeconds))
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
                RunLoop.current.run(
                    until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.readbackPollSeconds))
                if app.keyboards.count == 0 {
                    return
                }
            }
        }

        // On some OS versions the keyboard toolbar is not in the XCTest tree, so it cannot be the only check.

        let toolbarDoneButton = app.buttons["server.keyboard.done.button"]
        if toolbarDoneButton.exists && toolbarDoneButton.isHittable {
            toolbarDoneButton.tap()
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.readbackPollSeconds))
            if app.keyboards.count == 0 {
                return
            }
        }

        let safeTopTapArea = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06))
        safeTopTapArea.tap()
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.readbackPollSeconds))

        if app.keyboards.count == 0 {
            return
        }

        let navigationBar = app.navigationBars.firstMatch
        if navigationBar.exists {
            navigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.readbackPollSeconds))
        }
    }

    func startRandomPlaybackFromModeSelection(app: XCUIApplication) {

        let modeRandomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(
            modeRandomButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Mode selection page should show the 'Shuffle All Photos' entry")
        tapElement(modeRandomButton)

        let modeContinueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            modeContinueButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Mode selection page should show the continue button")
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

        XCTAssertTrue(
            app.buttons["filterSummary.startPlayback.button"].waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.screenTransitionTimeoutSeconds))
    }

    @MainActor
    func waitForReadinessMarker(
        app: XCUIApplication, identifier: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let readinessLabel = app.staticTexts[identifier]
        XCTAssertTrue(
            readinessLabel.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.screenTransitionTimeoutSeconds),
            "Should expose a readable UI test readiness marker: \(identifier)", file: file, line: line)

        // ui-label-lookup: This checks readiness marker copy after identifier lookup.
        let predicate = NSPredicate(format: "label == %@", "ready")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: readinessLabel)
        let result = XCTWaiter.wait(
            for: [expectation], timeout: FilterSummaryIOSVisualUITestsWaitTiming.playbackControlTimeoutSeconds)
        XCTAssertEqual(
            result, .completed, "Timed out waiting for the page to finish loading: \(identifier)", file: file,
            line: line)
    }

    func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.pollIntervalSeconds))
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
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.pollIntervalSeconds))
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
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "Settings page should show English 'Playback Settings'"
        )
        XCTAssertTrue(
            waitForLocalizedElement(
                app,
                identifier: "settings.item.accessProtection",
                label: "Access Protection",
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "Settings page should show English 'Access Protection'"
        )
        XCTAssertTrue(
            waitForLocalizedElement(
                app,
                identifier: "settings.item.cache",
                label: "Cache Management",
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "Settings page should show English 'Cache Management'"
        )
        XCTAssertTrue(
            waitForLocalizedElement(
                app, identifier: "settings.item.about", label: "About",
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
            _ = waitForAnySettingsRootEntry(
                app: app, timeout: FilterSummaryIOSVisualUITestsWaitTiming.readbackTimeoutSeconds)
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
        XCTAssertTrue(
            albumButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(
            albumButton.isHittable
                || app.buttons["filterSummary.person.button"].waitForExistence(
                    timeout: FilterSummaryIOSVisualUITestsWaitTiming.readbackTimeoutSeconds)
        )
    }

    @MainActor
    func setOrientation(
        _ orientation: UIDeviceOrientation,
        app: XCUIApplication,
        waitForTitleIdentifier titleIdentifier: String
    ) {
        XCUIDevice.shared.orientation = orientation

        let title = app.staticTexts[titleIdentifier]
        XCTAssertTrue(
            title.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.snapshotPollSeconds))
    }

    @MainActor
    func setOrientation(
        _ orientation: UIDeviceOrientation,
        app: XCUIApplication,
        waitForElementIdentifier identifier: String
    ) {
        XCUIDevice.shared.orientation = orientation

        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(
            element.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds))
        RunLoop.current.run(
            until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.snapshotPollSeconds))
    }
}
#endif
