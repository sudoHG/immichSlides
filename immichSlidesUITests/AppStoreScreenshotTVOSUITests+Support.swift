import ImageIO
import XCTest

#if os(tvOS)
extension AppStoreScreenshotTVOSUITests {
    func requestedLocaleSpecs() throws -> [AppStoreScreenshotLocaleSpec] {
        let requestedDirectories = screenshotEnvironmentList("APP_STORE_SCREENSHOT_LOCALES")
        guard !requestedDirectories.isEmpty else {
            return AppStoreScreenshotLocaleSpec.submissionPrimary
        }

        return try requestedDirectories.map { directory in
            guard let spec = AppStoreScreenshotLocaleSpec.spec(for: directory) else {
                throw TVOSScreenshotError.message("Unknown screenshot locale directory: \(directory)")
            }
            return spec
        }
    }

    func requestedScreenshotSlots() throws -> [ScreenshotSlot] {
        let requestedSlotNames = screenshotEnvironmentList("APP_STORE_SCREENSHOT_SLOTS")
        guard !requestedSlotNames.isEmpty else { return ScreenshotSlot.allCases }

        return try requestedSlotNames.map { slotName in
            guard let slot = ScreenshotSlot(rawValue: slotName) else {
                throw TVOSScreenshotError.message("Unknown screenshot slot: \(slotName)")
            }
            return slot
        }
    }

    @MainActor
    func capture(slot: ScreenshotSlot, outputRoot: URL, slotDirectory: URL) throws {
        switch slot {
        case .playback:
            try capturePlayback(outputRoot: outputRoot, slotDirectory: slotDirectory)
        case .playbackMode:
            try capturePlaybackMode(outputRoot: outputRoot, slotDirectory: slotDirectory)
        case .filterEntry:
            try captureFilterEntry(outputRoot: outputRoot, slotDirectory: slotDirectory)
        case .peopleFilter:
            try capturePeopleFilter(outputRoot: outputRoot, slotDirectory: slotDirectory)
        case .albumFilter:
            try captureAlbumFilter(outputRoot: outputRoot, slotDirectory: slotDirectory)
        case .pinProtection:
            try capturePinProtection(outputRoot: outputRoot, slotDirectory: slotDirectory)
        case .connectImmich:
            try captureConnectImmich(outputRoot: outputRoot, slotDirectory: slotDirectory)
        }
    }

    @MainActor
    func runSlot(
        _ slot: ScreenshotSlot,
        outputRoot: URL,
        slotDirectory: URL,
        blockers: inout [String],
        capture: SlotCapture
    ) {
        do {
            try capture()
        } catch {
            XCUIApplication().terminate()
            let message = "\(slot.rawValue): \(error.localizedDescription)"
            blockers.append(message)
            appendManifestRow(
                outputRoot: outputRoot,
                slot: slot,
                relativeFilePath: "\(localeDirectory)/submission_primary/\(platformGroup)/\(slot.fileName)",
                pixelSize: "unknown",
                status: "blocker",
                notes: message
            )
        }
    }

