import Foundation
import Combine

@MainActor
protocol AccessProtectionStoring: AnyObject {
    var isEnabled: Bool { get set }
    var isRecoveryNeeded: Bool { get }
    func savePIN(_ pin: String) throws
    func verifyPIN(_ pin: String) -> Bool
    func clearPIN()
    func resetProtection()
}

extension AccessProtectionStore: AccessProtectionStoring {}

@MainActor
final class AccessProtectionViewModel: ObservableObject {
    @Published var isEnabled: Bool

    private let store: any AccessProtectionStoring

    convenience init() {
        self.init(store: AccessProtectionStore.shared)
    }

    init(store: any AccessProtectionStoring) {
        self.store = store
        self.isEnabled = store.isEnabled
    }

    func enableProtection(pin: String, confirmPin: String) throws {
        guard pin == confirmPin else {
            throw AccessProtectionError.pinConfirmationMismatch
        }
        try store.savePIN(pin)
        store.isEnabled = true
        isEnabled = true
    }

    func disableProtection(currentPin: String) throws {
        guard store.verifyPIN(currentPin) else {
            throw AccessProtectionError.invalidCurrentPin
        }
        // Turning off access protection also clears the saved PIN so no credential is left behind.
        store.clearPIN()
        store.isEnabled = false
        isEnabled = false
    }

    func changePIN(currentPin: String, newPin: String, confirmPin: String) throws {
        guard store.verifyPIN(currentPin) else {
            throw AccessProtectionError.invalidCurrentPin
        }
        guard newPin == confirmPin else {
            throw AccessProtectionError.pinConfirmationMismatch
        }
        try store.savePIN(newPin)
    }

    var isRecoveryNeeded: Bool {
        store.isRecoveryNeeded
    }

    func resetProtectionForRecovery() {
        store.resetProtection()
        isEnabled = false
    }
}

@MainActor
final class SettingsAccessCoordinator: ObservableObject {
    @Published var isPinEntrySheetPresented = false
    @Published var isAccessProtectionRecoveryAlertPresented = false
    @Published private(set) var pinEntryErrorMessage = ""
    private let store: any AccessProtectionStoring

    init(store: any AccessProtectionStoring = AccessProtectionStore.shared) {
        self.store = store
    }

    func requestSettings(onOpenSettings: () -> Void) {
        if store.isEnabled {
            if store.isRecoveryNeeded {
                isAccessProtectionRecoveryAlertPresented = true
                return
            }
            pinEntryErrorMessage = ""
            isPinEntrySheetPresented = true
        } else {
            onOpenSettings()
        }
    }

    func cancelPIN() {
        pinEntryErrorMessage = ""
        isPinEntrySheetPresented = false
    }

    func submitPIN(_ pin: String, onOpenSettings: () -> Void) {
        if store.verifyPIN(pin) {
            pinEntryErrorMessage = ""
            isPinEntrySheetPresented = false
            onOpenSettings()
        } else {
            pinEntryErrorMessage = String(localized: "PIN is incorrect. Please try again.")
        }
    }
}
