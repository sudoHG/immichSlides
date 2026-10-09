import XCTest

#if os(iOS)
final class StrictE2ELateImageIOSUITests: XCTestCase {
    private let lateRequestSettleSeconds: TimeInterval = TestWait.seconds(.product(1.5))

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    // Seam: the public frame after the second next.
    // It must not flash back to the old image once the late preview/fullsize completes.
    @MainActor
    func testLateImageKeepsCurrentSceneAfterLateRequest() throws {
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "late-image")
        try enterPlaybackThenAdvanceTwice(app: app)

        let current = try captureRequiredIdentity(app: app, name: "ooo-current-scene")
        RunLoop.current.run(until: Date().addingTimeInterval(lateRequestSettleSeconds))
        let afterLate = try captureRequiredIdentity(app: app, name: "ooo-after-late")

        guard current.status == .match,
            afterLate.status == .match,
            let currentMark = current.mark,
            !currentMark.split(separator: "+").contains("A1"),
            currentMark == afterLate.mark
        else {
            XCTFail(
                "After late completion the current public mark must stay: no flash back, all black or unreadable: "
                    + "ooo-current-scene=\(current.status.rawValue)/\(current.mark ?? "nil") "
                    + "ooo-after-late=\(afterLate.status.rawValue)/\(afterLate.mark ?? "nil")"
            )
            return
        }

