import XCTest

// Guards the private PIN input boundary: a missing key or bad format must not fall back to a source constant,
// and error messages must not echo the PIN.

final class PrivatePINInputTests: XCTestCase {
    func testMissingPrivatePINKeysFailClosed() {
        XCTAssertThrowsError(
            try requirePrivatePINInput(environment: [:])
        ) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("STRICT_E2E_INPUT_PIN"), "A missing key must name the input key")
            XCTAssertFalse(text.contains("TEST_RUNNER_"), "The error must not ask for the PIN in a command prefix")
        }
    }

    func testBlankOrInvalidPrivatePINFormatFailsWithoutEcho() {
        let correctKey = "STRICT_E2E_INPUT_PIN"
        let wrongKey = "STRICT_E2E_INPUT_PIN_WRONG"
        let invalid = "12ab"
        XCTAssertThrowsError(
            try requirePrivatePINInput(
                environment: [
                    correctKey: invalid,
                    wrongKey: String(repeating: "0", count: 6)
                ]
            )
        ) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains(correctKey))
            XCTAssertFalse(text.contains(invalid), "A format error must not echo the input value")
        }
    }

    func testSameCorrectAndWrongPrivatePINFails() {
        let repeated = String(repeating: "8", count: 6)
        XCTAssertThrowsError(
            try requirePrivatePINInput(
                environment: [
                    "STRICT_E2E_INPUT_PIN": repeated,
                    "STRICT_E2E_INPUT_PIN_WRONG": repeated
                ]
            )
        )
    }

    func testRunnerPrefixedPrivatePINKeysAreAccepted() throws {
        let correct = String(repeating: "8", count: 6)
        let wrong = String(repeating: "7", count: 6)
        let pins = try requirePrivatePINInput(
            environment: [
                "TEST_RUNNER_STRICT_E2E_INPUT_PIN": correct,
                "TEST_RUNNER_STRICT_E2E_INPUT_PIN_WRONG": wrong
            ]
        )
        XCTAssertEqual(pins.correct, correct)
        XCTAssertEqual(pins.wrong, wrong)
    }

    func testAssertPinAbsentRejectsPasswordInEvidenceText() {
        let secret = String(repeating: "9", count: 6)
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPinAbsent(
                in: "gate-log \(secret) still-open",
                pinValues: [secret]
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPinAbsent(
                in: "pin-restart-gate pin-wrong pin-cancel-safe",
                pinValues: [secret]
            )
        )
    }

    func testUserDefaultsStorageVerdictStaysPartial() throws {
        XCTAssertEqual(
            try AccessLifecycleContract.pinStorageVerdict(
                storageKind: "uitest_userdefaults",
                isXCTestConfigPresent: true
            ),
            "PARTIAL"
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.pinStorageVerdict(
                storageKind: "keychain",
                isXCTestConfigPresent: true
            )
        )
    }
}
