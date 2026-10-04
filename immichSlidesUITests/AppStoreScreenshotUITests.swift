//
//  AppStoreScreenshotUITests.swift
//  immichSlidesUITests
//
//  Batch export of App Store screenshots. Regular UI plans skip this suite. Evidence plans select it
//  but set only IMMICHSLIDES_EVIDENCE; this gate still requires APP_STORE_SCREENSHOT_RUN or
//  APP_STORE_SCREENSHOT_RUN_BATCH set to 1, true or yes.
//

import ImageIO
import XCTest

// Bind directory name, launch language and region together so a directory never mismatches the actual language.

private struct AppStoreScreenshotLocaleSpec {
    let directory: String
    let appleLanguage: String
    let appleLocale: String
    let note: String

    static let zhHans = AppStoreScreenshotLocaleSpec(
        directory: "zh-Hans",
        appleLanguage: "zh-Hans",
        appleLocale: "zh_CN",
        note: ""
    )

    static let submissionPrimary: [AppStoreScreenshotLocaleSpec] = [
        .zhHans,
        AppStoreScreenshotLocaleSpec(
            directory: "zh-Hant",
            appleLanguage: "zh-Hant-TW",
            appleLocale: "zh_TW",
            note: "directory zh-Hant uses zh-Hant-TW app language"
        ),
        AppStoreScreenshotLocaleSpec(
            directory: "en-US",
            appleLanguage: "en",
            appleLocale: "en_US",
            note: ""
        ),
        AppStoreScreenshotLocaleSpec(
            directory: "ja",
            appleLanguage: "ja",
            appleLocale: "ja_JP",
            note: ""
        ),
        AppStoreScreenshotLocaleSpec(
            directory: "es-MX",
            appleLanguage: "es",
            appleLocale: "es_MX",
            note: "directory es-MX uses generic es app language"
        )
    ]

    static func spec(for directory: String) -> AppStoreScreenshotLocaleSpec? {
        submissionPrimary.first { $0.directory == directory }
    }
}

private func screenshotEnvironmentValue(_ name: String) -> String? {
    let env = ProcessInfo.processInfo.environment
    return env[name] ?? env["TEST_RUNNER_\(name)"]
}

