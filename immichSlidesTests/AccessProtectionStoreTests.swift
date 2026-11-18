// Guards PIN format, wrong-PIN verification and lost-PIN recovery; isolates only the access protection keys and
// does not prove the production Keychain.

import XCTest
import Testing
import CryptoKit
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
        store.keychain.failingWrites = ["pinRecord", "pinHash", "pinSalt"]

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

@MainActor
struct AccessProtectionPersistenceTests {
    private let originalPIN = String(repeating: "2", count: 6)
    private let replacementPIN = String(repeating: "3", count: 6)

    @Test(arguments: [false, true])
    func `a failed save keeps the complete previous PIN verifying`(_ usesLegacyFormat: Bool) throws {
        let fixture = InMemoryAccessProtectionStore()
        if usesLegacyFormat {
            fixture.keychain.seedLegacyPIN(originalPIN)
        } else {
            try fixture.savePIN(originalPIN)
        }
        fixture.isEnabled = true
        let savedItems = fixture.keychain.items
        fixture.keychain.failingWrites = ["pinRecord", "pinSalt"]

        #expect(throws: AccessProtectionError.keychainFailure) { try fixture.savePIN(replacementPIN) }
        #expect(fixture.verifyPIN(originalPIN))
        #expect(!fixture.verifyPIN(replacementPIN))
        #expect(!fixture.isRecoveryNeeded)
        #expect(fixture.keychain.items == savedItems)
    }

    @Test
    func `a legacy PIN verifies and migrates only after a successful save`() throws {
        let fixture = InMemoryAccessProtectionStore()
        fixture.keychain.seedLegacyPIN(originalPIN)
        fixture.isEnabled = true
        #expect(fixture.verifyPIN(originalPIN))
        #expect(!fixture.isRecoveryNeeded)
        #expect(fixture.keychain.items["pinRecord"] == nil)

        try fixture.savePIN(replacementPIN)

        #expect(fixture.verifyPIN(replacementPIN))
        #expect(!fixture.verifyPIN(originalPIN))
        #expect(Set(fixture.keychain.items.keys) == ["pinRecord"])
        #expect(!fixture.isRecoveryNeeded)
    }

    @Test
    func `a failed legacy cleanup leaves the new PIN authoritative`() throws {
        let fixture = InMemoryAccessProtectionStore()
        fixture.keychain.seedLegacyPIN(originalPIN)
        fixture.keychain.failingDeletes = ["pinHash", "pinSalt"]
        try fixture.savePIN(replacementPIN)

        #expect(fixture.verifyPIN(replacementPIN))
        #expect(!fixture.verifyPIN(originalPIN))
        #expect(fixture.hasStoredPIN)
        #expect(fixture.keychain.items["pinRecord"] != nil)
    }

    @Test
    func `clearing a legacy PIN reaches missing PIN recovery and reset disables it`() {
        let fixture = InMemoryAccessProtectionStore()
        fixture.keychain.seedLegacyPIN(originalPIN)
        fixture.isEnabled = true
        #expect(!fixture.isRecoveryNeeded)
        fixture.clearPIN()
        #expect(!fixture.hasStoredPIN)
        #expect(!fixture.verifyPIN(originalPIN))
        #expect(fixture.keychain.items.isEmpty)
        #expect(fixture.isRecoveryNeeded)
        fixture.resetProtection()
        #expect(!fixture.isEnabled)
        #expect(!fixture.isRecoveryNeeded)
    }

    @Test(arguments: [nil, Data(), Data([2]) + Data(repeating: 0, count: 48)] as [Data?])
    func `an unreadable new record requires recovery instead of using stale legacy items`(_ record: Data?) {
        let fixture = InMemoryAccessProtectionStore()
        fixture.keychain.seedLegacyPIN(originalPIN)
        fixture.keychain.items["pinRecord"] = record
        if record == nil { fixture.keychain.failingReads = ["pinRecord"] }
        fixture.isEnabled = true
        #expect(!fixture.hasStoredPIN)
        #expect(!fixture.verifyPIN(originalPIN))
        #expect(fixture.isRecoveryNeeded)
    }
}

// Per-item failures drive the production persistence logic; real Keychain integration still needs a device.
@MainActor
private final class InMemoryAccessProtectionStore: AccessProtectionStoring {
    let keychain = InMemoryPINKeychain()
    private let defaultsName = "AccessProtectionStoreTests.\(UUID().uuidString)"
    private let store: AccessProtectionStore

    init() {
        store = AccessProtectionStore(defaults: UserDefaults(suiteName: defaultsName)!, keychain: keychain)
    }

    deinit { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }

    var isEnabled: Bool {
        get { store.isEnabled }
        set { store.isEnabled = newValue }
    }
    var hasStoredPIN: Bool { store.hasStoredPIN }
    var isRecoveryNeeded: Bool { store.isRecoveryNeeded }

    func savePIN(_ pin: String) throws {
        try store.savePIN(pin)
    }

    func verifyPIN(_ pin: String) -> Bool { store.verifyPIN(pin) }
    func clearPIN() { store.clearPIN() }
    func resetProtection() { store.resetProtection() }
}

private final class InMemoryPINKeychain: AccessProtectionKeychainStoring {
    var items: [String: Data] = [:]
    var failingWrites: Set<String> = []
    var failingDeletes: Set<String> = []
    var failingReads: Set<String> = []

    func read(account: String) throws -> Data? {
        if failingReads.contains(account) { throw AccessProtectionError.keychainFailure }
        return items[account]
    }

    func write(_ data: Data, account: String) -> Bool {
        guard !failingWrites.contains(account) else { return false }
        items[account] = data
        return true
    }

    func delete(account: String) {
        if !failingDeletes.contains(account) { items.removeValue(forKey: account) }
    }

    func seedLegacyPIN(_ pin: String) {
        let salt = Data(repeating: 7, count: 16)
        items["pinHash"] = Data(SHA256.hash(data: Data(pin.utf8) + salt))
        items["pinSalt"] = salt
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
