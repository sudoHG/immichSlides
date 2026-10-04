import Testing
@testable import immichSlides

@Suite
struct UnitTestHostTests {
    @Test func `the app detects that it is hosting unit tests so its UI stays idle`() {
        #expect(PlatformCompat.isHostingUnitTests)
    }

    @Test func `a UI-test-launched app that only sets the XCTest config variable is not a unit test host`() {
        #expect(
            !PlatformCompat.isUnitTestHost(
                environment: [
                    "XCTestConfigurationFilePath": "SmartFillMotionEvidenceUITest", "UI_TEST_RESET_STATE": "1"
                ],
                isXCTestLoaded: false
            ))
    }

    @Test func `a normal launch without the XCTest config variable is not a unit test host`() {
        #expect(!PlatformCompat.isUnitTestHost(environment: [:], isXCTestLoaded: true))
    }

    @Test func `a process with the XCTest config variable and XCTest loaded is a unit test host`() {
        #expect(
            PlatformCompat.isUnitTestHost(
                environment: ["XCTestConfigurationFilePath": "/tmp/config.xctestconfiguration"],
                isXCTestLoaded: true
            ))
    }
}
