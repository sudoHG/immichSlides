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

enum AppStoreScreenshotUITestsWaitTiming {
    static let connectionTimeoutSeconds: TimeInterval = TestWait.seconds(.infrastructure(15))
    static let controlAppearanceTimeoutSeconds: TimeInterval = TestWait.seconds(.product(8))
    static let elementAppearanceTimeoutSeconds: TimeInterval = TestWait.seconds(.product(5))
    static let hintAnimationSettleSeconds: TimeInterval = TestWait.seconds(.product(1.2))
    static let identityPollSeconds: TimeInterval = TestWait.seconds(.product(0.3))
    static let navigationTimeoutSeconds: TimeInterval = TestWait.seconds(.product(10))
    static let playbackEntryTimeoutSeconds: TimeInterval = TestWait.seconds(.infrastructure(25))
    static let pollIntervalSeconds: TimeInterval = TestWait.seconds(.product(0.1))
    static let screenTransitionTimeoutSeconds: TimeInterval = TestWait.seconds(.product(12))
    static let settingsChangeTimeoutSeconds: TimeInterval = TestWait.seconds(.product(6))
    static let shortInteractionTimeoutSeconds: TimeInterval = TestWait.seconds(.product(3))
    static let transitionPollSeconds: TimeInterval = TestWait.seconds(.product(0.4))
}

enum AppStoreScreenshotUITestsScreenshotSelection {
    static let albumCardCount: Int = 3
    static let personCardCount: Int = 4
}

// Bind directory name, launch language and region together so a directory never mismatches the actual language.

struct AppStoreScreenshotLocaleSpec {
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

func screenshotEnvironmentValue(_ name: String) -> String? {
    let env = ProcessInfo.processInfo.environment
    return env[name] ?? env["TEST_RUNNER_\(name)"]
}

func screenshotEnvironmentList(_ name: String) -> [String] {
    guard let rawValue = screenshotEnvironmentValue(name) else { return [] }
    return
        rawValue
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

func isAppStoreScreenshotRunEnabled() -> Bool {
    guard
        let rawValue = screenshotEnvironmentValue("APP_STORE_SCREENSHOT_RUN")
            ?? screenshotEnvironmentValue("APP_STORE_SCREENSHOT_RUN_BATCH")
    else {
        return false
    }
    let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return ["1", "true", "yes"].contains(normalizedValue)
}

enum ScreenshotBatchError: LocalizedError {
    case blockers([String])

    var errorDescription: String? {
        switch self {
        case .blockers(let messages):
            return "Batch screenshots have blockers: \(messages.joined(separator: "; "))"
        }
    }
}

func requireScreenshotBatchWithoutBlockers(_ blockers: [String]) throws {
    guard blockers.isEmpty else { throw ScreenshotBatchError.blockers(blockers) }
}

#if os(iOS)
final class AppStoreScreenshotUITests: XCTestCase {
    // XCTest creates a new instance per test method; platform and locale are vars filled from env vars.

    var localeSpec = AppStoreScreenshotLocaleSpec.zhHans
    var iOSPlatformSpec = IOSPlatformSpec.iphone69
    let appearance = "Light"

    func testSelectedBatchRejectsCollectedBlockers() {
        XCTAssertThrowsError(try requireScreenshotBatchWithoutBlockers(["01_playback: fixture failure"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("01_playback: fixture failure"))
        }
        XCTAssertNoThrow(try requireScreenshotBatchWithoutBlockers([]))
    }

    var localeDirectory: String { localeSpec.directory }
    var actualLanguage: String { localeSpec.appleLanguage }
    var actualLocale: String { localeSpec.appleLocale }
    var platformGroup: String { iOSPlatformSpec.directory }
    var collectionDirectory: String { iOSPlatformSpec.collectionDirectory }

    struct IOSPlatformSpec {
        let directory: String
        let collectionDirectory: String
        let idiom: UIUserInterfaceIdiom
        // Portrait pixel sizes App Store Connect accepts for the slot; nil means the slot is not validated.
        var acceptedPortraitPixelSizes: [String]? = nil

        static let iphone69 = IOSPlatformSpec(
            directory: "iPhone_6_9",
            collectionDirectory: "submission_primary",
            idiom: .phone,
            acceptedPortraitPixelSizes: ["1320x2868", "1290x2796", "1260x2736"]
        )
        static let iPad13 = IOSPlatformSpec(
            directory: "iPad_13",
            collectionDirectory: "submission_primary",
            idiom: .pad,
            acceptedPortraitPixelSizes: ["2064x2752", "2048x2732"]
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

        func acceptsPixelSize(_ pixelSize: String) -> Bool {
            guard let accepted = acceptedPortraitPixelSizes else { return true }
            let parts = pixelSize.split(separator: "x")
            let swapped = parts.count == 2 ? "\(parts[1])x\(parts[0])" : pixelSize
            return accepted.contains(pixelSize) || accepted.contains(swapped)
        }

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

    let playbackAlbumName = "The Little Duchess"
    let playbackAlbumID = "5f0a56af-fd7c-4abb-82d0-55c98eea2a83"
    let appStoreDemoServerURL = "https://slides.by331.net"
    let appStoreDemoAPIKey = "123456789"

    let briefAlbumSelections: [(name: String, id: String)] = [
        ("Augusto Family", "fda0ab91-4868-44ae-8b3b-20cff7c79634"),
        ("Augusto & Mia", "0dc6daf9-27c9-4677-8b7f-6db26abb5008"),
        ("Beijing Cycling", "28339cee-c855-41e9-8eb3-a847bf987f60")
    ]

    let briefPersonSelections: [(name: String, id: String)] = [
        ("Augusto", "79a64d5f-0b37-4b3b-abbe-4c6fb66165ae"),
        ("Mia", "6a3e11f2-ed9d-4cd8-a26c-66d62b2e3a85"),
        ("Wang", "542737cd-32e1-4a06-a869-a9840827c0d9"),
        ("Ethan", "3ab72f13-c29e-4655-88b5-66e458b4bddc")
    ]

    // Seed the people filter into the Store as JSON (toggles are flaky); this only works in DEBUG+XCTest.

    let briefPeopleFilterSelectionJSON = """
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
            !isAppStoreScreenshotRunEnabled(),
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

extension AppStoreScreenshotUITests {
    typealias SlotCapture = () throws -> Void
}

enum ScreenshotError: LocalizedError {
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

extension AppStoreScreenshotTVOSUITests {
    typealias SlotCapture = () throws -> Void
}

enum TVOSScreenshotError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}
#endif
