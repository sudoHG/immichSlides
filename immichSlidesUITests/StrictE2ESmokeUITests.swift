import XCTest

final class StrictE2ESmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    #if os(iOS)
    @MainActor
    func testIOSStrictE2EConnectionSmoke() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("Runs on iPhone only.")
        }
        try runConnectionSmoke()
    }
    #endif

    #if os(tvOS)
    @MainActor
    func testTVOSStrictE2EConnectionSmoke() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The strict tvOS smoke test must run on a tvOS Simulator.")
            return
        }
        try runConnectionSmoke()
    }
    #endif

    @MainActor
    private func runConnectionSmoke() throws {
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer {
            let scene = XCTAttachment(screenshot: app.screenshot())
            scene.name = "strict-e2e-before-termination"
            scene.lifetime = .keepAlways
            add(scene)
            app.terminate()
        }

        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForExistence(timeout: TestWait.seconds(.infrastructure(12))),
            "Fresh install must open the normal first-launch page")
        #if os(iOS)
        replaceText(in: serverField, with: input.serverURL)
        #else
        replaceFocusedTVOSText(in: serverField, app: app, with: input.serverURL)
        #endif

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "First-launch page must show the API Key field.")
        #if os(iOS)
        replaceText(in: apiKeyField, with: input.publicKey)
        #else
        moveTVOSFocusDown(to: apiKeyField, message: "After closing the URL keyboard, focus should go down to API Key.")
        replaceFocusedTVOSText(in: apiKeyField, app: app, with: input.publicKey)
        #endif

        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(
            testConnectionButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "First-launch page must show Test Connection.")
        #if os(iOS)
        testConnectionButton.tap()
        #else
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.right)
        attachTVOSFocusAudit(app: app)
        XCUIRemote.shared.press(.select)
        #endif

        #if os(iOS)
        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "First-launch page must show the Save Settings button.")
        let enabled = expectation(
            for: NSPredicate(format: "isEnabled == true"),
            evaluatedWith: saveButton
        )
        wait(for: [enabled], timeout: TestWait.seconds(.infrastructure(45)))
        #else
        waitForTVOSConnectionSuccess(in: app, timeout: TestWait.seconds(.infrastructure(45)))
        #endif

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "strict-e2e-connection-reachable"
        screenshot.lifetime = XCTAttachment.Lifetime.keepAlways
        add(screenshot)
    }

    #if os(iOS)
    private func replaceText(in field: XCUIElement, with value: String) {
        field.tap()
        if let existingValue = field.value as? String, !existingValue.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingValue.count))
        }
        field.typeText(value)
    }
    #else
    private func replaceFocusedTVOSText(in field: XCUIElement, app: XCUIApplication, with value: String) {
        XCTAssertTrue(
            waitForTVOSFocus(on: field, timeout: TestWait.seconds(.product(3))),
            "The field must be focused before typing.")
        XCUIRemote.shared.press(.select)
        app.typeText(value)
        if field.identifier == "firstboot.serverURL.field" {
            let typed = XCTAttachment(screenshot: app.screenshot())
            typed.name = "strict-e2e-url-before-submit"
            typed.lifetime = .keepAlways
            add(typed)
        }
        let submit = app.buttons.matching(
            // ui-label-lookup: Match the simulator-localized tvOS system keyboard submit key.
            NSPredicate(format: "label IN %@", ["下一项", "Next", "完成", "Done"])
        ).firstMatch
        XCTAssertTrue(
            submit.waitForExistence(timeout: TestWait.seconds(.product(3))),
            "The system keyboard must have a visible submit button.")
        for _ in 0..<6 {
            if submit.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(submit.hasFocus, "The system keyboard submit button must be focused before submitting.")
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.menu)
        if field.identifier == "firstboot.serverURL.field" {
            XCTAssertEqual(
                field.value as? String, value,
                "The public test URL must be submitted unchanged, without keyboard control characters.")
        }
        XCTAssertTrue(
            waitForTVOSFocus(on: field, timeout: TestWait.seconds(.product(3))),
            "After submitting, focus must return to the same field.")
    }

    private func moveTVOSFocusDown(to element: XCUIElement, message: String) {
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForTVOSFocus(on: element, timeout: TestWait.seconds(.product(3))), message)
    }

    private func waitForTVOSFocus(on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.hasFocus { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.1))))
        }
        return element.exists && element.hasFocus
    }

    private func attachTVOSFocusAudit(app: XCUIApplication) {
        let focused = app.descendants(matching: .any).allElementsBoundByIndex.filter(\.hasFocus)
        let lines = focused.map { element in
            "type=\(element.elementType.rawValue) id=\(element.identifier) label=\(element.label)"
        }
        print("STRICT_E2E_TVOS_FOCUS " + (lines.isEmpty ? "none" : lines.joined(separator: " | ")))
        let attachment = XCTAttachment(string: lines.isEmpty ? "no-focused-element" : lines.joined(separator: "\n"))
        attachment.name = "strict-e2e-tvos-focus-before-select"
        attachment.lifetime = XCTAttachment.Lifetime.keepAlways
        add(attachment)
    }

    private func waitForTVOSConnectionSuccess(in app: XCUIApplication, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.staticTexts["firstboot.connection.success"].exists { return }
            if app.descendants(matching: .any)["server.apiKey.help.sheet"].exists {
                XCTFail("Select hit the API Key help sheet instead of Test Connection.")
                return
            }
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let alert = app.alerts.firstMatch
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            if alert.exists {
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                let details = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
                XCTFail("Test Connection showed a failure alert: \(alert.label) | \(details)")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.1))))
        }
        XCTFail("Once the real server is reachable, the connection test success message must be shown.")
    }
    #endif

    private func firstBootControl(
        in app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        let identifiedElement = app.descendants(matching: .any)[identifier]
        return identifiedElement
    }
}
