import Foundation
import XCTest

#if os(iOS)
extension FilterSummaryIOSVisualUITests {
    @MainActor
    func configureExifDiagnosticFilters(app: XCUIApplication) throws {

        clearAllPeopleSelections(app: app)
        try selectOnlyExifDiagnosticAlbum(app: app)

        let personEntry = app.buttons["filter.editor.person.entry"]
        XCTAssertTrue(
            personEntry.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After returning to the filter editor, the people entry should still be visible")

        let albumEntry = app.buttons["filter.editor.album.entry"]
        XCTAssertTrue(
            albumEntry.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After returning to the filter editor, the album entry should still be visible")
        attachScreenshot(app: app, name: "ios-exif-diagnostic-filter-configured")
    }

    @MainActor
    func clearAllPeopleSelections(app: XCUIApplication) {
        let personEntry = app.buttons["filter.editor.person.entry"]
        XCTAssertTrue(
            personEntry.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Filter editor should show the people entry")
        tapElement(personEntry)

        assertInPersonFilterEditorPage(app: app)

        let clearButton = app.buttons["personFilter.clear.button"]
        XCTAssertTrue(
            clearButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "People filter page should show the clear button")
        tapElement(clearButton)

        let backButton = app.buttons["personFilter.back.button"]
        XCTAssertTrue(
            backButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "People filter page should show the back button")
        tapElement(backButton)
    }

    @MainActor
    func selectOnlyExifDiagnosticAlbum(app: XCUIApplication) throws {
        let albumEntry = app.buttons["filter.editor.album.entry"]
        XCTAssertTrue(
            albumEntry.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Filter editor should show the album entry")
        tapElement(albumEntry)

        assertInAlbumFilterEditorPage(app: app)

        let clearButton = app.buttons["albumFilter.clear.button"]
        XCTAssertTrue(
            clearButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Album filter page should show the clear button")
        tapElement(clearButton)

        let diagnosticAlbumButton = waitForAlbumFilterButton(
            app: app,
            albumID: try requireExifDiagnosticAlbumID(),
            timeout: FilterSummaryIOSVisualUITestsWaitTiming.screenTransitionTimeoutSeconds
        )
        guard diagnosticAlbumButton.exists else {
            throw XCTSkip(
                "The test server has no EXIF panel diagnostic album; skipping this diagnostic screenshot, which depends on fixed test data."
            )
        }
        tapElement(diagnosticAlbumButton)

        let backButton = app.buttons["albumFilter.back.button"]
        XCTAssertTrue(
            backButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Album filter page should show the back button")
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
            RunLoop.current.run(
                until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.controlSettleSeconds))
        }

        return albumButton
    }

    @MainActor
    func captureExifDiagnosticSlides(
        app: XCUIApplication,
        expectedCount: Int,
        screenshotNamePrefix: String = "ios-exif-diagnostic",
        shouldWaitForSamplingOverlay: Bool = false
    ) {
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPauseButton.waitForExistence(
                timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After returning to the playback page, the play/pause button should be visible")
        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryIOSVisualUITestsWaitTiming.stateChangeTimeoutSeconds) {
                ((playPauseButton.value as? String) ?? "").lowercased() == "play"
            },
            "In diagnostic mode autoplay should be off, and the middle control bar button should be in the 'play' state"
        )

        for index in 0..<expectedCount {
            XCTAssertTrue(
                waitForSlideshowSettingsButton(
                    app: app, timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
                "Before each screenshot, the playback control bar should wake up reliably"
            )

            if shouldWaitForSamplingOverlay {
                XCTAssertTrue(
                    waitForExifSamplingDebugOverlay(
                        app: app, timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
                    "In sampling-region diagnostic mode, the playback page should render the reconstructed sampling image, not stay in the loading state"
                )
            }
            let toneLabel = currentExifToneDebugLabel(app: app)
            attachScreenshot(
                app: app,
                name: "\(screenshotNamePrefix)-\(String(format: "%02d", index + 1))-\(toneLabel)"
            )

            guard index < expectedCount - 1 else { continue }

            if shouldWaitForSamplingOverlay {
                XCTAssertTrue(
                    waitForSlideshowSettingsButton(
                        app: app, timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
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
                waitForSlideshowSettingsButton(
                    app: app, timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
                "Before retrying next, the playback control bar should wake up again"
            )
            let nextButton = app.buttons["slideshow.control.next.button"]
            XCTAssertTrue(
                nextButton.waitForExistence(
                    timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
                "Playback page should show the 'Next' button")
            tapElement(nextButton)

            if let previousAssetID {
                if waitUntil(
                    timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
                    condition: {
                        guard let currentAssetID = self.currentSlideshowAssetID(app: app) else { return false }
                        return currentAssetID != previousAssetID
                    })
                {
                    return true
                }
            } else if let previousDateLabel {
                if waitUntil(
                    timeout: FilterSummaryIOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
                    condition: {
                        self.currentExifDateLabel(app: app) != previousDateLabel
                    })
                {
                    return true
                }
            } else {
                RunLoop.current.run(
                    until: Date().addingTimeInterval(FilterSummaryIOSVisualUITestsWaitTiming.screenSettleSeconds))
                return true
            }
        }

        return false
    }

    func currentExifToneDebugLabel(app: XCUIApplication) -> String {
        let toneFlag = app.descendants(matching: .any)["slideshow.exifForegroundTone.flag"]
        XCTAssertTrue(
            toneFlag.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.settingsChangeTimeoutSeconds),
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
        guard assetFlag.waitForExistence(timeout: FilterSummaryIOSVisualUITestsWaitTiming.stateChangeTimeoutSeconds)
        else { return nil }

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
}
#endif
