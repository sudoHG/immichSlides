import ImageIO
import XCTest

#if os(tvOS)
final class AppStoreScreenshotTVOSUITests: XCTestCase {
    // Current export locale; the older zh-Hans-only tests keep the default.
    var localeSpec = AppStoreScreenshotLocaleSpec.zhHans
    let platformGroup = "tvOS_4K"
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

    // Seed filters by album ID so the remote never has to scroll the list to find them.

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

    var playbackAlbumSelectionJSON: String {
        """
        {
          "albumIds": ["\(playbackAlbumID)"],
          "personFilters": [],
          "tagIds": []
        }
        """
    }

    var briefAlbumFilterSelectionJSON: String {
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

    var briefPeopleFilterSelectionJSON: String {
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

    var briefCombinedFilterSelectionJSON: String {
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
            !isAppStoreScreenshotRunEnabled(),
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
#endif
