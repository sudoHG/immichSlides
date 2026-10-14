import Testing
@testable import immichSlides

@Suite
struct UnitTestHostTests {
    @Test func `the read only scene probe does not activate XCTest mode`() {
        let probe = ["UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE": "1"]
        #expect(!PlatformCompat.isRunningXCTest(environment: probe))
        #expect(!PlatformCompat.isRunningXCTest(environment: [:]))
        #expect(
            PlatformCompat.isRunningXCTest(
                environment: probe.merging(["XCTestConfigurationFilePath": "host"]) { _, value in value }))
        #expect(
            PlatformCompat.isRunningXCTest(
                environment: probe.merging(["UI_TEST_RESET_STATE": "1"]) { _, value in value }))
        #expect(PlatformCompat.isRunningXCTest(environment: ["UI_TEST_ANY_FUTURE_KEY": "0"]))
    }

    @Test func `the read only scene probe exposes diagnostics only when enabled`() {
        #expect(
            PlatformCompat.shouldExposeUITestProbes(environment: ["UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE": "1"]))
        #expect(
            !PlatformCompat.shouldExposeUITestProbes(environment: ["UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE": "0"]))
        #expect(!PlatformCompat.shouldExposeUITestProbes(environment: [:]))
        #expect(PlatformCompat.shouldExposeUITestProbes(environment: ["UI_TEST_RESET_STATE": "1"]))
        #expect(PlatformCompat.shouldExposeUITestProbes(environment: ["XCTestConfigurationFilePath": "test-host"]))
    }

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
