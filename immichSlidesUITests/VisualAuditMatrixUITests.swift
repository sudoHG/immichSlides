import XCTest

#if os(iOS)
final class VisualAuditMatrixUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // Return to portrait before each test so a previous landscape test cannot affect first-launch input.

        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testVisualAudit_FirstBoot_Matrix() throws {
        let schemes = ["light", "dark"]
        let orientations: [(name: String, value: UIDeviceOrientation)] = [
            ("portrait", .portrait),
            ("landscape", .landscapeLeft)
        ]

        for scheme in schemes {
            for orientation in orientations {
                let app = launchApp(resetState: true, colorScheme: scheme)
                XCUIDevice.shared.orientation = orientation.value

                XCTAssertTrue(app.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 8))
                attachScreenshot(app: app, name: "audit-matrix-firstboot-\(scheme)-\(orientation.name)-\(deviceTag())")
                app.terminate()
            }
        }

        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testVisualAudit_ModeSelection_MatrixWithInteraction() throws {
        let schemes = ["light", "dark"]
        let orientations: [(name: String, value: UIDeviceOrientation)] = [
            ("portrait", .portrait),
            ("landscape", .landscapeLeft)
        ]

        for scheme in schemes {
            XCUIDevice.shared.orientation = .portrait
            let app = try launchConfiguredAppAtModeSelection(resetState: true, colorScheme: scheme)

            for orientation in orientations {
                XCUIDevice.shared.orientation = orientation.value
                let randomButton = app.buttons["mode.random.button"]
                XCTAssertTrue(randomButton.waitForExistence(timeout: 8))
                tapElement(randomButton)
                attachScreenshot(
                    app: app, name: "audit-matrix-mode-random-selected-\(scheme)-\(orientation.name)-\(deviceTag())")
            }

            app.terminate()
        }

        XCUIDevice.shared.orientation = .portrait
    }
}

private extension VisualAuditMatrixUITests {
    func launchApp(resetState: Bool, colorScheme: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        if resetState {
            app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        }
        if let colorScheme {
            app.launchEnvironment["UI_TEST_COLOR_SCHEME"] = colorScheme
        }
        // Hide the one-tap fill button; inject only the expected connection-test input, without writing the server
        // config directly.
        app.launchEnvironment["UI_TEST_DISABLE_DEBUG_FILL_APIKEY_BUTTON"] = "1"

        if let config = TestServerConfiguration.current {
            app.launchEnvironment["UI_TEST_ASSUME_CONNECTION_TEST_SUCCESS"] = "1"
            app.launchEnvironment["UI_TEST_EXPECTED_CONNECTION_SERVER_URL"] = config.serverURL
            app.launchEnvironment["UI_TEST_EXPECTED_CONNECTION_API_KEY"] = config.apiKey
        }
        app.launch()
        return app
    }

    func launchConfiguredAppAtModeSelection(resetState: Bool, colorScheme: String? = nil) throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = XCUIApplication()
        if resetState {
            app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        }
        if let colorScheme {
            app.launchEnvironment["UI_TEST_COLOR_SCHEME"] = colorScheme
        }
        // Inject the test server directly so failures point at the mode page itself.

        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        app.launch()

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForExistence(timeout: 10),
            "After the visual matrix injects the test server, the app should go straight to the mode selection page"
        )
        return app
    }

    func completeFirstBootToModeSelection(app: XCUIApplication, serverURL: String, apiKey: String) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        guard serverField.waitForExistence(timeout: 8) else {
            throw XCTSkip("Not in the first-launch state; skipping the first-launch flow assertions.")
        }
        serverField.tap()
        serverField.clearAndType(text: serverURL)

        let apiField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiField.waitForExistence(timeout: 8))
        apiField.tap()
        apiField.clearAndType(text: apiKey)

        let testConnectionButton = app.buttons["firstboot.testConnection.button"]
        XCTAssertTrue(testConnectionButton.waitForExistence(timeout: 8))
        testConnectionButton.tap()

        let saveButton = app.buttons["firstboot.saveConfig.button"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 12))
        let saveEnabledExpectation = NSPredicate(format: "isEnabled == true")
        let saveEnabledWait = expectation(for: saveEnabledExpectation, evaluatedWith: saveButton)
        wait(for: [saveEnabledWait], timeout: 45)
        saveButton.tap()

        XCTAssertTrue(app.buttons["mode.continue.button"].waitForExistence(timeout: 10))
    }

    func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
            return
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func deviceTag() -> String {
        UIDevice.current.model.replacingOccurrences(of: " ", with: "_").lowercased()
    }
}

private extension XCUIElement {
    func clearAndType(text: String) {
        guard let existing = self.value as? String else {
            self.typeText(text)
            return
        }
        self.tap()
        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)
        self.typeText(deleteString)
        self.typeText(text)
    }
}
#endif
