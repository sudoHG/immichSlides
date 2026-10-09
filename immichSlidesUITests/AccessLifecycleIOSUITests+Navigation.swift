import CryptoKit
import XCTest

#if os(iOS)
extension AccessLifecycleIOSUITests {
    @MainActor
    func launchApp() throws -> XCUIApplication {
        let app = XCUIApplication()
        try prepareLaunch(app)
        app.launch()
        return app
    }

    @MainActor
    func relaunchApp(_ app: XCUIApplication) throws {
        app.terminate()
        try prepareLaunch(app)
        app.launch()
    }

    @MainActor
    func prepareLaunch(_ app: XCUIApplication) throws {
        app.launchEnvironment = [
            AccessLifecycleContract.scenePresentationProbeKey: "1"
        ]
        try AccessLifecycleContract.assertNoForcedDisplayMode(app.launchEnvironment)
    }

    @MainActor
    func readSceneProgress(app: XCUIApplication) throws -> (value: Double, raw: String, source: String) {
        revealPlaybackControls(app: app)
        let contractProbe = app.descendants(matching: .any)["slideshow.scenePresentation.contract.summary"]
        if contractProbe.waitForExistence(timeout: TestWait.seconds(.product(4))),
            let parsed = progressValue(in: contractProbe.label)
        {
            return (parsed.value, parsed.raw, "slideshow.scenePresentation.contract.summary")
        }
        let motionSummary = app.descendants(matching: .any)["slideshow.smartfill.motionFrame.summary"]
        if motionSummary.waitForExistence(timeout: TestWait.seconds(.product(2))),
            let parsed = progressValue(in: motionSummary.label)
        {
            return (parsed.value, parsed.raw, "slideshow.smartfill.motionFrame.summary")
        }
        let firstFrame = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "slideshow.smartfill.motionFrame."))
            .firstMatch
        if firstFrame.exists, let parsed = progressValue(in: firstFrame.label) {
            return (parsed.value, parsed.raw, firstFrame.identifier)
        }
        throw AccessLifecycleContract.AssertionError.message("Progress must be measured")
    }

    func progressValue(in raw: String) -> (value: Double, raw: String)? {
        if let fromMotion = parseProgressField(raw) {
            return (fromMotion, raw)
        }
        if let fromContract = parseMotionRawProgress(raw) {
            return (fromContract, raw)
        }
        let rows = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for row in rows where !row.contains("renderRole=outgoing") {
            if let value = parseProgressField(row) ?? parseMotionRawProgress(row) {
                return (value, row)
            }
        }
        return nil
    }

    func parseMotionRawProgress(_ raw: String) -> Double? {
        guard let range = raw.range(of: "motionRawProgress=") else { return nil }
        let token = String(raw[range.upperBound...]).split(separator: ";").first.map(String.init) ?? ""
        let parts = token.split(separator: "|").compactMap { Double($0) }
        return parts.last
    }

    func parseProgressField(_ raw: String) -> Double? {
        guard let range = raw.range(of: "progress=") else { return nil }
        let token = String(raw[range.upperBound...]).split(separator: ";").first.map(String.init) ?? ""
        if token.isEmpty || token == "missing" { return nil }
        return Double(token)
    }

    @MainActor
    func captureRequiredMark(app: XCUIApplication, name: String) throws -> (mark: String, png: Data) {
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        var png = Data()
        var identity = StrictE2EPhotoIdentity.classify(png: Data())
        var mark = ""
        let deadline = Date().addingTimeInterval(TestWait.seconds(.product(4)))
        while Date() < deadline {
            png = try captureRequiredPNG(app: app, name: name)
            identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
            mark = contractMark(identity)
            if identity.status == .match, !mark.isEmpty {
                return (mark, png)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.4))))
        }
        if mark == "BLACK" || mark == "BLANK" || mark == "UNRECOGNIZABLE" || mark.isEmpty {
            XCTFail(
                "Screenshot \(name) cannot be used as identity: \(identity.status.rawValue)/\(identity.mark ?? "nil")")
        }
        return (mark, png)
    }

    @MainActor
    func captureNewStableMark(
        app: XCUIApplication,
        name: String,
        timeout: TimeInterval
    ) throws -> (mark: String, png: Data) {
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        let initialPNG = app.screenshot().pngRepresentation
        let initialMark = contractMark(StrictE2EPhotoIdentity.captureIdentity(png: initialPNG))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                break
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(AccessLifecycleContract.pollWait(remaining: remaining))
            )
            let png = app.screenshot().pngRepresentation
            let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
            let mark = contractMark(identity)
            if identity.status == .match, !mark.isEmpty, mark != initialMark {
                let remainingForConfirm = deadline.timeIntervalSinceNow
                if remainingForConfirm <= 0 {
                    break
                }
                RunLoop.current.run(
                    until: Date().addingTimeInterval(
                        AccessLifecycleContract.confirmWait(remaining: remainingForConfirm)
                    )
                )
                let stablePNG = app.screenshot().pngRepresentation
                let stableIdentity = StrictE2EPhotoIdentity.captureIdentity(png: stablePNG)
                let stableMark = contractMark(stableIdentity)
                if AccessLifecycleContract.isConfirmedNewStableMark(
                    status: stableIdentity.status.rawValue,
                    mark: stableMark,
                    candidateMark: mark,
                    initialMark: initialMark,
                    meanLuma: stableIdentity.meanLuma
                ) {
                    try persistRequiredPNG(stablePNG, name: name)
                    return (stableMark, stablePNG)
                }
            }
        }
        throw AccessLifecycleContract.AssertionError.message(
            "No new stable frame appeared before going to the background")
    }

    @MainActor
    func captureRequiredPNG(app: XCUIApplication, name: String) throws -> Data {
        let png = app.screenshot().pngRepresentation
        try persistRequiredPNG(png, name: name)
        return png
    }

    @MainActor
    func persistRequiredPNG(_ png: Data, name: String) throws {
        XCTAssertFalse(png.isEmpty, "Screenshot must not be empty: \(name)")
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
    }

    func contractMark(_ identity: StrictE2EPhotoIdentity.Result) -> String {
        if identity.status == .match, let mark = identity.mark {
            return mark
        }
        if identity.status == .black { return "BLACK" }
        if identity.status == .blank { return "BLANK" }
        return "UNRECOGNIZABLE"
    }

    func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func syntheticPIN() -> String {
        [2, 4, 6, 8, 0, 1].map(String.init).joined()
    }

    func wrongPIN() -> String {
        [1, 3, 5, 7, 9, 0].map(String.init).joined()
    }

    func deviceKind() -> String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    @MainActor
    func enterPin(app: XCUIApplication, pin: String) {
        for digit in pin {
            let key = app.buttons["pinEntry.digit.\(digit).button"]
            XCTAssertTrue(key.waitForExistence(timeout: TestWait.seconds(.product(3))), "PIN digit key does not exist.")
            tapElement(key)
        }
    }

    @MainActor
    func tapSettingsPinInput(app: XCUIApplication, id: String) {
        let pinInputButton = app.buttons[id]
        let ready = waitUntil(timeout: TestWait.seconds(.infrastructure(8))) {
            self.dismissSystemSavePromptIfPresent(app: app, timeout: TestWait.seconds(.product(0)))
            return pinInputButton.exists && pinInputButton.isHittable
                && !self.isSystemSavePasswordPromptVisible(app: app)
        }
        XCTAssertTrue(ready, "PIN input entry not found.")
        tapElement(pinInputButton)
    }

    @MainActor
    func openSettingsFromSlideshow(app: XCUIApplication) {
        revealPlaybackControls(app: app)
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(15))),
            "The playback page must provide a settings entry.")
        tapElement(settingsButton)
    }

    @MainActor
    func returnToSlideshowFromSettings(app: XCUIApplication) {
        for _ in 0..<12 {
            if app.buttons["slideshow.control.settings.button"].exists,
                app.buttons["slideshow.control.settings.button"].isHittable
            {
                return
            }
            if !isOnSettingsSurface(app: app) {
                revealPlaybackControls(app: app)
                if app.buttons["slideshow.control.settings.button"].waitForExistence(
                    timeout: TestWait.seconds(.infrastructure(2)))
                {
                    return
                }
            }
            if app.buttons["pinEntry.close.button"].exists {
                tapElement(app.buttons["pinEntry.close.button"])
                RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.2))))
                continue
            }
            let globalBack = app.buttons["global.back.button"]
            if globalBack.exists && globalBack.isHittable {
                tapElement(globalBack)
                RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.3))))
                continue
            }
            let backButton =
                app.navigationBars.buttons.allElementsBoundByIndex.last { button in
                    button.exists && button.isHittable && button.identifier == "BackButton"
                }
                ?? app.navigationBars.buttons.allElementsBoundByIndex.last { button in
                    button.exists && button.isHittable && button.identifier != "ToggleSidebar"
                        // ui-label-lookup: System navigation supplies the sidebar button label.
                        && !["显示边栏", "隐藏边栏", "Show Sidebar", "Hide Sidebar"].contains(button.label)
                }
            if let backButton {
                tapElement(backButton)
                RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.3))))
                continue
            }
            app.swipeDown()
        }
        if app.buttons["slideshow.control.next.button"].exists {
            revealPlaybackControls(app: app)
        }
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: TestWait.seconds(.infrastructure(8))),
            "Must be able to return from settings to the playback page."
        )
    }

    @MainActor
    func openPlaybackSettings(app: XCUIApplication) {
        let toggle = playbackSwitch(app: app, identifier: "settings.playback.autoPlay.toggle")
        if toggle.waitForExistence(timeout: TestWait.seconds(.infrastructure(2))) {
            return
        }
        let sidebar = app.buttons["ToggleSidebar"]
        // ui-label-lookup: System navigation supplies the sidebar button label.
        if sidebar.exists && ["显示边栏", "Show Sidebar"].contains(sidebar.label) {
            tapElement(sidebar)
        }
        _ = app.descendants(matching: .any)["settings.item.playback"].waitForExistence(
            timeout: TestWait.seconds(.infrastructure(3)))
        let playbackButton = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "The settings list must provide the playback settings entry")
        // A full-screen Toolbar swallows coordinate taps; use the element's tap() to activate via accessibility.
        playbackButton.tap()
        if !waitUntil(
            timeout: TestWait.seconds(.infrastructure(2)),
            condition: { toggle.exists || app.staticTexts["settings.playback.title"].exists })
        {
            app.cells.element(boundBy: 0).tap()
        }
        let opened = waitUntil(timeout: TestWait.seconds(.infrastructure(10))) {
            toggle.exists || app.staticTexts["settings.playback.title"].exists
        }
        if !opened {
            let png = app.screenshot().pngRepresentation
            try? StrictE2EVisualEvidence.writeRequiredPNG(png, name: "settings-open-debug")
            if let directory = StrictE2EVisualEvidence.directory() {
                try? app.debugDescription.write(
                    to: directory.appendingPathComponent("settings-open-debug.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
        XCTAssertTrue(
            opened,
            "After opening playback settings, the autoplay toggle or the playback settings title must be visible.")
    }

    @MainActor
    func settingsControl(app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    // In the iPad split view, List(selection)+Label is not always a Button; same query set as FilterSummary.
    @MainActor
    func settingsItemCandidates(
        app: XCUIApplication,
        identifier: String
    ) -> [XCUIElement] {
        [
            app.buttons[identifier],
            app.staticTexts[identifier],
            app.otherElements[identifier],
            settingsControl(app: app, identifier: identifier)
        ]
    }

    @MainActor
    func firstExistingSettingsItem(
        app: XCUIApplication,
        identifier: String
    ) -> XCUIElement? {
        settingsItemCandidates(app: app, identifier: identifier)
            .first(where: \.exists)
    }

    @MainActor
    func isOnSettingsSurface(app: XCUIApplication) -> Bool {
        let identifiers = [
            "settings.item.playback", "settings.playback.title", "settings.accessProtection.title",
            "settings.server.title", "settings.cache.title", "settings.about.title",
            "settings.about.opensource.page"
        ]
        if identifiers.contains(where: { settingsControl(app: app, identifier: $0).exists }) {
            return true
        }
        return app.buttons["settings.item.playback"].exists
            || app.buttons["settings.pin.enable.button"].exists
            || app.buttons["settings.pin.disable.button"].exists
            || settingsControl(app: app, identifier: "settings.playback.autoPlay.toggle").exists
    }

    @MainActor
    func openSettingsSection(app: XCUIApplication, sectionID: String) {
        let sidebar = app.buttons["ToggleSidebar"]
        // ui-label-lookup: System navigation supplies the sidebar button label.
        if sidebar.exists && (sidebar.label == "显示边栏" || sidebar.label == "Show Sidebar") {
            sidebar.tap()
        }
        // While the Save Password prompt covers the screen the hit point is {-1,-1}; tap "Not Now" first,
        // then Access Protection.
        for attempt in 0..<20 {
            dismissSystemSavePromptIfPresent(app: app, timeout: TestWait.seconds(.product(0)))
            if let candidate = firstExistingSettingsItem(
                app: app,
                identifier: sectionID
            ), !isSystemSavePasswordPromptVisible(app: app) {
                tapElement(candidate)
                return
            }
            if isSystemSavePasswordPromptVisible(app: app)
                || settingsControl(app: app, identifier: sectionID).exists
            {
                RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.3))))
                continue
            }
            if attempt % 2 == 0 {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
        }
        XCTFail("Settings item not found: \(sectionID)")
    }

    // Judge by play/pause being really hittable; a leftover settings button that still exists is not the control bar.
    @MainActor
    func revealPlaybackControls(app: XCUIApplication) {
        let playPause = playPauseButton(app)
        let settingsExists = app.buttons["slideshow.control.settings.button"].exists
        if AccessLifecycleContract.isPlaybackControlBarRevealed(
            isPlayPauseHittable: playPause.exists && playPause.isHittable
        ) {
            return
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPlaybackControlsRevealedByTarget(
                isPlayPauseHittable: playPause.exists && playPause.isHittable,
                isSettingsPresent: settingsExists,
                isTreatedAsRevealed: false
            )
        )
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        _ = waitUntil(timeout: TestWait.seconds(.product(3))) {
            let button = self.playPauseButton(app)
            return button.exists && button.isHittable
        }
    }

    // Arriving at playback checks only exists; do not tap the screen or the hint, so XCTest does not wait
    // about 60 s for Ken Burns to go idle.
    @MainActor
    func waitForPlaybackControls(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            self.dismissSystemSavePromptIfPresent(app: app, timeout: TestWait.seconds(.product(0)))
            return AccessLifecycleContract.hasPlaybackPageArrived(
                isSettingsPresent: app.buttons["slideshow.control.settings.button"].exists,
                isNextPresent: app.buttons["slideshow.control.next.button"].exists,
                isPlayPausePresent: self.playPauseButton(app).exists,
                isHintPresent: app.descendants(matching: .any)["slideshow.entryHint.banner"].exists
            )
        }
    }

    @MainActor
    func fillFirstBootForm(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForExistence(timeout: TestWait.seconds(.infrastructure(20))),
            "A fresh install must reach the normal first-boot page.")
        replaceText(in: serverField, with: input.serverURL)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "The first-boot page must show the API Key field.")
        replaceText(in: apiKeyField, with: input.publicKey)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(3))) { self.hasSecureFieldEnteredValue(apiKeyField) },
            "The API Key must be entered into the secure field.")
        commitFocusedInputIfNeeded(app: app)
    }

    @MainActor
    func tapTestConnection(app: XCUIApplication) {
        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(
            testConnectionButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "Test Connection must be shown")
        tapElement(testConnectionButton)
    }

    @MainActor
    func waitForSaveEnabled(app: XCUIApplication, saveButton: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            acceptLocalNetworkPermissionIfNeeded()
            if saveButton.exists && saveButton.isEnabled { return true }
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let alert = app.alerts.firstMatch
            if alert.exists {
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                let details = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
                XCTFail("Connection test showed a failure alert: \(alert.label) | \(details)")
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.2))))
        }
        return saveButton.exists && saveButton.isEnabled
    }

    func acceptLocalNetworkPermissionIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // ui-label-lookup: The local-network permission alert belongs to iOS.
        for label in ["允许", "Allow"] {
            // ui-label-lookup: The permission action belongs to SpringBoard.
            let button = springboard.alerts.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
    }

    @MainActor
    func firstBootControl(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        return app.descendants(matching: .any)[identifier]
    }

    @MainActor
    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    @MainActor
    func replaceText(in field: XCUIElement, with value: String) {
        field.tap()
        let existingValue = field.value as? String ?? ""
        let looksLikePlaceholder =
            existingValue.contains("请输入") || existingValue.localizedCaseInsensitiveContains("enter")
        if !existingValue.isEmpty && !looksLikePlaceholder {
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        }
        field.typeText(value)
    }

    @MainActor
    func hasSecureFieldEnteredValue(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return !value.isEmpty && !value.contains("请输入") && !value.localizedCaseInsensitiveContains("api key")
    }

    @MainActor
    func commitFocusedInputIfNeeded(app: XCUIApplication) {
        let done = app.buttons["server.keyboard.done.button"]
        if done.exists && done.isHittable {
            done.tap()
            return
        }
        // ui-label-lookup: System keyboard submit keys follow the simulator language.
        for label in ["完成", "Done", "next", "Next"] {
            // ui-label-lookup: System keyboard submit keys follow the simulator language.
            let button = app.keyboards.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
                return
            }
        }
    }

    @MainActor
    func findFirstExistingIdentifiedText(in app: XCUIApplication, identifiers: [String], timeout: TimeInterval)
        -> XCUIElement?
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for identifier in identifiers {
                let text = app.staticTexts[identifier]
                if text.exists { return text }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.1))))
        }
        return nil
    }

    @MainActor
    func isToggleOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }
}
#endif
