import Foundation
import Combine

@MainActor
final class AccessProtectionViewModel: ObservableObject {
    @Published var isEnabled: Bool

    private let store: AccessProtectionStore

    convenience init() {
        self.init(store: .shared)
    }

    init(store: AccessProtectionStore) {
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

    var needsRecovery: Bool {
        store.needsRecovery
    }

    func resetProtectionForRecovery() {
        store.resetProtection()
        isEnabled = false
    }
}