        let visualIdentity: [String: Any] = [
            "suite": "late-image",
            "device": currentDeviceTag(),
            "identity_source": "public_fixture_photo_mark",
            "mark": currentMark,
            "ooo-current-scene": StrictE2EPhotoIdentity.payload(current),
            "ooo-after-late": StrictE2EPhotoIdentity.payload(afterLate)
        ]
        XCTAssertTrue(JSONSerialization.isValidJSONObject(visualIdentity), "The identity JSON must be serializable.")
        try StrictE2EVisualEvidence.writeRequiredJSON(visualIdentity, name: "visual-identity.json")
    }

    @MainActor
    private func enterPlaybackThenAdvanceTwice(app: XCUIApplication) throws {
        let modeButton = firstBootControl(
            in: app,
            identifier: "mode.random.button"
        )
        let continueButton = firstBootControl(
            in: app,
            identifier: "mode.continue.button"
        )
        let next = app.buttons["slideshow.control.next.button"]
        let loading = app.descendants(matching: .any)["playback.loading.indicator"]
        // When random is already selected by default, do not tap the mode card or call waitForExistence again:
        // that would trigger the first A1 before entering playback.
        if !(continueButton.exists && continueButton.isEnabled) {
            XCTAssertTrue(
                modeButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
                "The mode page must provide mode.random.button.")
            modeButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(
                waitUntil(timeout: TestWait.seconds(.product(2))) { continueButton.exists && continueButton.isEnabled },
                "After selecting random, Continue must be enabled."
            )
        }
        // tap() waits for idle by default; the post-event idle wait lasts until the first 300ms delay ends.
        skipQuiescence(app: app) {
            tapElement(continueButton)
            let deadline = Date().addingTimeInterval(TestWait.seconds(.product(8)))
            var isReady = false
            while Date() < deadline {
                self.dismissPlaybackEntryHintIfPresent(app: app)
                if next.exists && !loading.exists {
                    isReady = true
                    break
                }
                RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.02))))
            }
            XCTAssertTrue(
                isReady,
                "Next must be tappable twice right after entering the slideshow, before old image requests finish."
            )
            self.dismissPlaybackEntryHintIfPresent(app: app)
            tapElement(next)
            tapElement(next)
        }
    }

    @MainActor
    private func skipQuiescence(app: XCUIApplication, _ body: () -> Void) {
        // XCTest has no public API to skip idle waits.
        // The private interaction options are used only for this test's 300ms window.
        let skipPreAndPost: UInt = 1 << 0 | 1 << 1
        let optionsSel = NSSelectorFromString("_performWithInteractionOptions:block:")
        if app.responds(to: optionsSel), let method = app.method(for: optionsSel) {
            typealias Perform = @convention(c) (AnyObject, Selector, UInt, @convention(block) () -> Void) -> Void
            unsafeBitCast(method, to: Perform.self)(app, optionsSel, skipPreAndPost, body)
            return
        }
        setProcessSkipQuiescence(app: app, skip: true)
        defer { setProcessSkipQuiescence(app: app, skip: false) }
        body()
    }

    @MainActor
    private func setProcessSkipQuiescence(app: XCUIApplication, skip: Bool) {
        let implSel = NSSelectorFromString("applicationImpl")
        guard app.responds(to: implSel),
            let impl = app.perform(implSel)?.takeUnretainedValue() as? NSObject
        else {
            return
        }
        let processSel = NSSelectorFromString("currentProcess")
        guard impl.responds(to: processSel),
            let process = impl.perform(processSel)?.takeUnretainedValue() as? NSObject
        else {
            return
        }
        if process.responds(to: NSSelectorFromString("setShouldSkipPreEventQuiescence:")) {
            process.setValue(skip, forKey: "shouldSkipPreEventQuiescence")
        }
        if process.responds(to: NSSelectorFromString("setShouldSkipPostEventQuiescence:")) {
            process.setValue(skip, forKey: "shouldSkipPostEventQuiescence")
        }
    }

    @MainActor
    private func captureRequiredIdentity(app: XCUIApplication, name: String) throws -> StrictE2EPhotoIdentity.Result {
        let png = app.screenshot().pngRepresentation
        XCTAssertFalse(png.isEmpty, "The playback screenshot must not be empty: \(name)")
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
        return StrictE2EPhotoIdentity.captureIdentity(png: png)
    }

    @MainActor
    private func completeFirstBootToModeSelection(
        app: XCUIApplication,
        input: StrictE2EInput,
        evidencePrefix: String
    ) throws {
        try fillFirstBootForm(app: app, input: input)
        tapTestConnection(app: app)
        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "The first-launch page must show the Save Settings button.")
        XCTAssertTrue(
            waitForSaveEnabled(app: app, saveButton: saveButton, timeout: TestWait.seconds(.infrastructure(45))),
            "After a real connection test succeeds, Save must become enabled."
        )
        attachStrictE2EScreenshot(app: app, name: "\(evidencePrefix)-connection-passed-\(currentDeviceTag())")
        tapElement(saveButton)
        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(timeout: TestWait.seconds(.infrastructure(15))),
            "After a successful save, mode selection must open."
        )
        attachStrictE2EScreenshot(app: app, name: "\(evidencePrefix)-mode-selection-\(currentDeviceTag())")
    }

    @MainActor
    private func fillFirstBootForm(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForExistence(timeout: TestWait.seconds(.infrastructure(20))),
            "A fresh install must open the normal first-launch page.")
        replaceText(in: serverField, with: input.serverURL)
        XCTAssertEqual(
            serverField.value as? String, input.serverURL,
            "The public test URL must be written into the field unchanged.")
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "The first-launch page must show the API Key field.")
        replaceText(in: apiKeyField, with: input.publicKey)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(3))) { self.secureFieldHasEnteredValue(apiKeyField) },
            "The API Key must actually be entered into the secure field."
        )
        commitFocusedInputIfNeeded(app: app)
    }

    @MainActor
    private func dismissPlaybackEntryHintIfPresent(app: XCUIApplication) {
        let banner = app.descendants(matching: .any)["slideshow.entryHint.banner"]
        guard banner.exists else { return }
        tapElement(banner)
    }

    @MainActor
    private func tapTestConnection(app: XCUIApplication) {
        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(
            testConnectionButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "Test Connection must be shown")
        tapElement(testConnectionButton)
    }

    private func waitForSaveEnabled(app: XCUIApplication, saveButton: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            acceptLocalNetworkPermissionIfNeeded()
            if saveButton.exists && saveButton.isEnabled { return true }
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let alert = app.alerts.firstMatch
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
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

    private func acceptLocalNetworkPermissionIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // ui-label-lookup: Dismiss the simulator-owned local network permission prompt.
        for label in ["允许", "Allow"] {
            // ui-label-lookup: The permission action belongs to SpringBoard.
            let button = springboard.alerts.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
    }

    private func firstBootControl(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        let identifiedElement = app.descendants(matching: .any)[identifier]
        return identifiedElement
    }

    private func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func replaceText(in field: XCUIElement, with value: String) {
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

    private func secureFieldHasEnteredValue(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return !value.isEmpty && !value.contains("请输入") && !value.localizedCaseInsensitiveContains("api key")
    }

    private func commitFocusedInputIfNeeded(app: XCUIApplication) {
        // ui-label-lookup: Match the simulator-localized system keyboard action.
        for label in ["完成", "Done", "next", "Next"] {
            // ui-label-lookup: System keyboard keys follow the simulator language.
            let keyboardButton = app.keyboards.buttons[label]
            if keyboardButton.exists && keyboardButton.isHittable {
                keyboardButton.tap()
                return
            }
            let accessory = app.buttons["server.keyboard.done.button"]
            if accessory.exists && accessory.isHittable {
                accessory.tap()
                return
            }
        }
    }

    private func currentDeviceTag() -> String {
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let orientation = XCUIDevice.shared.orientation.isLandscape ? "landscape" : "portrait"
        return "\(idiom)-\(orientation)"
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.1))))
        }
        return condition()
    }
}
#endif
