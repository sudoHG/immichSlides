// Guards PIN format, wrong-PIN verification and lost-PIN recovery; isolates only the access protection keys and
// does not prove the production Keychain.

import XCTest
import Testing
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
        XCTAssertTrue(store.isRecoveryNeeded)

        store.resetProtection()
        XCTAssertFalse(store.isRecoveryNeeded)
    }
}

@MainActor
struct AccessProtectionViewModelTests {
    private let originalPIN = String(repeating: "2", count: 6)
    private let replacementPIN = String(repeating: "3", count: 6)
    private let wrongPIN = String(repeating: "4", count: 6)

    @Test
    func `enabling changing and disabling protection persists through a new coordinator`() throws {
        let store = InMemoryAccessProtectionStore()
        let viewModel = AccessProtectionViewModel(store: store)
        try viewModel.enableProtection(pin: originalPIN, confirmPin: originalPIN)
        #expect(viewModel.isEnabled)
        #expect(AccessProtectionViewModel(store: store).isEnabled)
        #expect(store.verifyPIN(originalPIN))

        try viewModel.changePIN(currentPin: originalPIN, newPin: replacementPIN, confirmPin: replacementPIN)
        #expect(store.verifyPIN(replacementPIN))
        #expect(!store.verifyPIN(originalPIN))
        #expect(AccessProtectionViewModel(store: store).isEnabled)

        try viewModel.disableProtection(currentPin: replacementPIN)
        #expect(!viewModel.isEnabled)
        #expect(!AccessProtectionViewModel(store: store).isEnabled)
        #expect(!store.hasStoredPIN)
    }

    @Test(arguments: [false, true])
    func `a failed PIN write preserves the previous protection state`(_ wasEnabled: Bool) throws {
        let store = InMemoryAccessProtectionStore()
        let viewModel = AccessProtectionViewModel(store: store)
        if wasEnabled {
            try viewModel.enableProtection(pin: originalPIN, confirmPin: originalPIN)
        }
        store.shouldFailWrite = true

        #expect(throws: AccessProtectionError.keychainFailure) {
            if wasEnabled {
                try viewModel.changePIN(currentPin: originalPIN, newPin: replacementPIN, confirmPin: replacementPIN)
            } else {
                try viewModel.enableProtection(pin: replacementPIN, confirmPin: replacementPIN)
            }
        }

        #expect(viewModel.isEnabled == wasEnabled)
        #expect(AccessProtectionViewModel(store: store).isEnabled == wasEnabled)
        #expect(store.hasStoredPIN == wasEnabled)
        #expect(store.verifyPIN(originalPIN) == wasEnabled)
        #expect(!store.verifyPIN(replacementPIN))
    }

    @Test(arguments: RejectedPINOperation.allCases)
    func `rejected PIN operations leave the saved protection unchanged`(_ operation: RejectedPINOperation) throws {
        let store = InMemoryAccessProtectionStore()
        let viewModel = AccessProtectionViewModel(store: store)
        try viewModel.enableProtection(pin: originalPIN, confirmPin: originalPIN)

        #expect(throws: operation.expectedError) {
            switch operation {
            case .enableMismatch:
                try viewModel.enableProtection(pin: replacementPIN, confirmPin: wrongPIN)
            case .disableWrongPIN:
                try viewModel.disableProtection(currentPin: wrongPIN)
            case .changeWrongPIN:
                try viewModel.changePIN(currentPin: wrongPIN, newPin: replacementPIN, confirmPin: replacementPIN)
            case .changeMismatch:
                try viewModel.changePIN(currentPin: originalPIN, newPin: replacementPIN, confirmPin: wrongPIN)
            }
        }
        #expect(viewModel.isEnabled)
        #expect(store.isEnabled)
        #expect(store.verifyPIN(originalPIN))
        #expect(!store.verifyPIN(replacementPIN))
    }

    @Test
    func `wrong PIN and cancel never open settings and a later request still requires verification`() throws {
        let store = InMemoryAccessProtectionStore()
        try AccessProtectionViewModel(store: store).enableProtection(pin: originalPIN, confirmPin: originalPIN)
        let coordinator = SettingsAccessCoordinator(store: store)
        var openCount = 0
        let openSettings = { openCount += 1 }

        coordinator.requestSettings(onOpenSettings: openSettings)
        #expect(coordinator.isPinEntrySheetPresented)
        #expect(openCount == 0)
        coordinator.submitPIN(wrongPIN, onOpenSettings: openSettings)
        #expect(coordinator.isPinEntrySheetPresented)
        #expect(coordinator.pinEntryErrorMessage == String(localized: "PIN is incorrect. Please try again."))
        #expect(openCount == 0)
        coordinator.cancelPIN()
        #expect(!coordinator.isPinEntrySheetPresented)
        #expect(coordinator.pinEntryErrorMessage.isEmpty)
        #expect(openCount == 0)

        coordinator.requestSettings(onOpenSettings: openSettings)
        #expect(coordinator.isPinEntrySheetPresented)
        #expect(openCount == 0)
        coordinator.submitPIN(originalPIN, onOpenSettings: openSettings)
        #expect(!coordinator.isPinEntrySheetPresented)
        #expect(coordinator.pinEntryErrorMessage.isEmpty)
        #expect(openCount == 1)
        coordinator.requestSettings(onOpenSettings: openSettings)
        #expect(coordinator.isPinEntrySheetPresented)
        #expect(openCount == 1)
        coordinator.cancelPIN()
        #expect(openCount == 1)
    }

    @Test(arguments: [false, true])
    func `settings access distinguishes disabled protection from missing PIN recovery`(_ isEnabled: Bool) {
        let store = InMemoryAccessProtectionStore()
        store.isEnabled = isEnabled
        let coordinator = SettingsAccessCoordinator(store: store)
        var openCount = 0
        coordinator.requestSettings { openCount += 1 }

        #expect(openCount == (isEnabled ? 0 : 1))
        #expect(coordinator.isAccessProtectionRecoveryAlertPresented == isEnabled)
        #expect(!coordinator.isPinEntrySheetPresented)
    }

    enum RejectedPINOperation: CaseIterable {
        case enableMismatch, disableWrongPIN, changeWrongPIN, changeMismatch

        var expectedError: AccessProtectionError {
            switch self {
            case .enableMismatch, .changeMismatch: return .pinConfirmationMismatch
            case .disableWrongPIN, .changeWrongPIN: return .invalidCurrentPin
            }
        }
    }
}

// Atomic in-memory writes test coordinator ordering, not the production Keychain transaction.
@MainActor
private final class InMemoryAccessProtectionStore: AccessProtectionStoring {
    var isEnabled = false
    var shouldFailWrite = false
    private var savedPIN: String?
    var hasStoredPIN: Bool { savedPIN != nil }
    var isRecoveryNeeded: Bool { isEnabled && !hasStoredPIN }

    func savePIN(_ pin: String) throws {
        if shouldFailWrite { throw AccessProtectionError.keychainFailure }
        guard AccessProtectionStore.isValidPinFormat(pin) else { throw AccessProtectionError.invalidPinFormat }
        savedPIN = pin
    }

    func verifyPIN(_ pin: String) -> Bool { savedPIN == pin }
    func clearPIN() { savedPIN = nil }
    func resetProtection() { clearPIN(); isEnabled = false }
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
