import Foundation
import Security
import CryptoKit

extension Notification.Name {
    static let accessProtectionStateDidChange = Notification.Name("accessProtectionStateDidChange")
}

enum AccessProtectionError: LocalizedError {
    case invalidPinFormat
    case pinNotSet
    case invalidCurrentPin
    case pinConfirmationMismatch
    case keychainFailure

    var errorDescription: String? {
        switch self {
        case .invalidPinFormat:
            return String(localized: "PIN must be 6 digits")
        case .pinNotSet:
            return String(localized: "No PIN is set yet")
        case .invalidCurrentPin:
            return String(localized: "PIN verification failed")
        case .pinConfirmationMismatch:
            return String(localized: "The PIN entries do not match")
        case .keychainFailure:
            return String(localized: "Failed to read or write secure storage")
        }
    }
}

final class AccessProtectionStore {
    static let shared = AccessProtectionStore()
    private static let saltLengthBytes: Int = 16

    private let defaults = UserDefaults.standard
    private let enabledKey = "accessProtection.isEnabled"
    private let uiTestPINStorageEnabledKey = "accessProtection.uiTest.storageEnabled"
    private let uiTestPinHashKey = "accessProtection.uiTest.pinHash"
    private let uiTestPinSaltKey = "accessProtection.uiTest.pinSalt"

    private let keychainService = "immichSlides.accessProtection"
    private let pinHashAccount = "pinHash"
    private let pinSaltAccount = "pinSalt"

    private init() {}

    var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set {
            defaults.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: .accessProtectionStateDidChange, object: nil)
        }
    }

    var hasStoredPIN: Bool {
        if shouldUseUITestPINStorage {
            return uiTestPINData(forKey: uiTestPinHashKey) != nil && uiTestPINData(forKey: uiTestPinSaltKey) != nil
        }

        return (readKeychainData(account: pinHashAccount) != nil) && (readKeychainData(account: pinSaltAccount) != nil)
    }

    // Fallback recovery check: the logical switch says "enabled" but the key material is missing (for example,
    // the Keychain was wiped).
    var isRecoveryNeeded: Bool {
        isEnabled && !hasStoredPIN
    }

    static func isValidPinFormat(_ pin: String) -> Bool {
        pin.count == 6 && pin.allSatisfy { $0.isNumber }
    }

    func savePIN(_ pin: String) throws {
        guard Self.isValidPinFormat(pin) else {
            throw AccessProtectionError.invalidPinFormat
        }

        let salt = try makeRandomSalt(length: Self.saltLengthBytes)
        let hash = makeHash(pin: pin, salt: salt)

        if shouldUseUITestPINStorage {
            // UI tests without full signing store salt+hash in UserDefaults; release builds only use the Keychain.
            defaults.set(true, forKey: uiTestPINStorageEnabledKey)
            defaults.set(hash, forKey: uiTestPinHashKey)
            defaults.set(salt, forKey: uiTestPinSaltKey)
            return
        }

        guard writeKeychainData(hash, account: pinHashAccount),
            writeKeychainData(salt, account: pinSaltAccount)
        else {
            throw AccessProtectionError.keychainFailure
        }
    }

    func verifyPIN(_ pin: String) -> Bool {
        if shouldUseUITestPINStorage {
            guard Self.isValidPinFormat(pin),
                let savedHash = uiTestPINData(forKey: uiTestPinHashKey),
                let savedSalt = uiTestPINData(forKey: uiTestPinSaltKey)
            else {
                return false
            }

            return makeHash(pin: pin, salt: savedSalt) == savedHash
        }

        guard Self.isValidPinFormat(pin),
            let savedHash = readKeychainData(account: pinHashAccount),
            let savedSalt = readKeychainData(account: pinSaltAccount)
        else {
            return false
        }

        return makeHash(pin: pin, salt: savedSalt) == savedHash
    }

    func clearPIN() {
        if shouldUseUITestPINStorage {
            defaults.removeObject(forKey: uiTestPINStorageEnabledKey)
            defaults.removeObject(forKey: uiTestPinHashKey)
            defaults.removeObject(forKey: uiTestPinSaltKey)
        }

        deleteKeychainData(account: pinHashAccount)
        deleteKeychainData(account: pinSaltAccount)
    }

    // Force-reset access protection so the user cannot be locked out.
    func resetProtection() {
        clearPIN()
        isEnabled = false
    }

    private func makeHash(pin: String, salt: Data) -> Data {
        var input = Data(pin.utf8)
        input.append(salt)
        return Data(SHA256.hash(data: input))
    }

    private var shouldUseUITestPINStorage: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        // launchEnvironment may be gone after a relaunch, so detect test storage via the XCTest path and the Debug
        // marker.
        if env["UI_TEST_RESET_STATE"] == "1" || env["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return defaults.bool(forKey: uiTestPINStorageEnabledKey)
        #else
        return false
        #endif
    }

    private func uiTestPINData(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    private func makeRandomSalt(length: Int) throws -> Data {
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, length, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw AccessProtectionError.keychainFailure
        }
        return data
    }

    private func writeKeychainData(_ data: Data, account: String) -> Bool {
        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        // Delete with the identity query only; if Add hits a duplicate, Update instead, to avoid leftovers on the
        // simulator.
        SecItemDelete(lookupQuery as CFDictionary)
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        }

        if status == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecValueData as String: data
            ]
            return SecItemUpdate(lookupQuery as CFDictionary, update as CFDictionary) == errSecSuccess
        }

        return false
    }

    private func readKeychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteKeychainData(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