private func screenshotEnvironmentList(_ name: String) -> [String] {
    guard let rawValue = screenshotEnvironmentValue(name) else { return [] }
    return
        rawValue
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func appStoreScreenshotRunEnabled() -> Bool {
    guard
        let rawValue = screenshotEnvironmentValue("APP_STORE_SCREENSHOT_RUN")
            ?? screenshotEnvironmentValue("APP_STORE_SCREENSHOT_RUN_BATCH")
    else {
        return false
    }
    let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return ["1", "true", "yes"].contains(normalizedValue)
}

private enum ScreenshotBatchError: LocalizedError {
    case blockers([String])

    var errorDescription: String? {
        switch self {
        case .blockers(let messages):
            return "Batch screenshots have blockers: \(messages.joined(separator: "; "))"
        }
    }
}

private func requireScreenshotBatchWithoutBlockers(_ blockers: [String]) throws {
    guard blockers.isEmpty else { throw ScreenshotBatchError.blockers(blockers) }
}

#if os(iOS)
final class AppStoreScreenshotUITests: XCTestCase {
    // XCTest creates a new instance per test method; platform and locale are vars filled from env vars.

    private var localeSpec = AppStoreScreenshotLocaleSpec.zhHans
    private var iOSPlatformSpec = IOSPlatformSpec.iphone69
    private let appearance = "Light"

    func testSelectedBatchRejectsCollectedBlockers() {
        XCTAssertThrowsError(try requireScreenshotBatchWithoutBlockers(["01_playback: fixture failure"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("01_playback: fixture failure"))
        }
        XCTAssertNoThrow(try requireScreenshotBatchWithoutBlockers([]))
    }

    private var localeDirectory: String { localeSpec.directory }
    private var actualLanguage: String { localeSpec.appleLanguage }
    private var actualLocale: String { localeSpec.appleLocale }
    private var platformGroup: String { iOSPlatformSpec.directory }
    private var collectionDirectory: String { iOSPlatformSpec.collectionDirectory }

    private struct IOSPlatformSpec {
        let directory: String
        let collectionDirectory: String
        let idiom: UIUserInterfaceIdiom

        static let iphone69 = IOSPlatformSpec(
            directory: "iPhone_6_9",
            collectionDirectory: "submission_primary",
            idiom: .phone
        )
        static let iPad13 = IOSPlatformSpec(
            directory: "iPad_13",
            collectionDirectory: "submission_primary",
            idiom: .pad
        )
        static let iphone63 = IOSPlatformSpec(
            directory: "iPhone_6_3",
            collectionDirectory: "device_variants",
            idiom: .phone
        )
        static let iphone61 = IOSPlatformSpec(
            directory: "iPhone_6_1",
            collectionDirectory: "device_variants",
            idiom: .phone
        )
        static let iPad11 = IOSPlatformSpec(
            directory: "iPad_11",
            collectionDirectory: "device_variants",
            idiom: .pad
        )

        static func spec(for directory: String) -> IOSPlatformSpec? {
            switch directory {
            case iphone69.directory: return .iphone69
            case iPad13.directory: return .iPad13
            case iphone63.directory: return .iphone63
            case iphone61.directory: return .iphone61
            case iPad11.directory: return .iPad11
            default: return nil
            }
        }
    }

    // The album ID can come from an env var, so a new test server or album needs no source change.

    private let playbackAlbumName = "The Little Duchess"
    private let playbackAlbumID = "5f0a56af-fd7c-4abb-82d0-55c98eea2a83"
    private let appStoreDemoServerURL = "https://slides.by331.net"
    private let appStoreDemoAPIKey = "123456789"

    private let briefAlbumSelections: [(name: String, id: String)] = [
        ("Augusto Family", "fda0ab91-4868-44ae-8b3b-20cff7c79634"),
        ("Augusto & Mia", "0dc6daf9-27c9-4677-8b7f-6db26abb5008"),
        ("Beijing Cycling", "28339cee-c855-41e9-8eb3-a847bf987f60")
    ]

    private let briefPersonSelections: [(name: String, id: String)] = [
        ("Augusto", "79a64d5f-0b37-4b3b-abbe-4c6fb66165ae"),
        ("Mia", "6a3e11f2-ed9d-4cd8-a26c-66d62b2e3a85"),
        ("Wang", "542737cd-32e1-4a06-a869-a9840827c0d9"),
        ("Ethan", "3ab72f13-c29e-4655-88b5-66e458b4bddc")
    ]

    // Seed the people filter into the Store as JSON (toggles are flaky); this only works in DEBUG+XCTest.

    private let briefPeopleFilterSelectionJSON = """
        {
          "albumIds": [],
          "personFilters": [
            { "personId": "79a64d5f-0b37-4b3b-abbe-4c6fb66165ae", "matchMode": "soloOnly" },
            { "personId": "6a3e11f2-ed9d-4cd8-a26c-66d62b2e3a85", "matchMode": "normal" },
            { "personId": "542737cd-32e1-4a06-a869-a9840827c0d9", "matchMode": "normal" },
            { "personId": "3ab72f13-c29e-4655-88b5-66e458b4bddc", "matchMode": "normal" }
          ],
          "tagIds": []
        }
        """

    // Slot names must match the brief's file names so the delivery directory stays stable.

    enum ScreenshotSlot: String, CaseIterable {
        case playback = "01_playback"
        case playbackMode = "02_playback_mode"
        case filterEntry = "03_filter_entry"
        case peopleFilter = "04_people_filter"
        case albumFilter = "05_album_filter"
        case pinProtection = "06_pin_protection"
        case connectImmich = "07_connect_immich"

        var fileName: String { "\(rawValue).png" }

        var title: String {
            switch self {
            case .playback: return "Playback / Core showcase"
            case .playbackMode: return "Playback mode"
            case .filterEntry: return "Filter summary"
            case .peopleFilter: return "People filter"
            case .albumFilter: return "Album filter"
            case .pinProtection: return "PIN / Access protection"
            case .connectImmich: return "FirstBootView / First-launch server setup"
            }
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false

        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom != .phone && UIDevice.current.userInterfaceIdiom != .pad,
            "This App Store screenshot test only runs on an iPhone or iPad simulator."
        )
        try XCTSkipIf(
            !appStoreScreenshotRunEnabled(),
            "App Store screenshot tests are excluded from the regular UI regression by default. Evidence plans select this suite but set only IMMICHSLIDES_EVIDENCE, which this gate ignores; set APP_STORE_SCREENSHOT_RUN=1 to run them."
        )

        // All screenshots are portrait; the current App Store brief only lists portrait sizes.
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testZhHansIPhone69Screenshots() throws {
        let outputRoot = resolvedOutputRoot()
        let slotDirectory =
            outputRoot
            .appendingPathComponent(localeDirectory)
            .appendingPathComponent("submission_primary")
            .appendingPathComponent(platformGroup)

        try prepareOutputDirectory(slotDirectory)
        try resetManifest(at: outputRoot)

        var blockers: [String] = []

        runSlot(.playback, outputRoot: outputRoot, slotDirectory: slotDirectory, blockers: &blockers) {
            try capturePlayback(outputRoot: outputRoot, slotDirectory: slotDirectory)
        }

        runSlot(.playbackMode, outputRoot: outputRoot, slotDirectory: slotDirectory, blockers: &blockers) {
            try capturePlaybackMode(outputRoot: outputRoot, slotDirectory: slotDirectory)
        }

        runSlot(.filterEntry, outputRoot: outputRoot, slotDirectory: slotDirectory, blockers: &blockers) {
            try captureFilterEntry(outputRoot: outputRoot, slotDirectory: slotDirectory)
        }

        runSlot(.peopleFilter, outputRoot: outputRoot, slotDirectory: slotDirectory, blockers: &blockers) {
            try capturePeopleFilter(outputRoot: outputRoot, slotDirectory: slotDirectory)
        }

        runSlot(.albumFilter, outputRoot: outputRoot, slotDirectory: slotDirectory, blockers: &blockers) {
            try captureAlbumFilter(outputRoot: outputRoot, slotDirectory: slotDirectory)
        }

        runSlot(.pinProtection, outputRoot: outputRoot, slotDirectory: slotDirectory, blockers: &blockers) {
            try capturePinProtection(outputRoot: outputRoot, slotDirectory: slotDirectory)
        }

        runSlot(.connectImmich, outputRoot: outputRoot, slotDirectory: slotDirectory, blockers: &blockers) {
            try captureConnectImmich(outputRoot: outputRoot, slotDirectory: slotDirectory)
        }

        if !blockers.isEmpty {
            XCTFail("App Store screenshots have blockers: \(blockers.joined(separator: "; "))")
        }
    }

    @MainActor
    func testZhHansIPhone69PeopleAndConnectScreenshots() throws {
        let outputRoot = resolvedOutputRoot()
        let slotDirectory =
            outputRoot
            .appendingPathComponent(localeDirectory)
            .appendingPathComponent("submission_primary")
            .appendingPathComponent(platformGroup)
        let targetSlots: [ScreenshotSlot] = [.peopleFilter, .connectImmich]

        try prepareOutputDirectory(slotDirectory, slots: targetSlots)
        try removeManifestRows(outputRoot: outputRoot, slots: targetSlots)

        var blockers: [String] = []

        runSlot(.peopleFilter, outputRoot: outputRoot, slotDirectory: slotDirectory, blockers: &blockers) {
            try capturePeopleFilter(outputRoot: outputRoot, slotDirectory: slotDirectory)
        }

        runSlot(.connectImmich, outputRoot: outputRoot, slotDirectory: slotDirectory, blockers: &blockers) {
            try captureConnectImmich(outputRoot: outputRoot, slotDirectory: slotDirectory)
        }

        if !blockers.isEmpty {
            XCTFail("App Store screenshots 04/07 have blockers: \(blockers.joined(separator: "; "))")
        }
    }

    @MainActor
    func testSubmissionPrimarySelectedScreenshots() throws {
        // Collect slot failures as manifest blockers so later locales still write evidence.

        let requestedPlatform = try requestedIOSPlatformSpec()
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom != requestedPlatform.idiom,
            "The current simulator is not \(requestedPlatform.directory); skipping this iOS screenshot batch."
        )
        iOSPlatformSpec = requestedPlatform

        let outputRoot = resolvedOutputRoot()
        let requestedLocales = try requestedLocaleSpecs()
        let requestedSlots = try requestedScreenshotSlots()

        var batchBlockers: [String] = []
        for locale in requestedLocales {
            localeSpec = locale
            let slotDirectory =
                outputRoot
                .appendingPathComponent(localeDirectory)
                .appendingPathComponent(collectionDirectory)
                .appendingPathComponent(platformGroup)

            try prepareOutputDirectory(slotDirectory, slots: requestedSlots)
            try removeManifestRows(outputRoot: outputRoot, slots: requestedSlots)

            var blockers: [String] = []
            for slot in requestedSlots {
                runSlot(slot, outputRoot: outputRoot, slotDirectory: slotDirectory, blockers: &blockers) {
                    try capture(slot: slot, outputRoot: outputRoot, slotDirectory: slotDirectory)
                }
            }
            batchBlockers.append(contentsOf: blockers.map { "\(locale.directory)/\($0)" })
        }
        try requireScreenshotBatchWithoutBlockers(batchBlockers)
    }
}

private extension AppStoreScreenshotUITests {
    typealias SlotCapture = () throws -> Void

    private func requestedIOSPlatformSpec() throws -> IOSPlatformSpec {
        let platformName = screenshotEnvironmentValue("APP_STORE_SCREENSHOT_PLATFORM_GROUP") ?? platformGroup
        guard let platform = IOSPlatformSpec.spec(for: platformName) else {
            throw ScreenshotError.message("Unknown iOS screenshot platform: \(platformName)")
        }
        return platform
    }

    private func requestedLocaleSpecs() throws -> [AppStoreScreenshotLocaleSpec] {
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

    private func requestedScreenshotSlots() throws -> [ScreenshotSlot] {
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
        let app = try launchIntoFilterSummary(disablePlaybackEntryHint: false)

        try openAlbumFilterFromSummary(app)

        let playbackAlbumID = try resolvedPlaybackAlbumID()
        try tapCard(
            identifier: albumCardIdentifier(id: playbackAlbumID),
            in: app,
            timeout: 15,
            missingMessage: "Album filter page should find \(playbackAlbumName)"
        )

        try tapBackButton(in: app, expectedPageAfterBack: app.buttons["filterSummary.startPlayback.button"])

        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        try waitOrThrow(
            startPlaybackButton, timeout: 12, "Start playback button should appear after selecting an album")
        guard startPlaybackButton.isEnabled else {
            throw ScreenshotError.message(
                "Start playback button is disabled; the album selection may not have taken effect.")
        }
        tapElement(startPlaybackButton)

        try waitForPlaybackPageReady(app)
        try waitOrThrow(
            app.otherElements["slideshow.entryHint.banner"],
            timeout: 8,
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
            app.buttons["mode.random.button"], timeout: 12, "Mode selection should show the random playback option")
        try waitOrThrow(
            app.buttons["mode.filtered.button"], timeout: 12, "Mode selection should show the filtered playback option")

        capture(app: app, slot: .playbackMode, outputRoot: outputRoot, slotDirectory: slotDirectory)
        app.terminate()
    }

    @MainActor
    func captureFilterEntry(outputRoot: URL, slotDirectory: URL) throws {
        let app = try launchIntoFilterSummary()

        try selectFirstAlbumAndPersonCardsForSummary(app)

        try waitOrThrow(
            app.buttons["filterSummary.album.button"], timeout: 12, "Filter summary should show the album entry")
        try waitOrThrow(
            app.buttons["filterSummary.person.button"], timeout: 12, "Filter summary should show the people entry")
        try waitUntilOrThrow(
            timeout: 8, "Filter summary should enable Start playback after albums and people are selected"
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
        let app = try launchIntoSlideShow(disablePlaybackEntryHint: true)

        try openSettingsFromSlideShow(app)
        try openSettingsSection(app: app, sectionID: "settings.item.accessProtection")

        let pinInputButton = app.buttons["settings.pin.input.enable"]
        try waitOrThrow(pinInputButton, timeout: 12, "Access protection page should show the set-PIN entry")
        tapElement(pinInputButton)

        try waitOrThrow(
            app.buttons["pinEntry.close.button"], timeout: 8, "Choosing set PIN should show the PIN overlay")
        try waitOrThrow(app.buttons["pinEntry.digit.1.button"], timeout: 8, "PIN overlay should show the number pad")

        capture(app: app, slot: .pinProtection, outputRoot: outputRoot, slotDirectory: slotDirectory)
        app.terminate()
    }

    @MainActor
    func captureConnectImmich(outputRoot: URL, slotDirectory: URL) throws {
        let app = makeBaseLaunchApp(disablePlaybackEntryHint: true)
        app.launchEnvironment["UI_TEST_APP_STORE_SCREENSHOT_PREFILL_CONNECTION"] = "1"
        app.launchEnvironment["UI_TEST_APP_STORE_SCREENSHOT_SERVER_URL"] = appStoreDemoServerURL
        app.launchEnvironment["UI_TEST_APP_STORE_SCREENSHOT_API_KEY"] = appStoreDemoAPIKey
        app.launch()

        let serverURLField = app.textFields["firstboot.serverURL.field"]
        try waitOrThrow(serverURLField, timeout: 12, "A fresh install should open the first-launch server setup page")
        let displayedURL = (serverURLField.value as? String) ?? ""
        guard displayedURL.contains(appStoreDemoServerURL) else {
            throw ScreenshotError.message("First-launch page should prefill the screenshot demo URL.")
        }

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        try waitOrThrow(apiKeyField, timeout: 8, "First-launch page should show the secure API Key field")

        try waitUntilOrThrow(timeout: 5, "Save configuration button should be enabled after the screenshot prefill") {
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

private extension AppStoreScreenshotUITests {
    @MainActor
    func selectFirstAlbumAndPersonCardsForSummary(_ app: XCUIApplication) throws {
        try openAlbumFilterFromSummary(app)
        try tapFirstCards(
            prefix: "albumFilter.album.",
            count: 3,
            in: app,
            missingMessage: "Album filter page should show at least the first 3 albums"
        )
        try tapBackButton(in: app, expectedPageAfterBack: app.buttons["filterSummary.startPlayback.button"])

        try openPersonFilterFromSummary(app)
        try tapFirstCards(
            prefix: "personFilter.person.",
            count: 4,
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
                timeout: 12,
                missingMessage: "Album filter page should find \(album.name)"
            )
        }
    }

    func waitForBriefPeopleCardsForScreenshot(_ app: XCUIApplication) throws {
        for person in briefPersonSelections {
            try waitOrThrow(
                exactCardQuery(identifier: personCardIdentifier(id: person.id), in: app).firstMatch,
                timeout: 10,
                "People filter page should show the person named in the brief: \(person.name)"
            )
        }
    }

    @MainActor
    func openAlbumFilterFromSummary(_ app: XCUIApplication) throws {
        let albumButton = app.buttons["filterSummary.album.button"]
        try waitOrThrow(albumButton, timeout: 12, "Filter summary should show the album entry")
        tapElement(albumButton)
        try waitForFilterCards(
            prefix: "albumFilter.album.", in: app, message: "Album filter page should show album cards")
    }

    @MainActor
    func openPersonFilterFromSummary(_ app: XCUIApplication) throws {
        let personButton = app.buttons["filterSummary.person.button"]
        try waitOrThrow(personButton, timeout: 12, "Filter summary should show the people entry")
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
                timeout: 8,
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
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
        try waitOrThrow(firstCard, timeout: 12, message)
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

private extension AppStoreScreenshotUITests {
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
        disablePlaybackEntryHint: Bool = true,
        seedFilterSelection: Bool = false,
        filterSelectionJSON: String? = nil
    ) throws -> XCUIApplication {
        let app = makeBaseLaunchApp(
            disablePlaybackEntryHint: disablePlaybackEntryHint,
            seedFilterSelection: seedFilterSelection,
            filterSelectionJSON: filterSelectionJSON
        )
        try injectRealTestServer(into: app)
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launch()

        try startFilteredFlowFromModeSelection(app)
        return app
    }

    @MainActor
    func launchIntoSlideShow(disablePlaybackEntryHint: Bool) throws -> XCUIApplication {
        let app = try launchIntoFilterSummary(
            disablePlaybackEntryHint: disablePlaybackEntryHint,
            seedFilterSelection: true
        )

        let startPlaybackButton = app.buttons["filterSummary.startPlayback.button"]
        try waitOrThrow(startPlaybackButton, timeout: 12, "Filter summary should show the Start playback button")
        guard startPlaybackButton.isEnabled else {
            throw ScreenshotError.message("Start playback button is disabled; there may be no filter criteria.")
        }
        tapElement(startPlaybackButton)
        try waitForPlaybackPageReady(app)
        return app
    }

    func makeBaseLaunchApp(
        disablePlaybackEntryHint: Bool = true,
        seedFilterSelection: Bool = false,
        filterSelectionJSON: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()

        // Launch clean for each screenshot so cache, PIN or hint state never leaks into the next one.

        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_COLOR_SCHEME"] = "light"
        app.launchEnvironment["UI_TEST_DISABLE_DEBUG_FILL_APIKEY_BUTTON"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        if seedFilterSelection || filterSelectionJSON != nil {
            app.launchEnvironment["UI_TEST_SEED_FILTER_SELECTION"] = "1"
        }
        if let filterSelectionJSON {
            app.launchEnvironment["UI_TEST_FILTER_SELECTION_JSON"] = filterSelectionJSON
        }

        if disablePlaybackEntryHint {
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
            app.buttons["mode.filtered.button"], timeout: 12, "Mode selection should show the filtered playback option")
        tapElement(app.buttons["mode.filtered.button"])

        let continueButton = app.buttons["mode.continue.button"]
        try waitOrThrow(continueButton, timeout: 12, "Mode selection should show the Continue button")
        guard continueButton.isEnabled else {
            throw ScreenshotError.message("Continue button is disabled after choosing filtered playback.")
        }
        tapElement(continueButton)

        try waitOrThrow(
            app.buttons["filterSummary.startPlayback.button"], timeout: 15, "Should reach the filter summary")
    }

    @MainActor
    func waitForPlaybackPageReady(_ app: XCUIApplication) throws {
        try waitOrThrow(
            app.buttons["slideshow.control.settings.button"], timeout: 25,
            "Playback page should show the settings button")
        try waitOrThrow(
            app.buttons["slideshow.control.playPause.button"], timeout: 12,
            "Playback page should show the play/pause button")

        // Wait briefly after entering playback to avoid capturing EXIF before it settles.

        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    }
}

private extension AppStoreScreenshotUITests {
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

            | file | slot | locale | actual_language | actual_locale | platform_group | simulator_name | runtime | pixel_size | theme | ui_language_matches | status | notes |
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
            | \(relativeFilePath) | \(slot.rawValue) - \(slot.title) | \(localeDirectory) | \(actualLanguage) | \(actualLocale) | \(platformGroup) | \(UIDevice.current.name) | \(ProcessInfo.processInfo.operatingSystemVersionString) | \(pixelSize) | \(appearance) | yes | \(status) | \(escapedNotes) |

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

private extension AppStoreScreenshotUITests {
    @MainActor
    func openSettingsFromSlideShow(_ app: XCUIApplication) throws {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        try waitOrThrow(settingsButton, timeout: 15, "Playback page should show the settings button")
        tapElement(settingsButton)
        try waitUntilOrThrow(timeout: 12, "Opening settings from playback should show the settings list") {
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
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
            try waitOrThrow(expectedPageAfterBack, timeout: 8, "Tapping Back should return to the expected page")
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard condition() else {
            throw ScreenshotError.message(message)
        }
    }
}

private enum ScreenshotError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}
#endif

#if os(tvOS)
final class AppStoreScreenshotTVOSUITests: XCTestCase {
    // Current export locale; the older zh-Hans-only tests keep the default.
    private var localeSpec = AppStoreScreenshotLocaleSpec.zhHans
    private let platformGroup = "tvOS_4K"
    private let appearance = "Light"

    func testSelectedBatchRejectsCollectedBlockers() {
        XCTAssertThrowsError(try requireScreenshotBatchWithoutBlockers(["01_playback: fixture failure"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("01_playback: fixture failure"))
        }
        XCTAssertNoThrow(try requireScreenshotBatchWithoutBlockers([]))
    }

    private var localeDirectory: String { localeSpec.directory }
    private var actualLanguage: String { localeSpec.appleLanguage }
    private var actualLocale: String { localeSpec.appleLocale }

    // Seed filters by album ID so the remote never has to scroll the list to find them.

    private let playbackAlbumName = "The Little Duchess"
    private let playbackAlbumID = "5f0a56af-fd7c-4abb-82d0-55c98eea2a83"

    private let appStoreDemoServerURL = "https://slides.by331.net"
    private let appStoreDemoAPIKey = "123456789"

    private let briefAlbumSelections: [(name: String, id: String)] = [
        ("Augusto Family", "fda0ab91-4868-44ae-8b3b-20cff7c79634"),
        ("Augusto & Mia", "0dc6daf9-27c9-4677-8b7f-6db26abb5008"),
        ("Beijing Cycling", "28339cee-c855-41e9-8eb3-a847bf987f60")
    ]

    private let briefPersonSelections: [(name: String, id: String)] = [
        ("Augusto", "79a64d5f-0b37-4b3b-abbe-4c6fb66165ae"),
        ("Mia", "6a3e11f2-ed9d-4cd8-a26c-66d62b2e3a85"),
        ("Wang", "542737cd-32e1-4a06-a869-a9840827c0d9"),
        ("Ethan", "3ab72f13-c29e-4655-88b5-66e458b4bddc")
    ]

    private var playbackAlbumSelectionJSON: String {
        """
        {
          "albumIds": ["\(playbackAlbumID)"],
          "personFilters": [],
          "tagIds": []
        }
        """
    }

    private var briefAlbumFilterSelectionJSON: String {
        let albumIDs =
            briefAlbumSelections
            .map { "\"\($0.id)\"" }
            .joined(separator: ", ")
        return """
            {
              "albumIds": [\(albumIDs)],
              "personFilters": [],
              "tagIds": []
            }
            """
    }

    private var briefPeopleFilterSelectionJSON: String {
        """
        {
          "albumIds": [],
          "personFilters": [
            { "personId": "79a64d5f-0b37-4b3b-abbe-4c6fb66165ae", "matchMode": "soloOnly" },
            { "personId": "6a3e11f2-ed9d-4cd8-a26c-66d62b2e3a85", "matchMode": "normal" },
            { "personId": "542737cd-32e1-4a06-a869-a9840827c0d9", "matchMode": "normal" },
            { "personId": "3ab72f13-c29e-4655-88b5-66e458b4bddc", "matchMode": "normal" }
          ],
          "tagIds": []
        }
        """
    }

    private var briefCombinedFilterSelectionJSON: String {
        let albumIDs =
            briefAlbumSelections
            .map { "\"\($0.id)\"" }
            .joined(separator: ", ")
        return """
            {
              "albumIds": [\(albumIDs)],
              "personFilters": [
                { "personId": "79a64d5f-0b37-4b3b-abbe-4c6fb66165ae", "matchMode": "soloOnly" },
                { "personId": "6a3e11f2-ed9d-4cd8-a26c-66d62b2e3a85", "matchMode": "normal" },
                { "personId": "542737cd-32e1-4a06-a869-a9840827c0d9", "matchMode": "normal" },
                { "personId": "3ab72f13-c29e-4655-88b5-66e458b4bddc", "matchMode": "normal" }
              ],
              "tagIds": []
            }
            """
    }

    enum ScreenshotSlot: String, CaseIterable {
        case playback = "01_playback"
        case playbackMode = "02_playback_mode"
        case filterEntry = "03_filter_entry"
        case peopleFilter = "04_people_filter"
        case albumFilter = "05_album_filter"
        case pinProtection = "06_pin_protection"
        case connectImmich = "07_connect_immich"

        var fileName: String { "\(rawValue).png" }

        var title: String {
            switch self {
            case .playback: return "Playback / Core showcase"
            case .playbackMode: return "Playback mode"
            case .filterEntry: return "Filter summary"
            case .peopleFilter: return "People filter"
            case .albumFilter: return "Album filter"
            case .pinProtection: return "PIN / Access protection"
            case .connectImmich: return "FirstBootView / First-launch server setup"
            }
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false

        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom != .tv,
            "This App Store screenshot test only runs on a tvOS simulator."
        )
        try XCTSkipIf(
            !appStoreScreenshotRunEnabled(),
            "App Store screenshot tests are excluded from the regular UI regression by default. Evidence plans select this suite but set only IMMICHSLIDES_EVIDENCE, which this gate ignores; set APP_STORE_SCREENSHOT_RUN=1 to run them."
        )
    }

    @MainActor
    func testZhHansTVOS4KScreenshots() throws {
        let outputRoot = resolvedOutputRoot()
        let slotDirectory =
            outputRoot
            .appendingPathComponent(localeDirectory)
            .appendingPathComponent("submission_primary")
            .appendingPathComponent(platformGroup)

        try prepareOutputDirectory(slotDirectory)
        try removeManifestRows(outputRoot: outputRoot, slots: ScreenshotSlot.allCases)

        // A failed capture leaves the session on an unknown scene, so later slots would be invalid.

        try capturePlayback(outputRoot: outputRoot, slotDirectory: slotDirectory)
        try capturePlaybackMode(outputRoot: outputRoot, slotDirectory: slotDirectory)
        try captureFilterEntry(outputRoot: outputRoot, slotDirectory: slotDirectory)
        try capturePeopleFilter(outputRoot: outputRoot, slotDirectory: slotDirectory)
        try captureAlbumFilter(outputRoot: outputRoot, slotDirectory: slotDirectory)
        try capturePinProtection(outputRoot: outputRoot, slotDirectory: slotDirectory)
        try captureConnectImmich(outputRoot: outputRoot, slotDirectory: slotDirectory)
    }

    @MainActor
    func testZhHansTVOS4KPlaybackScreenshot() throws {
        let outputRoot = resolvedOutputRoot()
        let slotDirectory =
            outputRoot
            .appendingPathComponent(localeDirectory)
            .appendingPathComponent("submission_primary")
            .appendingPathComponent(platformGroup)

        try prepareOutputDirectory(slotDirectory, slots: [.playback])
        try removeManifestRows(outputRoot: outputRoot, slots: [.playback])
        try capturePlayback(outputRoot: outputRoot, slotDirectory: slotDirectory)
    }

    @MainActor
    func testZhHansTVOS4KConnectScreenshot() throws {
        let outputRoot = resolvedOutputRoot()
        let slotDirectory =
            outputRoot
            .appendingPathComponent(localeDirectory)
            .appendingPathComponent("submission_primary")
            .appendingPathComponent(platformGroup)

        try prepareOutputDirectory(slotDirectory, slots: [.connectImmich])
        try removeManifestRows(outputRoot: outputRoot, slots: [.connectImmich])
        try captureConnectImmich(outputRoot: outputRoot, slotDirectory: slotDirectory)
    }

    @MainActor
    func testSubmissionPrimarySelectedScreenshots() throws {
        let outputRoot = resolvedOutputRoot()
        let requestedLocales = try requestedLocaleSpecs()
        let requestedSlots = try requestedScreenshotSlots()

        var batchBlockers: [String] = []
        for locale in requestedLocales {
            localeSpec = locale
            let slotDirectory =
                outputRoot
                .appendingPathComponent(localeDirectory)
                .appendingPathComponent("submission_primary")
                .appendingPathComponent(platformGroup)

            try prepareOutputDirectory(slotDirectory, slots: requestedSlots)
            try removeManifestRows(outputRoot: outputRoot, slots: requestedSlots)

            var blockers: [String] = []
            for slot in requestedSlots {
                runSlot(slot, outputRoot: outputRoot, slotDirectory: slotDirectory, blockers: &blockers) {
                    try capture(slot: slot, outputRoot: outputRoot, slotDirectory: slotDirectory)
                }
            }
            batchBlockers.append(contentsOf: blockers.map { "\(locale.directory)/\($0)" })
        }
        try requireScreenshotBatchWithoutBlockers(batchBlockers)
    }
}

private extension AppStoreScreenshotTVOSUITests {
    typealias SlotCapture = () throws -> Void

    private func requestedLocaleSpecs() throws -> [AppStoreScreenshotLocaleSpec] {
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

    private func requestedScreenshotSlots() throws -> [ScreenshotSlot] {
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
            prepareFilterSummaryVisuals: false,
            disablePlaybackEntryHint: false
        )
        try focusStartPlaybackButton(in: app)
        XCUIRemote.shared.press(.select)

        try waitOrThrow(
            app.buttons["slideshow.control.settings.button"],
            timeout: 25,
            "tvOS playback page should show the settings button"
        )
        try waitOrThrow(
            app.buttons["slideshow.control.playPause.button"],
            timeout: 12,
            "tvOS playback page should show the play/pause button"
        )
        try waitOrThrow(
            app.staticTexts["slideshow.entryHint.title"],
            timeout: 8,
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
            app.buttons["mode.random.button"], timeout: 12, "Mode selection should show the random playback option")
        try waitOrThrow(
            app.buttons["mode.filtered.button"], timeout: 12, "Mode selection should show the filtered playback option")
        waitForFocusVisualSettle()

        capture(app: app, slot: .playbackMode, outputRoot: outputRoot, slotDirectory: slotDirectory)
        app.terminate()
    }

    @MainActor
    func captureFilterEntry(outputRoot: URL, slotDirectory: URL) throws {
        let app = try launchIntoFilterSummary(filterSelectionJSON: briefCombinedFilterSelectionJSON)

        try waitOrThrow(
            app.buttons["filterSummary.album.button"], timeout: 12, "Filter summary should show the album entry")
        try waitOrThrow(
            app.buttons["filterSummary.person.button"], timeout: 12, "Filter summary should show the people entry")
        try waitOrThrow(
            app.staticTexts["filterSummary.album.ready"], timeout: 15,
            "Filter summary album stage should finish loading")
        try waitOrThrow(
            app.staticTexts["filterSummary.people.ready"], timeout: 15,
            "Filter summary people stage should finish loading")
        try waitUntilOrThrow(timeout: 8, "Filter summary should enable Start playback after filters are seeded") {
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
            prepareFilterSummaryVisuals: false
        )

        try openPersonFilterFromSummary(app)
        try waitOrThrow(
            app.buttons["personFilter.back.button"], timeout: 12, "People filter page should show the Back button")
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
            prepareFilterSummaryVisuals: false
        )

        try openAlbumFilterFromSummary(app)
        try waitOrThrow(
            app.buttons["albumFilter.back.button"], timeout: 12, "Album filter page should show the Back button")
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
        try waitOrThrow(pinInputButton, timeout: 12, "Access protection page should show the set-PIN entry")
        try waitForFocus(pinInputButton, timeout: 8, "Access protection page should default focus to the set-PIN entry")
        XCUIRemote.shared.press(.select)

        try waitOrThrow(
            app.buttons["pinEntry.close.button"], timeout: 8, "Choosing set PIN should show the PIN overlay")
        try waitOrThrow(app.buttons["pinEntry.digit.1.button"], timeout: 8, "PIN overlay should show the number pad")
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
            serverURLField, timeout: 15, "A fresh install should open the tvOS first-launch server setup page")
        let displayedURL = (serverURLField.value as? String) ?? ""
        guard displayedURL.contains(appStoreDemoServerURL) else {
            throw TVOSScreenshotError.message("tvOS first-launch page should prefill the screenshot demo URL.")
        }

        try waitOrThrow(
            app.secureTextFields["firstboot.apiKey.field"], timeout: 8,
            "tvOS first-launch page should show the secure API Key field")
        try waitOrThrow(
            app.descendants(matching: .any)["firstboot.form.card"],
            timeout: 8,
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

private extension AppStoreScreenshotTVOSUITests {
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
        prepareFilterSummaryVisuals: Bool = true,
        disablePlaybackEntryHint: Bool = true
    ) throws -> XCUIApplication {
        let app = makeBaseLaunchApp(
            filterSelectionJSON: filterSelectionJSON,
            disablePlaybackEntryHint: disablePlaybackEntryHint
        )
        try injectRealTestServer(into: app)
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        if prepareFilterSummaryVisuals {
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
            prepareFilterSummaryVisuals: false
        )
        try focusStartPlaybackButton(in: app)
        XCUIRemote.shared.press(.select)
        try waitOrThrow(
            app.buttons["slideshow.control.settings.button"], timeout: 25,
            "Starting playback should open the tvOS playback page")
        return app
    }

    func makeBaseLaunchApp(
        filterSelectionJSON: String? = nil,
        disablePlaybackEntryHint: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()

        // Launch clean for each screenshot so PIN, focus, server or filter state never leaks into the next one.

        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_COLOR_SCHEME"] = "light"
        app.launchEnvironment["UI_TEST_DISABLE_DEBUG_FILL_APIKEY_BUTTON"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        if disablePlaybackEntryHint {
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
        try waitOrThrow(filteredButton, timeout: 12, "Mode selection should show the filtered playback option")
        XCUIRemote.shared.press(.right)
        waitForFocusVisualSettle(seconds: 0.25)
        XCUIRemote.shared.press(.select)

        let continueButton = app.buttons["mode.continue.button"]
        try waitOrThrow(continueButton, timeout: 12, "Mode selection should show the Continue button")
        guard continueButton.isEnabled else {
            throw TVOSScreenshotError.message("Continue button is disabled after choosing filtered playback.")
        }
        XCUIRemote.shared.press(.down)
        waitForFocusVisualSettle(seconds: 0.25)
        XCUIRemote.shared.press(.select)

        try waitOrThrow(
            app.buttons["filterSummary.startPlayback.button"], timeout: 15, "Should reach the tvOS filter summary")
    }
}

private extension AppStoreScreenshotTVOSUITests {
    @MainActor
    func openAlbumFilterFromSummary(_ app: XCUIApplication) throws {
        let albumButton = app.buttons["filterSummary.album.button"]
        try waitOrThrow(albumButton, timeout: 12, "Filter summary should show the album entry")
        try focusFilterSummaryAlbumButton(in: app)
        XCUIRemote.shared.press(.select)
        try waitOrThrow(app.buttons["albumFilter.back.button"], timeout: 12, "Should reach the tvOS album filter page")
    }

    @MainActor
    func openPersonFilterFromSummary(_ app: XCUIApplication) throws {
        let peopleButton = app.buttons["filterSummary.person.button"]
        try waitOrThrow(peopleButton, timeout: 12, "Filter summary should show the people entry")
        try focusFilterSummaryPeopleButton(in: app)
        XCUIRemote.shared.press(.select)
        try waitOrThrow(
            app.buttons["personFilter.back.button"], timeout: 12, "Should reach the tvOS people filter page")
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
        try waitForFocus(peopleButton, timeout: 3, "Filter summary should be able to move focus to the people entry")
    }

    @MainActor
    func focusStartPlaybackButton(in app: XCUIApplication) throws {
        let startButton = app.buttons["filterSummary.startPlayback.button"]
        try waitOrThrow(startButton, timeout: 12, "Filter summary should show the Start playback button")

        for _ in 0..<10 {
            if isFocused(startButton) { return }
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.15)
        }

        try waitForFocus(startButton, timeout: 3, "Filter summary should be able to move focus to Start playback")
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
                timeout: 12,
                "tvOS album filter page should show the album named in the brief: \(album.name)"
            )
        }
    }

    func waitForBriefPeopleCardsForScreenshot(_ app: XCUIApplication) throws {
        for person in briefPersonSelections {
            try waitOrThrow(
                exactElement(identifier: personCardIdentifier(id: person.id), in: app),
                timeout: 12,
                "tvOS people filter page should show the person named in the brief: \(person.name)"
            )
        }
    }
}

private extension AppStoreScreenshotTVOSUITests {
    @MainActor
    func openSettingsFromSlideShow(_ app: XCUIApplication) throws {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        try waitOrThrow(settingsButton, timeout: 15, "Playback page should show the settings button")

        // Press Left repeatedly to bring focus back to the leftmost settings button.

        for _ in 0..<6 {
            if isFocused(settingsButton) { break }
            XCUIRemote.shared.press(.left)
            waitForFocusVisualSettle(seconds: 0.12)
        }

        try waitForFocus(
            settingsButton, timeout: 5, "Focus should return to the settings button before opening settings")
        XCUIRemote.shared.press(.select)
        try waitUntilOrThrow(timeout: 10, "Pressing the settings button should open settings home") {
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
            timeout: 8,
            failureMessage: "Settings home should show the playback settings entry"
        )

        for _ in 0..<8 {
            if isFocused(playbackItem) { break }
            XCUIRemote.shared.press(.up)
            waitForFocusVisualSettle(seconds: 0.12)
        }
        try waitForFocus(
            playbackItem, timeout: 6, "Settings home should be able to settle focus on the playback settings entry")

        for _ in 0..<downStepsFromPlayback {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle(seconds: 0.15)
        }

        let target = try waitForSettingsControl(
            app: app,
            identifier: identifier,
            timeout: 8,
            failureMessage: failureMessage
        )
        try waitForFocus(target, timeout: 6, failureMessage)
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        if let element = settingsControlCandidates(app: app, identifier: identifier).first(where: \.exists) {
            return element
        }
        throw TVOSScreenshotError.message(failureMessage)
    }
}

private extension AppStoreScreenshotTVOSUITests {
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

            | file | slot | locale | actual_language | actual_locale | platform_group | simulator_name | runtime | pixel_size | theme | ui_language_matches | status | notes |
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
            | \(relativeFilePath) | \(slot.rawValue) - \(slot.title) | \(localeDirectory) | \(actualLanguage) | \(actualLocale) | \(platformGroup) | \(UIDevice.current.name) | \(ProcessInfo.processInfo.operatingSystemVersionString) | \(pixelSize) | \(appearance) | yes | \(status) | \(escapedNotes) |

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

private extension AppStoreScreenshotTVOSUITests {
    func waitOrThrow(_ element: XCUIElement, timeout: TimeInterval, _ message: String) throws {
        guard element.waitForExistence(timeout: timeout) else {
            throw TVOSScreenshotError.message(message)
        }
    }

    func waitUntilOrThrow(timeout: TimeInterval, _ message: String, condition: @escaping () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
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

private enum TVOSScreenshotError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}
#endif