    @MainActor
    func capturePlayback(outputRoot: URL, slotDirectory: URL) throws {
        let app = try launchIntoFilterSummary(
            filterSelectionJSON: playbackAlbumSelectionJSON,
            shouldPrepareFilterSummaryVisuals: false,
            shouldDisablePlaybackEntryHint: false
        )
        try focusStartPlaybackButton(in: app)
        XCUIRemote.shared.press(.select)

        try waitOrThrow(
            app.buttons["slideshow.control.settings.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.playbackEntryTimeoutSeconds,
            "tvOS playback page should show the settings button"
        )
        try waitOrThrow(
            app.buttons["slideshow.control.playPause.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "tvOS playback page should show the play/pause button"
        )
        try waitOrThrow(
            app.staticTexts["slideshow.entryHint.title"],
            timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            "tvOS playback screenshot must show the settings hint bubble"
        )
        try waitOrThrow(
            app.otherElements["slideshow.entryHint.keycap"],
            timeout: 4,
            "tvOS playback settings hint bubble should show the key hint"
        )
        waitForFocusVisualSettle(seconds: 1.2)

        capture(
            app: app,
            slot: .playback,
            outputRoot: outputRoot,
            slotDirectory: slotDirectory,
            notes: "selected album: \(playbackAlbumName)"
        )
        app.terminate()
    }

    @MainActor
    func capturePlaybackMode(outputRoot: URL, slotDirectory: URL) throws {
        let app = try launchIntoModeSelection()

        try waitOrThrow(
            app.buttons["mode.random.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Mode selection should show the random playback option")
        try waitOrThrow(
            app.buttons["mode.filtered.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Mode selection should show the filtered playback option")
        waitForFocusVisualSettle()

        capture(app: app, slot: .playbackMode, outputRoot: outputRoot, slotDirectory: slotDirectory)
        app.terminate()
    }

    @MainActor
    func captureFilterEntry(outputRoot: URL, slotDirectory: URL) throws {
        let app = try launchIntoFilterSummary(filterSelectionJSON: briefCombinedFilterSelectionJSON)

        try waitOrThrow(
            app.buttons["filterSummary.album.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Filter summary should show the album entry")
        try waitOrThrow(
            app.buttons["filterSummary.person.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Filter summary should show the people entry")
        try waitOrThrow(
            app.staticTexts["filterSummary.album.ready"],
            timeout: AppStoreScreenshotUITestsWaitTiming.connectionTimeoutSeconds,
            "Filter summary album stage should finish loading")
        try waitOrThrow(
            app.staticTexts["filterSummary.people.ready"],
            timeout: AppStoreScreenshotUITestsWaitTiming.connectionTimeoutSeconds,
            "Filter summary people stage should finish loading")
        try waitUntilOrThrow(
            timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            "Filter summary should enable Start playback after filters are seeded"
        ) {
            app.buttons["filterSummary.startPlayback.button"].isEnabled
        }
        waitForFocusVisualSettle(seconds: 1.2)

        capture(app: app, slot: .filterEntry, outputRoot: outputRoot, slotDirectory: slotDirectory)
        app.terminate()
    }

    @MainActor
    func capturePeopleFilter(outputRoot: URL, slotDirectory: URL) throws {
        let app = try launchIntoFilterSummary(
            filterSelectionJSON: briefPeopleFilterSelectionJSON,
            shouldPrepareFilterSummaryVisuals: false
        )

        try openPersonFilterFromSummary(app)
        try waitOrThrow(
            app.buttons["personFilter.back.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "People filter page should show the Back button")
        try waitForBriefPeopleCardsForScreenshot(app)
        waitForFocusVisualSettle()

        capture(
            app: app,
            slot: .peopleFilter,
            outputRoot: outputRoot,
            slotDirectory: slotDirectory,
            notes: "preseeded people: Augusto soloOnly; Mia, Wang, Ethan normal"
        )
        app.terminate()
    }

    @MainActor
    func captureAlbumFilter(outputRoot: URL, slotDirectory: URL) throws {
        let app = try launchIntoFilterSummary(
            filterSelectionJSON: briefAlbumFilterSelectionJSON,
            shouldPrepareFilterSummaryVisuals: false
        )

        try openAlbumFilterFromSummary(app)
        try waitOrThrow(
            app.buttons["albumFilter.back.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Album filter page should show the Back button")
        try waitForBriefAlbumCardsForScreenshot(app)
        waitForFocusVisualSettle()

        capture(
            app: app,
            slot: .albumFilter,
            outputRoot: outputRoot,
            slotDirectory: slotDirectory,
            notes: "preseeded albums: Augusto Family; Augusto & Mia; Beijing Cycling"
        )
        app.terminate()
    }

    @MainActor
    func capturePinProtection(outputRoot: URL, slotDirectory: URL) throws {
        let app = try launchIntoSlideShow(filterSelectionJSON: playbackAlbumSelectionJSON)

        try openSettingsFromSlideShow(app)
        try focusSettingsHomeItem(
            app: app,
            identifier: "settings.item.accessProtection",
            downStepsFromPlayback: 1,
            failureMessage: "Settings home should be able to focus the access protection entry"
        )
        XCUIRemote.shared.press(.select)

        let pinInputButton = app.buttons["settings.pin.input.enable"]
        try waitOrThrow(
            pinInputButton, timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Access protection page should show the set-PIN entry")
        try waitForFocus(
            pinInputButton, timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            "Access protection page should default focus to the set-PIN entry")
        XCUIRemote.shared.press(.select)

        try waitOrThrow(
            app.buttons["pinEntry.close.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            "Choosing set PIN should show the PIN overlay")
        try waitOrThrow(
            app.buttons["pinEntry.digit.1.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            "PIN overlay should show the number pad")
        waitForFocusVisualSettle()

        capture(app: app, slot: .pinProtection, outputRoot: outputRoot, slotDirectory: slotDirectory)
        app.terminate()
    }

    @MainActor
    func captureConnectImmich(outputRoot: URL, slotDirectory: URL) throws {
        let app = makeBaseLaunchApp()
        app.launchEnvironment["UI_TEST_APP_STORE_SCREENSHOT_PREFILL_CONNECTION"] = "1"
        app.launchEnvironment["UI_TEST_APP_STORE_SCREENSHOT_SERVER_URL"] = appStoreDemoServerURL
        app.launchEnvironment["UI_TEST_APP_STORE_SCREENSHOT_API_KEY"] = appStoreDemoAPIKey
        app.launch()

        let serverURLField = app.textFields["firstboot.serverURL.field"]
        try waitOrThrow(
            serverURLField, timeout: AppStoreScreenshotUITestsWaitTiming.connectionTimeoutSeconds,
            "A fresh install should open the tvOS first-launch server setup page")
        let displayedURL = (serverURLField.value as? String) ?? ""
        guard displayedURL.contains(appStoreDemoServerURL) else {
            throw TVOSScreenshotError.message("tvOS first-launch page should prefill the screenshot demo URL.")
        }

        try waitOrThrow(
            app.secureTextFields["firstboot.apiKey.field"],
            timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            "tvOS first-launch page should show the secure API Key field")
        try waitOrThrow(
            app.descendants(matching: .any)["firstboot.form.card"],
            timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            "tvOS first-launch page should show the server setup form"
        )

        if app.buttons["firstboot.fillConfig.button"].exists
            || app.descendants(matching: .any)["firstboot.fillConfig.button"].exists
        {
            throw TVOSScreenshotError.message("tvOS first-launch page still shows the debug Autofill settings button.")
        }
        waitForFocusVisualSettle()

        capture(
            app: app,
            slot: .connectImmich,
            outputRoot: outputRoot,
            slotDirectory: slotDirectory,
            notes: "prefilled demo URL and masked API key"
        )
        app.terminate()
    }
}
extension AppStoreScreenshotTVOSUITests {
    @MainActor
    func launchIntoModeSelection() throws -> XCUIApplication {
        let app = makeBaseLaunchApp()
        try injectRealTestServer(into: app)
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launch()

        try waitOrThrow(app.buttons["mode.continue.button"], timeout: 18, "Should reach tvOS mode selection")
        return app
    }

    @MainActor
    func launchIntoFilterSummary(
        filterSelectionJSON: String,
        shouldPrepareFilterSummaryVisuals: Bool = true,
        shouldDisablePlaybackEntryHint: Bool = true
    ) throws -> XCUIApplication {
        let app = makeBaseLaunchApp(
            filterSelectionJSON: filterSelectionJSON,
            shouldDisablePlaybackEntryHint: shouldDisablePlaybackEntryHint
        )
        try injectRealTestServer(into: app)
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        if shouldPrepareFilterSummaryVisuals {
            app.launchEnvironment["UI_TEST_PREPARE_FILTER_SUMMARY_VISUAL_SELECTIONS"] = "1"
        }
        app.launch()

        try startFilteredFlowFromModeSelection(app)
        return app
    }

    @MainActor
    func launchIntoSlideShow(filterSelectionJSON: String) throws -> XCUIApplication {
        let app = try launchIntoFilterSummary(
            filterSelectionJSON: filterSelectionJSON,
            shouldPrepareFilterSummaryVisuals: false
        )
        try focusStartPlaybackButton(in: app)
        XCUIRemote.shared.press(.select)
        try waitOrThrow(
            app.buttons["slideshow.control.settings.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.playbackEntryTimeoutSeconds,
            "Starting playback should open the tvOS playback page")
        return app
    }

    func makeBaseLaunchApp(
        filterSelectionJSON: String? = nil,
        shouldDisablePlaybackEntryHint: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()

        // Launch clean for each screenshot so PIN, focus, server or filter state never leaks into the next one.

        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_COLOR_SCHEME"] = "light"
        app.launchEnvironment["UI_TEST_DISABLE_DEBUG_FILL_APIKEY_BUTTON"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        if shouldDisablePlaybackEntryHint {
            app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        }

        if let filterSelectionJSON {
            app.launchEnvironment["UI_TEST_SEED_FILTER_SELECTION"] = "1"
            app.launchEnvironment["UI_TEST_FILTER_SELECTION_JSON"] = filterSelectionJSON
        }

        app.launchArguments += [
            "-AppleLanguages", "(\(actualLanguage))",
            "-AppleLocale", actualLocale
        ]
        return app
    }

    func injectRealTestServer(into app: XCUIApplication) throws {
        let config = try requireTestServerConfig()
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
    }

    @MainActor
    func startFilteredFlowFromModeSelection(_ app: XCUIApplication) throws {
        let filteredButton = app.buttons["mode.filtered.button"]
        try waitOrThrow(
            filteredButton, timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Mode selection should show the filtered playback option")
        XCUIRemote.shared.press(.right)
        waitForFocusVisualSettle(seconds: 0.25)
        XCUIRemote.shared.press(.select)

        let continueButton = app.buttons["mode.continue.button"]
        try waitOrThrow(
            continueButton, timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Mode selection should show the Continue button")
        guard continueButton.isEnabled else {
            throw TVOSScreenshotError.message("Continue button is disabled after choosing filtered playback.")
        }
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.25)
        XCUIRemote.shared.press(.select)

        try waitOrThrow(
            app.buttons["filterSummary.startPlayback.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.connectionTimeoutSeconds,
            "Should reach the tvOS filter summary")
    }
}
extension AppStoreScreenshotTVOSUITests {
    @MainActor
    func openAlbumFilterFromSummary(_ app: XCUIApplication) throws {
        let albumButton = app.buttons["filterSummary.album.button"]
        try waitOrThrow(
            albumButton, timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Filter summary should show the album entry")
        try focusFilterSummaryAlbumButton(in: app)
        XCUIRemote.shared.press(.select)
        try waitOrThrow(
            app.buttons["albumFilter.back.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Should reach the tvOS album filter page")
    }

    @MainActor
    func openPersonFilterFromSummary(_ app: XCUIApplication) throws {
        let peopleButton = app.buttons["filterSummary.person.button"]
        try waitOrThrow(
            peopleButton, timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Filter summary should show the people entry")
        try focusFilterSummaryPeopleButton(in: app)
        XCUIRemote.shared.press(.select)
        try waitOrThrow(
            app.buttons["personFilter.back.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Should reach the tvOS people filter page")
    }

    @MainActor
    func focusFilterSummaryAlbumButton(in app: XCUIApplication) throws {
        let albumButton = app.buttons["filterSummary.album.button"]
        if isFocused(albumButton) { return }

        for _ in 0..<6 {
            if isFocused(albumButton) { return }
            XCUIRemote.shared.press(.left)
            waitForFocusVisualSettle(seconds: 0.15)
            if isFocused(albumButton) { return }
            XCUIRemote.shared.press(.up)
            waitForFocusVisualSettle(seconds: 0.15)
        }

        try waitForFocus(albumButton, timeout: 2, "Filter summary should be able to move focus to the album entry")
    }

    @MainActor
    func focusFilterSummaryPeopleButton(in app: XCUIApplication) throws {
        let peopleButton = app.buttons["filterSummary.person.button"]
        if isFocused(peopleButton) { return }

        try focusFilterSummaryAlbumButton(in: app)
        XCUIRemote.shared.press(.right)
        waitForFocusVisualSettle(seconds: 0.25)
        try waitForFocus(
            peopleButton, timeout: AppStoreScreenshotUITestsWaitTiming.shortInteractionTimeoutSeconds,
            "Filter summary should be able to move focus to the people entry")
    }

    @MainActor
    func focusStartPlaybackButton(in app: XCUIApplication) throws {
        let startButton = app.buttons["filterSummary.startPlayback.button"]
        try waitOrThrow(
            startButton, timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Filter summary should show the Start playback button")

        for _ in 0..<10 {
            if isFocused(startButton) { return }
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.15)
        }

        try waitForFocus(
            startButton, timeout: AppStoreScreenshotUITestsWaitTiming.shortInteractionTimeoutSeconds,
            "Filter summary should be able to move focus to Start playback")
    }

    func albumCardIdentifier(id: String) -> String {
        "albumFilter.album.\(id).button"
    }

    func personCardIdentifier(id: String) -> String {
        "personFilter.person.\(id).button"
    }

    func exactElement(identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }

    func waitForBriefAlbumCardsForScreenshot(_ app: XCUIApplication) throws {
        for album in briefAlbumSelections {
            try waitOrThrow(
                exactElement(identifier: albumCardIdentifier(id: album.id), in: app),
                timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
                "tvOS album filter page should show the album named in the brief: \(album.name)"
            )
        }
    }

    func waitForBriefPeopleCardsForScreenshot(_ app: XCUIApplication) throws {
        for person in briefPersonSelections {
            try waitOrThrow(
                exactElement(identifier: personCardIdentifier(id: person.id), in: app),
                timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
                "tvOS people filter page should show the person named in the brief: \(person.name)"
            )
        }
    }
}
extension AppStoreScreenshotTVOSUITests {
    @MainActor
    func openSettingsFromSlideShow(_ app: XCUIApplication) throws {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        try waitOrThrow(
            settingsButton, timeout: AppStoreScreenshotUITestsWaitTiming.connectionTimeoutSeconds,
            "Playback page should show the settings button")

        // Press Left repeatedly to bring focus back to the leftmost settings button.

        for _ in 0..<6 {
            if isFocused(settingsButton) { break }
            XCUIRemote.shared.press(.left)
            waitForFocusVisualSettle(seconds: 0.12)
        }

        try waitForFocus(
            settingsButton, timeout: AppStoreScreenshotUITestsWaitTiming.elementAppearanceTimeoutSeconds,
            "Focus should return to the settings button before opening settings")
        XCUIRemote.shared.press(.select)
        try waitUntilOrThrow(
            timeout: AppStoreScreenshotUITestsWaitTiming.navigationTimeoutSeconds,
            "Pressing the settings button should open settings home"
        ) {
            app.buttons["settings.item.playback"].exists || app.otherElements["settings.item.playback"].exists
                || app.staticTexts["settings.item.playback"].exists
        }
    }

    @MainActor
    func focusSettingsHomeItem(
        app: XCUIApplication,
        identifier: String,
        downStepsFromPlayback: Int,
        failureMessage: String
    ) throws {
        let playbackItem = try waitForSettingsControl(
            app: app,
            identifier: "settings.item.playback",
            timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Settings home should show the playback settings entry"
        )

        for _ in 0..<8 {
            if isFocused(playbackItem) { break }
            XCUIRemote.shared.press(.up)
            waitForFocusVisualSettle(seconds: 0.12)
        }
        try waitForFocus(
            playbackItem, timeout: AppStoreScreenshotUITestsWaitTiming.settingsChangeTimeoutSeconds,
            "Settings home should be able to settle focus on the playback settings entry")

        for _ in 0..<downStepsFromPlayback {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.15)
        }

        let target = try waitForSettingsControl(
            app: app,
            identifier: identifier,
            timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: failureMessage
        )
        try waitForFocus(
            target, timeout: AppStoreScreenshotUITestsWaitTiming.settingsChangeTimeoutSeconds, failureMessage)
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

    func waitForSettingsControl(
        app: XCUIApplication,
        identifier: String,
        timeout: TimeInterval,
        failureMessage: String
    ) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let element = settingsControlCandidates(app: app, identifier: identifier).first(where: \.exists) {
                return element
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(AppStoreScreenshotUITestsWaitTiming.pollIntervalSeconds))
        }

        if let element = settingsControlCandidates(app: app, identifier: identifier).first(where: \.exists) {
            return element
        }
        throw TVOSScreenshotError.message(failureMessage)
    }
}
extension AppStoreScreenshotTVOSUITests {
    func resolvedOutputRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        let explicitPath =
            env["APP_STORE_SCREENSHOT_OUTPUT_ROOT"] ?? env["TEST_RUNNER_APP_STORE_SCREENSHOT_OUTPUT_ROOT"]

        if let explicitPath, !explicitPath.isEmpty {
            return URL(fileURLWithPath: explicitPath)
        }

        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        return
            repositoryRoot
            .appendingPathComponent("产品截图")
            .appendingPathComponent("AppStore素材_2026-05-09")
    }

    func prepareOutputDirectory(
        _ directory: URL,
        slots: [ScreenshotSlot] = ScreenshotSlot.allCases
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for slot in slots {
            let fileURL = directory.appendingPathComponent(slot.fileName)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func removeManifestRows(outputRoot: URL, slots: [ScreenshotSlot]) throws {
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let manifestURL = outputRoot.appendingPathComponent("manifest.md")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            try resetManifest(at: outputRoot)
            return
        }

        let targetRelativePaths = Set(slots.map { relativeFilePath(for: $0) })
        let content = try String(contentsOf: manifestURL, encoding: .utf8)
        let keptLines =
            content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                !targetRelativePaths.contains { relativePath in
                    line.contains("| \(relativePath) |")
                }
            }
        try keptLines.joined(separator: "\n").write(to: manifestURL, atomically: true, encoding: .utf8)
    }

    func resetManifest(at outputRoot: URL) throws {
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let manifestURL = outputRoot.appendingPathComponent("manifest.md")
        let header = """
            # immichSlides App Store Screenshot Manifest

            | file | slot | locale | actual_language | actual_locale | platform_group | device_model | runtime | pixel_size | theme | ui_language_verified | status | notes |
            | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |

            """
        try header.write(to: manifestURL, atomically: true, encoding: .utf8)
    }

    func capture(
        app: XCUIApplication,
        slot: ScreenshotSlot,
        outputRoot: URL,
        slotDirectory: URL,
        notes: String = ""
    ) {
        waitForFocusVisualSettle(seconds: 0.7)

        let screenshot = app.screenshot()
        let data = screenshot.pngRepresentation
        let fileURL = slotDirectory.appendingPathComponent(slot.fileName)

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            XCTFail("Failed to write tvOS screenshot: \(fileURL.path), error: \(error.localizedDescription)")
            return
        }

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(localeDirectory)-\(platformGroup)-\(slot.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)

        appendManifestRow(
            outputRoot: outputRoot,
            slot: slot,
            relativeFilePath: relativeFilePath(for: slot),
            pixelSize: imagePixelSize(from: data) ?? "unknown",
            status: "success",
            notes: notes
        )
    }

    func relativeFilePath(for slot: ScreenshotSlot) -> String {
        "\(localeDirectory)/submission_primary/\(platformGroup)/\(slot.fileName)"
    }

    func appendManifestRow(
        outputRoot: URL,
        slot: ScreenshotSlot,
        relativeFilePath: String,
        pixelSize: String,
        status: String,
        notes: String
    ) {
        let manifestURL = outputRoot.appendingPathComponent("manifest.md")
        let combinedNotes = [notes, localeSpec.note]
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        let escapedNotes =
            combinedNotes
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
        let row = """
            | \(relativeFilePath) | \(slot.rawValue) - \(slot.title) | \(localeDirectory) | \(actualLanguage) | \(actualLocale) | \(platformGroup) | \(UIDevice.current.model) | \(ProcessInfo.processInfo.operatingSystemVersionString) | \(pixelSize) | \(appearance) | no | \(status) | \(escapedNotes) |

            """

        do {
            let handle = try FileHandle(forWritingTo: manifestURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(row.utf8))
            try handle.close()
        } catch {
            XCTFail("Failed to write manifest: \(manifestURL.path), error: \(error.localizedDescription)")
        }
    }

    func imagePixelSize(from data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return "\(width)x\(height)"
    }
}
extension AppStoreScreenshotTVOSUITests {
    func waitOrThrow(_ element: XCUIElement, timeout: TimeInterval, _ message: String) throws {
        guard element.waitForExistence(timeout: timeout) else {
            throw TVOSScreenshotError.message(message)
        }
    }

    func waitUntilOrThrow(timeout: TimeInterval, _ message: String, condition: @escaping () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(
                until: Date().addingTimeInterval(AppStoreScreenshotUITestsWaitTiming.pollIntervalSeconds))
        }
        guard condition() else {
            throw TVOSScreenshotError.message(message)
        }
    }

    func isFocused(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        return element.hasFocus || accessibilityValueString(for: element).contains("focused")
            || accessibilityValueString(for: element).contains("已聚焦")
    }

    func waitForFocus(_ element: XCUIElement, timeout: TimeInterval, _ message: String) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isFocused(element) { return }
            RunLoop.current.run(
                until: Date().addingTimeInterval(AppStoreScreenshotUITestsWaitTiming.pollIntervalSeconds))
        }
        guard isFocused(element) else {
            throw TVOSScreenshotError.message(message)
        }
    }

    func accessibilityValueString(for element: XCUIElement) -> String {
        guard let rawValue = element.value else { return "" }
        return String(describing: rawValue)
    }

    func waitForFocusVisualSettle(seconds: TimeInterval = 0.8) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
#endif
