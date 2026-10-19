import XCTest

#if os(iOS)
final class VisualAuditMatrixUITests: XCTestCase {
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
        // Return to portrait before each test so a previous landscape test cannot affect first-launch input.

        FirstFailureOrientation.set(.portrait)
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
                FirstFailureOrientation.set(orientation.value)

                XCTAssertTrue(
                    app.textFields["firstboot.serverURL.field"].waitForPublicElement(
                        "firstboot.serverURL.field",
                        timeout: TestWait.seconds(.infrastructure(8))))
                attachScreenshot(app: app, name: "audit-matrix-firstboot-\(scheme)-\(orientation.name)-\(deviceTag())")
                app.terminateForFailureEvidence()
            }
        }

        FirstFailureOrientation.set(.portrait)
    }

    @MainActor
    func testVisualAudit_ModeSelection_MatrixWithInteraction() throws {
        let schemes = ["light", "dark"]
        let orientations: [(name: String, value: UIDeviceOrientation)] = [
            ("portrait", .portrait),
            ("landscape", .landscapeLeft)
        ]

        for scheme in schemes {
            FirstFailureOrientation.set(.portrait)
            let app = try launchConfiguredAppAtModeSelection(shouldResetState: true, colorScheme: scheme)

            for orientation in orientations {
                FirstFailureOrientation.set(orientation.value)
                let randomButton = app.buttons["mode.random.button"]
                XCTAssertTrue(
                    randomButton.waitForPublicElement(
                        "mode.random.button", timeout: TestWait.seconds(.infrastructure(8))))
                IOSFirstBootNavigation(app: app).selectMode(
                    "mode.random.button", timeout: TestWait.seconds(.infrastructure(8)))
                attachScreenshot(
                    app: app, name: "audit-matrix-mode-random-selected-\(scheme)-\(orientation.name)-\(deviceTag())")
            }

            app.terminateForFailureEvidence()
        }

        FirstFailureOrientation.set(.portrait)
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
        app.launchForFailureEvidence()
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
        app.launchForFailureEvidence()

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForPublicElement(
                "mode.continue.button", timeout: TestWait.seconds(.infrastructure(10))),
            "After the visual matrix injects the test server, the app should go straight to the mode selection page"
        )
        return app
    }

    func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshotForFailureEvidence())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tapForFailureEvidence()
            return
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapForFailureEvidence()
    }

    func deviceTag() -> String {
        UIDevice.current.model.replacingOccurrences(of: " ", with: "_").lowercased()
    }
}
#endif
