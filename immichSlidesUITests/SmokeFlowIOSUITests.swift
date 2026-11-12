import XCTest

#if os(iOS)
final class SmokeFlowIOSUITests: XCTestCase {
    override func invokeTest() {
        FirstFailureContext.reset()
        super.invokeTest()
    }

    override func record(_ issue: XCTIssue) {
        FirstFailureEvidence.record(self, issue: issue)
        super.record(issue)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        FirstFailureContext.reset()
        FirstFailureOrientation.set(.portrait)
    }

    @MainActor
    func testFirstBoot() throws {
        try flow { app, guardWait, input in
            try configure(app, guardWait, input: input)
            try chooseMode(app, guardWait, filtered: false)
            try playback(app, guardWait)
            try action(guardWait) { app.terminateForFailureEvidence() }
            try action(guardWait) { app.launchForFailureEvidence() }
            try playback(app, guardWait)
        }
    }

    @MainActor
    func testConnectionError() throws {
        try flow { app, guardWait, input in
            try fillForm(
                app, guardWait,
                input: StrictE2EInput(
                    serverURL: input.serverURL, publicKey: "immichslides-public-e2e-wrong-key"))
            try tap(app, guardWait, "firstboot.testConnection.button")
            var alert: XCUIElementSnapshot?
            try require(guardWait, "authorization error must be recoverable on first boot") {
                alert = try? app.alerts.firstMatch.snapshot()
                return alert != nil && !alert!.frame.isEmpty
            }
            // ui-label-lookup: SwiftUI alerts expose localized text without accessibility identifiers.
            func labels(_ node: XCUIElementSnapshot) -> [String] { [node.label] + node.children.flatMap(labels) }
            let text = alert.map { labels($0).joined(separator: " ") } ?? ""
            XCTAssertTrue(
                text.contains("API Key")
                    && (text.contains("无效") || text.contains("拒绝")
                        || text.localizedCaseInsensitiveContains("invalid")
                        || text.localizedCaseInsensitiveContains("rejected")),
                "Smoke flow: authorization failure must explain the rejected key.")
            try action(guardWait) { app.alerts.firstMatch.buttons.firstMatch.tapForFailureEvidence() }
            try ready(app, guardWait, "firstboot.serverURL.field")
            let save = try snapshot(app, guardWait, "firstboot.saveConfig.button")
            XCTAssertFalse(save.isEnabled, "Smoke flow: authorization failure must not enable Save.")
            try action(guardWait) { app.terminateForFailureEvidence() }
            try action(guardWait) { app.launchForFailureEvidence() }
            try ready(app, guardWait, "firstboot.serverURL.field")
        }
    }

