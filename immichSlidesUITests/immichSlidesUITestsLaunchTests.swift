//
//  immichSlidesUITestsLaunchTests.swift
//  immichSlidesUITests
//
//  Created by sudoHG on 2026/3/18.
//

import XCTest

#if os(iOS)
final class immichSlidesUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        // RESET_STATE is required, or the launch screenshot inherits the previous test's playback page/PIN/settings.

        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        app.launch()

        XCTAssertTrue(
            app.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 10),
            "After launch, the app should reliably open the first-launch setup page"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
