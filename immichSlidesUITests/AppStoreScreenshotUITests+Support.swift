import ImageIO
import XCTest

#if os(iOS)
extension AppStoreScreenshotUITests {
    func requestedIOSPlatformSpec() throws -> IOSPlatformSpec {
        let platformName = screenshotEnvironmentValue("APP_STORE_SCREENSHOT_PLATFORM_GROUP") ?? platformGroup
        guard let platform = IOSPlatformSpec.spec(for: platformName) else {
            throw ScreenshotError.message("Unknown iOS screenshot platform: \(platformName)")
        }
        return platform
    }

    func requestedLocaleSpecs() throws -> [AppStoreScreenshotLocaleSpec] {
        let requestedDirectories = screenshotEnvironmentList("APP_STORE_SCREENSHOT_LOCALES")
        guard !requestedDirectories.isEmpty else {
            return AppStoreScreenshotLocaleSpec.submissionPrimary
        }

        return try requestedDirectories.map { directory in
            guard let spec = AppStoreScreenshotLocaleSpec.spec(for: directory) else {
                throw ScreenshotError.message("Unknown screenshot locale directory: \(directory)")
            }
            return spec
        }
    }

    func requestedScreenshotSlots() throws -> [ScreenshotSlot] {
        let requestedSlotNames = screenshotEnvironmentList("APP_STORE_SCREENSHOT_SLOTS")
        guard !requestedSlotNames.isEmpty else { return ScreenshotSlot.allCases }

        return try requestedSlotNames.map { slotName in
            guard let slot = ScreenshotSlot(rawValue: slotName) else {
                throw ScreenshotError.message("Unknown screenshot slot: \(slotName)")
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
                relativeFilePath: relativeFilePath(for: slot),
                pixelSize: "unknown",
                status: "blocker",
                notes: message
            )
        }
    }

