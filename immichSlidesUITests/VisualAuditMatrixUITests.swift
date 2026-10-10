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
                let app = launchApp(shouldResetState: true, colorScheme: scheme)
                XCUIDevice.shared.orientation = orientation.value

                XCTAssertTrue(
                    app.textFields["firstboot.serverURL.field"].waitForExistence(
                        timeout: TestWait.seconds(.infrastructure(8))))
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
            let app = try launchConfiguredAppAtModeSelection(shouldResetState: true, colorScheme: scheme)

            for orientation in orientations {
                XCUIDevice.shared.orientation = orientation.value
                let randomButton = app.buttons["mode.random.button"]
                XCTAssertTrue(randomButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))))
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
    func launchApp(shouldResetState: Bool, colorScheme: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        if shouldResetState {
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

    func launchConfiguredAppAtModeSelection(shouldResetState: Bool, colorScheme: String? = nil) throws
        -> XCUIApplication
    {
        let config = try requireTestServerConfig()
        let app = XCUIApplication()
        if shouldResetState {
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
            app.buttons["mode.continue.button"].waitForExistence(timeout: TestWait.seconds(.infrastructure(10))),
            "After the visual matrix injects the test server, the app should go straight to the mode selection page"
        )
        return app
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
#endif
