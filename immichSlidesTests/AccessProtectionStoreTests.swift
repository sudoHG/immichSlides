// Guards PIN format, wrong-PIN verification and lost-PIN recovery; isolates only the access protection keys and
// does not prove the production Keychain.

import XCTest
@testable import immichSlides

final class AccessProtectionStoreTests: XCTestCase {
    private var defaultsSnapshot = AccessProtectionDefaultsSnapshot.empty

    override func setUp() {
        super.setUp()
        defaultsSnapshot = .capture()
        AccessProtectionStore.shared.resetProtection()
    }

    override func tearDown() {
        // Clear this test's writes first, then restore only the access protection keys, so other tests sharing
        // UserDefaults keep their values.
        AccessProtectionStore.shared.resetProtection()
        defaultsSnapshot.restore()
        defaultsSnapshot = .empty
        super.tearDown()
    }

    func testInvalidPinFormatIsRejected() {
        XCTAssertFalse(AccessProtectionStore.isValidPinFormat("123"))
        XCTAssertFalse(AccessProtectionStore.isValidPinFormat("1234"))
        XCTAssertFalse(AccessProtectionStore.isValidPinFormat("12ab56"))

        XCTAssertThrowsError(try AccessProtectionStore.shared.savePIN("123")) { error in
            XCTAssertEqual(error as? AccessProtectionError, .invalidPinFormat)
        }
        XCTAssertFalse(AccessProtectionStore.shared.hasStoredPIN)
    }

    func testWrongPinDoesNotVerifyAfterSavingValidPin() throws {
        try AccessProtectionStore.shared.savePIN("123456")
        XCTAssertFalse(AccessProtectionStore.shared.verifyPIN("000000"))
        XCTAssertTrue(AccessProtectionStore.shared.verifyPIN("123456"))
    }

    func testEnabledWithoutStoredPinNeedsRecovery() {
        let store = AccessProtectionStore.shared
        store.isEnabled = true
        store.clearPIN()
        XCTAssertTrue(store.needsRecovery)

        store.resetProtection()
        XCTAssertFalse(store.needsRecovery)
    }
}

/// Snapshots only the access protection keys; leaves other UserDefaults such as server or filters alone.
private struct AccessProtectionDefaultsSnapshot {
    private static let keys = [
        "accessProtection.isEnabled",
        "accessProtection.uiTest.storageEnabled",
        "accessProtection.uiTest.pinHash",
        "accessProtection.uiTest.pinSalt"
    ]

    static let empty = AccessProtectionDefaultsSnapshot(values: [:])

    private let values: [String: Any]

    static func capture() -> AccessProtectionDefaultsSnapshot {
        let defaults = UserDefaults.standard
        var values: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) {
                values[key] = value
            }
        }
        return AccessProtectionDefaultsSnapshot(values: values)
    }

    func restore() {
        let defaults = UserDefaults.standard
        for key in Self.keys {
            if let value = values[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