    @MainActor
    func testAlbumSelection() throws {
        try flow { app, guardWait, input in
            try configure(app, guardWait, input: input)
            try chooseMode(app, guardWait, filtered: true)
            try tap(app, guardWait, "filterSummary.album.button")
            let directory = try XCTUnwrap(
                StrictE2EVisualEvidence.directory(), "Smoke flow: fixture metadata must be supplied.")
            let metadata =
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: directory.appendingPathComponent("member-manifest.json"))) as? [String: Any]
            let album = try XCTUnwrap(
                metadata?["target_album"] as? [String: Any], "Smoke flow: target album metadata must exist.")
            let albumID = try XCTUnwrap(album["id"] as? String, "Smoke flow: target album identifier must exist.")
            let identifier = "albumFilter.album.\(albumID).button"
            try tap(app, guardWait, identifier)
            try tap(app, guardWait, "albumFilter.back.button")
            try ready(app, guardWait, "filterSummary.startPlayback.button", enabled: true)
            try tap(app, guardWait, "filterSummary.startPlayback.button")
            try playback(app, guardWait)
        }
    }

    @MainActor
    func testPersonReturn() throws {
        try flow { app, guardWait, input in
            try configure(app, guardWait, input: input)
            try chooseMode(app, guardWait, filtered: true)
            try tap(app, guardWait, "filterSummary.person.button")
            let identifier = try firstIdentifier(app, guardWait, prefix: "personFilter.person.")
            // ui-label-lookup: The fixture name disambiguates descendants sharing the person card identifier.
            let name = app.staticTexts.matching(identifier: identifier)
                .matching(NSPredicate(format: "label ENDSWITH %@", " Synthetic")).firstMatch
            try action(guardWait) { name.tapForFailureEvidence() }
            try ready(app, guardWait, "personFilter.back.button")
            try ready(app, guardWait, identifier)
            try require(guardWait, "selected person must stay on its picker with a solo switch") {
                guard let selected = try? app.switches[identifier].snapshot() else { return false }
                return !selected.frame.isEmpty
            }
            try tap(app, guardWait, "personFilter.back.button")
            try ready(app, guardWait, "filterSummary.startPlayback.button", enabled: true)
            try require(guardWait, "Back must return from the person picker to the selected summary") {
                var didSnapshotFail = false
                let snapshots = app.evidenceSnapshotsByIdentifier(onSnapshotFailure: { _ in didSnapshotFail = true })
                return !didSnapshotFail
                    && snapshots["filterSummary.startPlayback.button"]?.isEnabled == true
                    && snapshots["filterSummary.startPlayback.button"]?.frame.isEmpty == false
                    && snapshots["personFilter.back.button"] == nil
            }
        }
    }

    @MainActor
    func testPlaybackControls() throws {
        try flow(observePlaybackLedger: true) { app, guardWait, input in
            try configure(app, guardWait, input: input)
            try chooseMode(app, guardWait, filtered: false)
            try playback(app, guardWait)
            try pause(app, guardWait)
            let before = try historyCursor(app, guardWait)
            try control(app, guardWait, "next")
            try require(guardWait, "Next must publish another scene while paused") {
                guard let value = self.observedHistoryCursor(app) else { return false }
                return value > before
            }
            try control(app, guardWait, "previous")
            try require(guardWait, "Previous must return to the prior scene") {
                self.observedHistoryCursor(app) == before
            }
            try control(app, guardWait, "playPause")
            try state(app, guardWait, "pause")
        }
    }

    @MainActor
    func testBackgroundReturn() throws {
        try flow { app, guardWait, input in
            try configure(app, guardWait, input: input)
            try chooseMode(app, guardWait, filtered: false)
            try playback(app, guardWait)
            try action(guardWait) { XCUIDevice.shared.press(.home) }
            try require(guardWait, "Home must background the app") {
                let phase = app.state
                return phase == .runningBackground || phase == .runningBackgroundSuspended
            }
            try action(guardWait) { app.activateForFailureEvidence() }
            try require(guardWait, "activation must return the app to foreground") { app.state == .runningForeground }
            try playback(app, guardWait)
            try pause(app, guardWait)
        }
    }

    @MainActor
    func testSettingsRelaunch() throws {
        try flow { app, guardWait, input in
            try configure(app, guardWait, input: input)
            try chooseMode(app, guardWait, filtered: false)
            try playback(app, guardWait)
            try openSettings(app, guardWait)
            try section(app, guardWait, "playback", destination: "settings.playback.showExif.toggle")
            let identifier = "settings.playback.showExif.toggle"
            let initial = try snapshot(app, guardWait, identifier).value as? String
            XCTAssertTrue(initial == "0" || initial == "1", "Smoke flow: EXIF setting must be readable.")
            try tap(app, guardWait, identifier)
            let expected = initial == "1" ? "0" : "1"
            try require(guardWait, "Settings must apply the changed EXIF value") {
                (app.evidenceSnapshotsByIdentifier()[identifier]?.value as? String) == expected
            }
            try action(guardWait) { app.terminateForFailureEvidence() }
            try action(guardWait) { app.launchForFailureEvidence() }
            try playback(app, guardWait)
            try openSettings(app, guardWait)
            try section(app, guardWait, "playback", destination: identifier)
            try require(guardWait, "Settings value must survive cold relaunch") {
                (app.evidenceSnapshotsByIdentifier()[identifier]?.value as? String) == expected
            }
        }
    }

    @MainActor
    func testRotation() throws {
        try flow { app, guardWait, input in
            defer { FirstFailureOrientation.set(.portrait) }
            try configure(app, guardWait, input: input)
            try chooseMode(app, guardWait, filtered: false)
            try playback(app, guardWait)
            try action(guardWait) { FirstFailureOrientation.set(.landscapeLeft) }
            try require(guardWait, "rotation must reach a landscape App window") {
                guard let window = try? app.windows.firstMatch.snapshot() else { return false }
                return window.frame.width > window.frame.height
            }
            try playback(app, guardWait)
            try pause(app, guardWait)
        }
    }

    @MainActor
    func testSettingsSidebar() throws {
        try flow { app, guardWait, input in
            try configure(app, guardWait, input: input)
            try chooseMode(app, guardWait, filtered: false)
            try playback(app, guardWait)
            try openSettings(app, guardWait)
            try section(app, guardWait, "about", destination: "settings.about.opensource.link")
            try tap(app, guardWait, "settings.about.opensource.link")
            try ready(app, guardWait, "settings.about.opensource.page")
            try tap(app, guardWait, "settings.about.opensource.back.button")
            try ready(app, guardWait, "settings.about.opensource.link")
            try tap(app, guardWait, "settings.about.opensource.link")
            try ready(app, guardWait, "settings.about.opensource.page")
            try tap(app, guardWait, "settings.item.server")
            try ready(app, guardWait, "firstboot.serverURL.field")
        }
    }

    @MainActor
    func testPinGate() throws {
        try flow(syntheticPIN: true) { app, guardWait, input in
            try configure(app, guardWait, input: input)
            try chooseMode(app, guardWait, filtered: false)
            try playback(app, guardWait)
            try openSettings(app, guardWait)
            try section(app, guardWait, "accessProtection", destination: "settings.pin.input.enable")
            try tap(app, guardWait, "settings.pin.input.enable")
            try digits(app, guardWait, "123456")
            try tap(app, guardWait, "settings.pin.input.enableConfirm")
            try digits(app, guardWait, "123456")
            try tap(app, guardWait, "settings.pin.enable.button")
            try ready(app, guardWait, "settings.pin.disable.button")
            try returnToPlayback(app, guardWait)
            try control(app, guardWait, "settings")
            try ready(app, guardWait, "pinEntry.close.button")
            try digits(app, guardWait, "000000")
            try ready(app, guardWait, "pinEntry.error.message")
            try ready(app, guardWait, "pinEntry.close.button")
            try digits(app, guardWait, "123456")
            try ready(app, guardWait, "settings.item.playback")
            try require(guardWait, "the correct synthetic PIN must unlock Settings") {
                var didSnapshotFail = false
                let snapshots = app.evidenceSnapshotsByIdentifier(onSnapshotFailure: { _ in didSnapshotFail = true })
                return !didSnapshotFail
                    && snapshots["settings.item.playback"]?.frame.isEmpty == false
                    && snapshots["pinEntry.close.button"] == nil
            }
        }
    }

    @MainActor
    private func flow(
        observePlaybackLedger: Bool = false, syntheticPIN: Bool = false,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: (XCUIApplication, TestWait.HangGuard, StrictE2EInput) throws -> Void
    ) throws {
        let guardWait = TestWait.hangGuard()
        let input = try requireStrictE2EInput()
        let app = XCUIApplication()
        if observePlaybackLedger { app.launchEnvironment["IMMICHSLIDES_PLAYBACK_CPU_DIAGNOSTICS"] = "1" }
        if syntheticPIN { app.launchEnvironment["UI_TEST_RESET_STATE"] = "1" }
        try action(guardWait, file: file, line: line) { app.launchForFailureEvidence() }
        // The reset hook is needed only for the initial launch and never for a cold relaunch.
        app.launchEnvironment = [:]
        defer { app.terminateForFailureEvidence() }
        try body(app, guardWait, input)
    }

    @MainActor
    private func action(
        _ guardWait: TestWait.HangGuard, file: StaticString = #filePath, line: UInt = #line,
        _ body: () -> Void
    ) throws {
        XCTAssertTrue(
            guardWait.transaction().perform("tap", body), "Smoke flow: action exceeded the shared hang guard.",
            file: file, line: line)
    }

    @MainActor
    private func require(
        _ guardWait: TestWait.HangGuard, _ message: String,
        file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) throws {
        XCTAssertTrue(guardWait.transaction().until(condition), "Smoke flow: \(message).", file: file, line: line)
    }

    @MainActor
    private func surface(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: XCUIElementSnapshot] {
        var captured: [String: XCUIElementSnapshot]?
        try require(guardWait, "App accessibility snapshot must succeed", file: file, line: line) {
            var didFail = false
            let snapshots = app.evidenceSnapshotsByIdentifier(onSnapshotFailure: { _ in didFail = true })
            guard !didFail else { return false }
            captured = snapshots
            return true
        }
        return try XCTUnwrap(captured, "Smoke flow: App accessibility snapshot is missing.", file: file, line: line)
    }

    @MainActor
    private func snapshot(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard, _ identifier: String, enabled: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) throws
        -> XCUIElementSnapshot
    {
        var observed: XCUIElementSnapshot?
        try require(guardWait, "required element must be available: \(identifier)", file: file, line: line) {
            observed = app.evidenceSnapshotsByIdentifier()[identifier]
            guard let observed else { return false }
            return !observed.frame.isEmpty && (!enabled || observed.isEnabled)
        }
        return try XCTUnwrap(observed, "Smoke flow: required element snapshot is missing.", file: file, line: line)
    }

    @MainActor
    private func ready(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard, _ identifier: String, enabled: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    )
        throws
    {
        try require(guardWait, "required element must be ready: \(identifier)", file: file, line: line) {
            guard let node = app.evidenceSnapshotsByIdentifier()[identifier] else { return false }
            return !node.frame.isEmpty && (!enabled || node.isEnabled)
        }
    }

    @MainActor
    private func tap(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard, _ identifier: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        if identifier.hasPrefix("slideshow.control.") {
            var captured: SlideshowControlBarButtonObservation?
            try require(guardWait, "required playback control must be ready", file: file, line: line) {
                captured = try? app.slideshowControlBarButtonObservation(identifier: identifier)
                return captured?.isReady == true
            }
            let target = try XCTUnwrap(
                captured, "Smoke flow: playback control observation is missing.", file: file, line: line)
            let button = try XCTUnwrap(
                target.button, "Smoke flow: playback control snapshot is missing.", file: file, line: line)
            try action(guardWait, file: file, line: line) {
                target.windowElement.coordinate(withNormalizedOffset: .zero).withOffset(
                    CGVector(
                        dx: button.frame.midX - target.windowFrame.minX,
                        dy: button.frame.midY - target.windowFrame.minY)
                ).tapForFailureEvidence()
            }
            return
        }
        let observed = try snapshot(app, guardWait, identifier, enabled: true, file: file, line: line)
        try action(guardWait, file: file, line: line) {
            // Native resolution follows keyboard/sidebar layout changes before the sole tap.
            app.descendants(matching: observed.elementType).matching(identifier: identifier)
                .firstMatch.tapForFailureEvidence()
        }
    }

    @MainActor
    private func fillForm(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard, input: StrictE2EInput,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for (identifier, value) in [
            ("firstboot.serverURL.field", input.serverURL), ("firstboot.apiKey.field", input.publicKey)
        ] {
            try ready(app, guardWait, identifier, file: file, line: line)
            let field =
                identifier == "firstboot.serverURL.field"
                ? app.textFields[identifier] : app.secureTextFields[identifier]
            var focused: XCUIElementSnapshot?
            try action(guardWait, file: file, line: line) {
                focused = IOSFirstBootNavigation(app: app).focusTextField(
                    field, identifier: identifier, file: file, line: line)
            }
            XCTAssertNotNil(focused, "Smoke flow: input must have keyboard focus.", file: file, line: line)
            try action(guardWait, file: file, line: line) {
                field.typeKey("a", modifierFlags: .command)
                field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
                field.typeForFailureEvidence(value)
            }
            if identifier == "firstboot.serverURL.field" {
                try require(guardWait, "the public URL must reach the real text field", file: file, line: line) {
                    (try? field.snapshot().value as? String) == input.serverURL
                }
            }
        }
        let keyboard = guardWait.transaction()
        if keyboard.probe({ app.evidenceSnapshotsByIdentifier()["server.keyboard.done.button"] != nil }) {
            try tap(app, guardWait, "server.keyboard.done.button", file: file, line: line)
        }
    }

    @MainActor
    private func configure(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard, input: StrictE2EInput,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try fillForm(app, guardWait, input: input, file: file, line: line)
        try tap(app, guardWait, "firstboot.testConnection.button", file: file, line: line)
        try ready(app, guardWait, "firstboot.saveConfig.button", enabled: true, file: file, line: line)
        try tap(app, guardWait, "firstboot.saveConfig.button", file: file, line: line)
        try ready(app, guardWait, "mode.random.button", file: file, line: line)
    }

    @MainActor
    private func chooseMode(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard, filtered: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let departure = IOSFirstBootNavigation(app: app).selectModeAndContinue(
            filtered ? "mode.filtered.button" : "mode.random.button",
            destinationIdentifier: filtered
                ? "filterSummary.startPlayback.button" : "slideshow.control.settings.button",
            file: file, line: line
        )
        XCTAssertNotNil(departure, "Smoke flow: selected mode must reach its destination.", file: file, line: line)
        if filtered { try ready(app, guardWait, "filterSummary.startPlayback.button", file: file, line: line) }
    }

    @MainActor
    private func firstIdentifier(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard, prefix: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws
        -> String
    {
        var identifier: String?
        try require(guardWait, "public fixture must provide a picker target", file: file, line: line) {
            identifier = app.evidenceSnapshotsByIdentifier().keys.sorted().first { $0.hasPrefix(prefix) }
            return identifier != nil
        }
        return try XCTUnwrap(identifier, "Smoke flow: picker target is missing.", file: file, line: line)
    }

    @MainActor
    private func playback(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let observation = try surface(app, guardWait, file: file, line: line)
        if observation["slideshow.entryHint.banner"] != nil {
            try tap(app, guardWait, "slideshow.entryHint.banner", file: file, line: line)
        }
        try wake(app, guardWait, file: file, line: line)
        try ready(app, guardWait, "slideshow.control.settings.button", enabled: true, file: file, line: line)
        try ready(app, guardWait, "slideshow.control.playPause.button", enabled: true, file: file, line: line)
    }

    @MainActor
    private func wake(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try action(guardWait, file: file, line: line) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tapForFailureEvidence()
        }
    }

    @MainActor
    private func control(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard, _ name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try wake(app, guardWait, file: file, line: line)
        try tap(app, guardWait, "slideshow.control.\(name).button", file: file, line: line)
    }

    @MainActor
    private func state(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard, _ expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try require(guardWait, "Play/Pause must reach \(expected)", file: file, line: line) {
            (app.evidenceSnapshotsByIdentifier()["slideshow.control.playPause.button"]?.value as? String) == expected
        }
    }

    @MainActor
    private func pause(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try wake(app, guardWait, file: file, line: line)
        let value =
            try snapshot(app, guardWait, "slideshow.control.playPause.button", file: file, line: line).value as? String
        if value == "pause" { try tap(app, guardWait, "slideshow.control.playPause.button", file: file, line: line) }
        try state(app, guardWait, "play", file: file, line: line)
    }

    @MainActor
    private func historyCursor(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Int {
        var cursor: Int?
        try require(guardWait, "playback must publish a scene before navigation", file: file, line: line) {
            cursor = self.observedHistoryCursor(app)
            return cursor != nil
        }
        return try XCTUnwrap(
            cursor, "Smoke flow: playback must expose its published history position.", file: file, line: line)
    }

    @MainActor
    private func observedHistoryCursor(_ app: XCUIApplication) -> Int? {
        guard let label = app.evidenceSnapshotsByIdentifier()["slideshow.historyLedger.summary.flag"]?.label,
            let bytes = label.data(using: .utf8),
            let summary = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { return nil }
        return summary["cursor"] as? Int
    }

    @MainActor
    private func openSettings(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try control(app, guardWait, "settings", file: file, line: line)
        try ready(app, guardWait, "settings.item.playback", file: file, line: line)
    }

    @MainActor
    private func section(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard, _ name: String, destination: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let observed = try surface(app, guardWait, file: file, line: line)
        if observed[destination] == nil { try tap(app, guardWait, "settings.item.\(name)", file: file, line: line) }
        try ready(app, guardWait, destination, file: file, line: line)
    }

    @MainActor
    private func navigationBack(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard, file: StaticString, line: UInt
    ) throws -> XCUIElement {
        var captured: XCUIElement?
        try require(guardWait, "Settings must offer Back", file: file, line: line) {
            guard
                let button = app.navigationBars.buttons.matching(identifier: "BackButton").allElementsBoundByIndex.last,
                let observed = try? button.snapshot(), !observed.frame.isEmpty, observed.isEnabled
            else { return false }
            captured = button
            return true
        }
        return try XCTUnwrap(captured, "Smoke flow: Settings Back is missing.", file: file, line: line)
    }

    @MainActor
    private func returnToPlayback(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let back = try navigationBack(app, guardWait, file: file, line: line)
        try action(guardWait, file: file, line: line) { back.tapForFailureEvidence() }
        var isSettingsRoot = false
        try require(guardWait, "Back must reach Settings root or playback", file: file, line: line) {
            var didFail = false
            let observed = app.evidenceSnapshotsByIdentifier(onSnapshotFailure: { _ in didFail = true })
            guard !didFail else { return false }
            isSettingsRoot = observed["settings.item.playback"]?.frame.isEmpty == false
            return isSettingsRoot || observed["slideshow.control.playPause.button"]?.frame.isEmpty == false
        }
        if isSettingsRoot {
            let rootBack = try navigationBack(app, guardWait, file: file, line: line)
            try action(guardWait, file: file, line: line) { rootBack.tapForFailureEvidence() }
        }
        try playback(app, guardWait, file: file, line: line)
    }

    @MainActor
    private func digits(
        _ app: XCUIApplication, _ guardWait: TestWait.HangGuard, _ pin: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for digit in pin { try tap(app, guardWait, "pinEntry.digit.\(digit).button", file: file, line: line) }
    }
}
#endif