    @MainActor
    func capturePlayback(outputRoot: URL, slotDirectory: URL) throws {
        let app = try launchIntoFilterSummary(shouldDisablePlaybackEntryHint: false)

        try openAlbumFilterFromSummary(app)

        let playbackAlbumID = try resolvedPlaybackAlbumID()
        try tapCard(
            identifier: albumCardIdentifier(id: playbackAlbumID),
            in: app,
            timeout: AppStoreScreenshotUITestsWaitTiming.connectionTimeoutSeconds,
            missingMessage: "Album filter page should find \(playbackAlbumName)"
        )

        try tapBackButton(in: app, expectedPageAfterBack: app.buttons["filterSummary.startPlayback.button"])

        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        try waitOrThrow(
            startPlaybackButton, timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Start playback button should appear after selecting an album")
        guard startPlaybackButton.isEnabled else {
            throw ScreenshotError.message(
                "Start playback button is disabled; the album selection may not have taken effect.")
        }
        tapElement(startPlaybackButton)

        try waitForPlaybackPageReady(app)
        try waitOrThrow(
            app.otherElements["slideshow.entryHint.banner"],
            timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            "Playback page should show the settings hint bubble"
        )

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

        capture(app: app, slot: .playbackMode, outputRoot: outputRoot, slotDirectory: slotDirectory)
        app.terminate()
    }

    @MainActor
    func captureFilterEntry(outputRoot: URL, slotDirectory: URL) throws {
        let app = try launchIntoFilterSummary()

        try selectFirstAlbumAndPersonCardsForSummary(app)

        try waitOrThrow(
            app.buttons["filterSummary.album.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Filter summary should show the album entry")
        try waitOrThrow(
            app.buttons["filterSummary.person.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Filter summary should show the people entry")
        try waitUntilOrThrow(
            timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            "Filter summary should enable Start playback after albums and people are selected"
        ) {
            app.buttons["filterSummary.startPlayback.button"].isEnabled
        }

        capture(app: app, slot: .filterEntry, outputRoot: outputRoot, slotDirectory: slotDirectory)
        app.terminate()
    }

    @MainActor
    func capturePeopleFilter(outputRoot: URL, slotDirectory: URL) throws {
        let app = try launchIntoFilterSummary(filterSelectionJSON: briefPeopleFilterSelectionJSON)

        try openPersonFilterFromSummary(app)
        try waitForBriefPeopleCardsForScreenshot(app)

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
        let app = try launchIntoFilterSummary()

        try openAlbumFilterFromSummary(app)
        try selectBriefAlbumsForScreenshot(app)

        capture(app: app, slot: .albumFilter, outputRoot: outputRoot, slotDirectory: slotDirectory)
        app.terminate()
    }

    @MainActor
    func capturePinProtection(outputRoot: URL, slotDirectory: URL) throws {
        let app = try launchIntoSlideShow(shouldDisablePlaybackEntryHint: true)

        try openSettingsFromSlideShow(app)
        try openSettingsSection(app: app, sectionID: "settings.item.accessProtection")

        let pinInputButton = app.buttons["settings.pin.input.enable"]
        try waitOrThrow(
            pinInputButton, timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Access protection page should show the set-PIN entry")
        tapElement(pinInputButton)

        try waitOrThrow(
            app.buttons["pinEntry.close.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            "Choosing set PIN should show the PIN overlay")
        try waitOrThrow(
            app.buttons["pinEntry.digit.1.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            "PIN overlay should show the number pad")

        capture(app: app, slot: .pinProtection, outputRoot: outputRoot, slotDirectory: slotDirectory)
        app.terminate()
    }

    @MainActor
    func captureConnectImmich(outputRoot: URL, slotDirectory: URL) throws {
        let app = makeBaseLaunchApp(shouldDisablePlaybackEntryHint: true)
        app.launchEnvironment["UI_TEST_APP_STORE_SCREENSHOT_PREFILL_CONNECTION"] = "1"
        app.launchEnvironment["UI_TEST_APP_STORE_SCREENSHOT_SERVER_URL"] = appStoreDemoServerURL
        app.launchEnvironment["UI_TEST_APP_STORE_SCREENSHOT_API_KEY"] = appStoreDemoAPIKey
        app.launch()

        let serverURLField = app.textFields["firstboot.serverURL.field"]
        try waitOrThrow(
            serverURLField, timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "A fresh install should open the first-launch server setup page")
        let displayedURL = (serverURLField.value as? String) ?? ""
        guard displayedURL.contains(appStoreDemoServerURL) else {
            throw ScreenshotError.message("First-launch page should prefill the screenshot demo URL.")
        }

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        try waitOrThrow(
            apiKeyField, timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            "First-launch page should show the secure API Key field")

        try waitUntilOrThrow(
            timeout: AppStoreScreenshotUITestsWaitTiming.elementAppearanceTimeoutSeconds,
            "Save configuration button should be enabled after the screenshot prefill"
        ) {
            app.buttons["firstboot.saveConfig.button"].isEnabled
        }

        guard app.keyboards.count == 0 else {
            throw ScreenshotError.message("The first-launch screenshot must not show the system keyboard.")
        }

        if app.buttons["firstboot.fillConfig.button"].exists
            || app.descendants(matching: .any)["firstboot.fillConfig.button"].exists
        {
            throw ScreenshotError.message("First-launch page still shows the debug Autofill settings button.")
        }

        capture(
            app: app,
            slot: .connectImmich,
            outputRoot: outputRoot,
            slotDirectory: slotDirectory,
            notes: "prefilled demo URL and masked API key; keyboard not opened"
        )
        app.terminate()
    }
}
extension AppStoreScreenshotUITests {
    @MainActor
    func selectFirstAlbumAndPersonCardsForSummary(_ app: XCUIApplication) throws {
        try openAlbumFilterFromSummary(app)
        try tapFirstCards(
            prefix: "albumFilter.album.",
            count: AppStoreScreenshotUITestsScreenshotSelection.albumCardCount,
            in: app,
            missingMessage: "Album filter page should show at least the first 3 albums"
        )
        try tapBackButton(in: app, expectedPageAfterBack: app.buttons["filterSummary.startPlayback.button"])

        try openPersonFilterFromSummary(app)
        try tapFirstCards(
            prefix: "personFilter.person.",
            count: AppStoreScreenshotUITestsScreenshotSelection.personCardCount,
            in: app,
            missingMessage: "People filter page should show at least the first 4 people"
        )
        try tapBackButton(in: app, expectedPageAfterBack: app.buttons["filterSummary.startPlayback.button"])
    }

    @MainActor
    func selectBriefAlbumsForScreenshot(_ app: XCUIApplication) throws {
        for album in briefAlbumSelections {
            try tapCard(
                identifier: albumCardIdentifier(id: album.id),
                in: app,
                timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
                missingMessage: "Album filter page should find \(album.name)"
            )
        }
    }

    func waitForBriefPeopleCardsForScreenshot(_ app: XCUIApplication) throws {
        for person in briefPersonSelections {
            try waitOrThrow(
                exactCardQuery(identifier: personCardIdentifier(id: person.id), in: app).firstMatch,
                timeout: AppStoreScreenshotUITestsWaitTiming.navigationTimeoutSeconds,
                "People filter page should show the person named in the brief: \(person.name)"
            )
        }
    }

    @MainActor
    func openAlbumFilterFromSummary(_ app: XCUIApplication) throws {
        let albumButton = app.buttons["filterSummary.album.button"]
        try waitOrThrow(
            albumButton, timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Filter summary should show the album entry")
        tapElement(albumButton)
        try waitForFilterCards(
            prefix: "albumFilter.album.", in: app, message: "Album filter page should show album cards")
    }

    @MainActor
    func openPersonFilterFromSummary(_ app: XCUIApplication) throws {
        let personButton = app.buttons["filterSummary.person.button"]
        try waitOrThrow(
            personButton, timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Filter summary should show the people entry")
        tapElement(personButton)
        try waitForFilterCards(
            prefix: "personFilter.person.", in: app, message: "People filter page should show person cards")
    }

    func albumCardIdentifier(id: String) -> String {
        "albumFilter.album.\(id).button"
    }

    func personCardIdentifier(id: String) -> String {
        "personFilter.person.\(id).button"
    }

    @MainActor
    func tapFirstCards(prefix: String, count: Int, in app: XCUIApplication, missingMessage: String) throws {
        try waitForFilterCards(prefix: prefix, in: app, message: missingMessage)

        // Count each identifier as one card so we never tap a cover, title or checkmark child element.

        var uniqueIdentifiers: [String] = []
        var seenIdentifiers: Set<String> = []
        for element in cardQuery(prefix: prefix, in: app).allElementsBoundByIndex {
            let identifier = element.identifier
            guard !identifier.isEmpty, !seenIdentifiers.contains(identifier) else { continue }
            seenIdentifiers.insert(identifier)
            uniqueIdentifiers.append(identifier)
            if uniqueIdentifiers.count == count { break }
        }

        guard uniqueIdentifiers.count >= count else {
            throw ScreenshotError.message(
                "\(missingMessage): found only \(uniqueIdentifiers.count) unique cards, need \(count).")
        }

        for (index, identifier) in uniqueIdentifiers.enumerated() {
            try tapCard(
                identifier: identifier,
                in: app,
                timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
                missingMessage: "\(missingMessage): card \(index + 1) is missing"
            )
        }
    }

    @MainActor
    func tapCard(identifier: String, in app: XCUIApplication, timeout: TimeInterval, missingMessage: String) throws {
        let card = exactCardQuery(identifier: identifier, in: app).firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if card.exists {
                tapElement(card)
                return
            }
            app.swipeUp()
            RunLoop.current.run(
                until: Date().addingTimeInterval(AppStoreScreenshotUITestsWaitTiming.transitionPollSeconds))
        }

        guard card.exists else {
            throw ScreenshotError.message(missingMessage)
        }
        tapElement(card)
    }

    func exactCardQuery(identifier: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", identifier)
        )
    }

    func waitForFilterCards(prefix: String, in app: XCUIApplication, message: String) throws {
        let firstCard = cardQuery(prefix: prefix, in: app).firstMatch
        try waitOrThrow(firstCard, timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds, message)
    }

    func cardQuery(prefix: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                prefix,
                ".button"
            )
        )
    }
}
extension AppStoreScreenshotUITests {
    @MainActor
    func launchIntoModeSelection() throws -> XCUIApplication {
        let app = makeBaseLaunchApp()
        try injectRealTestServer(into: app)
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launch()

        try waitOrThrow(app.buttons["mode.continue.button"], timeout: 18, "Should reach mode selection")
        return app
    }

    @MainActor
    func launchIntoFilterSummary(
        shouldDisablePlaybackEntryHint: Bool = true,
        shouldSeedFilterSelection: Bool = false,
        filterSelectionJSON: String? = nil
    ) throws -> XCUIApplication {
        let app = makeBaseLaunchApp(
            shouldDisablePlaybackEntryHint: shouldDisablePlaybackEntryHint,
            shouldSeedFilterSelection: shouldSeedFilterSelection,
            filterSelectionJSON: filterSelectionJSON
        )
        try injectRealTestServer(into: app)
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launch()

        try startFilteredFlowFromModeSelection(app)
        return app
    }

    @MainActor
    func launchIntoSlideShow(shouldDisablePlaybackEntryHint: Bool) throws -> XCUIApplication {
        let app = try launchIntoFilterSummary(
            shouldDisablePlaybackEntryHint: shouldDisablePlaybackEntryHint,
            shouldSeedFilterSelection: true
        )

        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        try waitOrThrow(
            startPlaybackButton, timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Filter summary should show the Start playback button")
        guard startPlaybackButton.isEnabled else {
            throw ScreenshotError.message("Start playback button is disabled; there may be no filter criteria.")
        }
        tapElement(startPlaybackButton)
        try waitForPlaybackPageReady(app)
        return app
    }

    func makeBaseLaunchApp(
        shouldDisablePlaybackEntryHint: Bool = true,
        shouldSeedFilterSelection: Bool = false,
        filterSelectionJSON: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()

        // Launch clean for each screenshot so cache, PIN or hint state never leaks into the next one.

        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_COLOR_SCHEME"] = "light"
        app.launchEnvironment["UI_TEST_DISABLE_DEBUG_FILL_APIKEY_BUTTON"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        if shouldSeedFilterSelection || filterSelectionJSON != nil {
            app.launchEnvironment["UI_TEST_SEED_FILTER_SELECTION"] = "1"
        }
        if let filterSelectionJSON {
            app.launchEnvironment["UI_TEST_FILTER_SELECTION_JSON"] = filterSelectionJSON
        }

        if shouldDisablePlaybackEntryHint {
            app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        }

        // Language and locale come from the selected locale specification so a previous run is not inherited.

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
        try waitOrThrow(
            app.buttons["mode.filtered.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Mode selection should show the filtered playback option")
        tapElement(app.buttons["mode.filtered.button"])

        let continueButton = app.buttons["mode.continue.button"]
        try waitOrThrow(
            continueButton, timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Mode selection should show the Continue button")
        guard continueButton.isEnabled else {
            throw ScreenshotError.message("Continue button is disabled after choosing filtered playback.")
        }
        tapElement(continueButton)

        try waitOrThrow(
            app.buttons["filterSummary.startPlayback.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.connectionTimeoutSeconds,
            "Should reach the filter summary")
    }

    @MainActor
    func waitForPlaybackPageReady(_ app: XCUIApplication) throws {
        try waitOrThrow(
            app.buttons["slideshow.control.settings.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.playbackEntryTimeoutSeconds,
            "Playback page should show the settings button")
        try waitOrThrow(
            app.buttons["slideshow.control.playPause.button"],
            timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Playback page should show the play/pause button")

        // Wait briefly after entering playback to avoid capturing EXIF before it settles.

        RunLoop.current.run(
            until: Date().addingTimeInterval(AppStoreScreenshotUITestsWaitTiming.hintAnimationSettleSeconds))
    }
}
extension AppStoreScreenshotUITests {
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

    func resolvedPlaybackAlbumID() throws -> String {
        let env = ProcessInfo.processInfo.environment
        let albumID =
            env["APP_STORE_SCREENSHOT_IOS_PLAYBACK_ALBUM_ID"]
            ?? env["TEST_RUNNER_APP_STORE_SCREENSHOT_IOS_PLAYBACK_ALBUM_ID"]

        let trimmedAlbumID = albumID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedAlbumID, !trimmedAlbumID.isEmpty {
            return trimmedAlbumID
        }

        return playbackAlbumID
    }

    func prepareOutputDirectory(
        _ directory: URL,
        slots: [ScreenshotSlot] = ScreenshotSlot.allCases
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A rerun replaces the target PNGs, so an old file is never mistaken for this run's success.

        for slot in slots {
            let fileURL = directory.appendingPathComponent(slot.fileName)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func resetManifest(at outputRoot: URL) throws {
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let manifestURL = outputRoot.appendingPathComponent("manifest.md")
        let header = """
            # immichSlides App Store Screenshot Manifest

            | file | slot | locale | actual_language | actual_locale | platform_group | device_name | runtime | pixel_size | theme | ui_language_verified | status | notes |
            | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |

            """
        try header.write(to: manifestURL, atomically: true, encoding: .utf8)
    }

    func removeManifestRows(outputRoot: URL, slots: [ScreenshotSlot]) throws {
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
        let updatedContent = keptLines.joined(separator: "\n")
        try updatedContent.write(to: manifestURL, atomically: true, encoding: .utf8)
    }

    func capture(
        app: XCUIApplication,
        slot: ScreenshotSlot,
        outputRoot: URL,
        slotDirectory: URL,
        notes: String = ""
    ) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))

        let screenshot = app.screenshot()
        let data = screenshot.pngRepresentation
        let fileURL = slotDirectory.appendingPathComponent(slot.fileName)

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            XCTFail("Failed to write screenshot: \(fileURL.path), error: \(error.localizedDescription)")
            return
        }

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(localeDirectory)-\(platformGroup)-\(slot.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)

        let pixelSize = imagePixelSize(from: data) ?? "unknown"
        guard iOSPlatformSpec.acceptsPixelSize(pixelSize) else {
            let message = "\(slot.rawValue): captured \(pixelSize) is not an accepted \(platformGroup) size"
            appendManifestRow(
                outputRoot: outputRoot,
                slot: slot,
                relativeFilePath: relativeFilePath(for: slot),
                pixelSize: pixelSize,
                status: "blocker",
                notes: message
            )
            XCTFail(message)
            return
        }
        appendManifestRow(
            outputRoot: outputRoot,
            slot: slot,
            relativeFilePath: relativeFilePath(for: slot),
            pixelSize: pixelSize,
            status: "success",
            notes: notes
        )
    }

    func relativeFilePath(for slot: ScreenshotSlot) -> String {
        "\(localeDirectory)/\(collectionDirectory)/\(platformGroup)/\(slot.fileName)"
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
            | \(relativeFilePath) | \(slot.rawValue) - \(slot.title) | \(localeDirectory) | \(actualLanguage) | \(actualLocale) | \(platformGroup) | \(UIDevice.current.name) | \(ProcessInfo.processInfo.operatingSystemVersionString) | \(pixelSize) | \(appearance) | no | \(status) | \(escapedNotes) |

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
extension AppStoreScreenshotUITests {
    @MainActor
    func openSettingsFromSlideShow(_ app: XCUIApplication) throws {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        try waitOrThrow(
            settingsButton, timeout: AppStoreScreenshotUITestsWaitTiming.connectionTimeoutSeconds,
            "Playback page should show the settings button")
        tapElement(settingsButton)
        try waitUntilOrThrow(
            timeout: AppStoreScreenshotUITestsWaitTiming.screenTransitionTimeoutSeconds,
            "Opening settings from playback should show the settings list"
        ) {
            app.buttons["settings.item.playback"].exists || app.otherElements["settings.item.playback"].exists
                || app.staticTexts["settings.item.playback"].exists
                || app.buttons["settings.item.accessProtection"].exists
                || app.otherElements["settings.item.accessProtection"].exists
                || app.staticTexts["settings.item.accessProtection"].exists
        }
    }

    @MainActor
    func openSettingsSection(app: XCUIApplication, sectionID: String) throws {
        for attempt in 0..<8 {
            let candidates = [
                app.buttons[sectionID],
                app.otherElements[sectionID],
                app.staticTexts[sectionID],
                app.descendants(matching: .any)[sectionID]
            ]

            for candidate in candidates where candidate.exists {
                tapElement(candidate)
                return
            }

            if attempt % 2 == 0 {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(AppStoreScreenshotUITestsWaitTiming.identityPollSeconds))
        }

        throw ScreenshotError.message("Settings entry not found: \(sectionID)")
    }

    @MainActor
    func tapBackButton(in app: XCUIApplication, expectedPageAfterBack: XCUIElement) throws {
        let candidates = [
            app.buttons["albumFilter.back.button"],
            app.buttons["personFilter.back.button"],
            app.buttons["global.back.button"],
            app.navigationBars.buttons.firstMatch
        ]

        for candidate in candidates where candidate.exists {
            tapElement(candidate)
            try waitOrThrow(
                expectedPageAfterBack, timeout: AppStoreScreenshotUITestsWaitTiming.controlAppearanceTimeoutSeconds,
                "Tapping Back should return to the expected page")
            return
        }

        throw ScreenshotError.message("No tappable Back button found.")
    }

    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(AppStoreScreenshotUITestsWaitTiming.identityPollSeconds))
    }

    func waitOrThrow(_ element: XCUIElement, timeout: TimeInterval, _ message: String) throws {
        guard element.waitForExistence(timeout: timeout) else {
            throw ScreenshotError.message(message)
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
            throw ScreenshotError.message(message)
        }
    }
}
#endif
