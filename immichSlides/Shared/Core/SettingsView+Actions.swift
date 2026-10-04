import SwiftUI

extension SettingsView {
    func openFilterEditor() {
        showFullScreenFilterEditor = true
    }

    func dismissPinInputSheet() {
        showAccessPinInputSheet = false
        activePinInputTarget = nil
    }

    func openPinInput(_ target: AccessPinInputTarget) {
        activePinInputTarget = target
        showAccessPinInputSheet = true
    }

    func toggleAutoPlay() {
        playbackVM.settings.autoPlayEnabled.toggle()
    }

    func selectPlaybackInterval(_ seconds: Double) {
        playbackVM.settings.intervalSeconds = seconds
    }

    func toggleShowExif() {
        playbackVM.settings.showExif.toggle()
    }

    func toggleShowDebugOverlay() {
        playbackVM.settings.showDebugOverlay.toggle()
    }

    func selectDefaultPlaybackMode(_ mode: DefaultPlaybackMode) {
        if mode == .filtered && filterVM.selection.isEmpty {
            promptState.pendingSwitchToFilteredAfterConfig = true
            promptState.showFilterModeBlockedAlert = true
            return
        }

        playbackVM.settings.defaultPlaybackMode = mode
    }

    func selectPlaybackDisplayMode(_ mode: PlaybackDisplayMode) {
        playbackVM.settings.displayMode = mode
    }

    func cancelFilterModeBlockedAlert() {
        promptState.pendingSwitchToFilteredAfterConfig = false
    }

    func testServerConnection() {
        serverVM.testConnection()
    }

    func saveServerConfiguration() {
        serverVM.saveServerConfig()
    }

    func openSupportEmail() {
        guard let supportURL = SettingsSupportReference.mailtoURL else { return }
        openURL(supportURL)
    }

    func requestClearDiskCache() {
        promptState.showClearDiskCacheAlert = true
    }

    func confirmClearDiskCache() {
        Task {
            isClearingCache = true
            await downloadManager.clearDiskCacheForSettings()
            refreshCacheSummary()
            cacheStatusMessage = String(localized: "Disk cache and state cleared")
            isClearingCache = false
        }
    }

    func enableAccessProtection() {
        do {
            try accessProtectionVM.enableProtection(pin: enablePin, confirmPin: enablePinConfirm)
            enablePin = ""
            enablePinConfirm = ""
            accessProtectionStatusMessage = String(localized: "Access protection is on")
            accessProtectionErrorMessage = ""
        } catch {
            accessProtectionErrorMessage = error.localizedDescription
            accessProtectionStatusMessage = ""
        }
    }

    func disableAccessProtection() {
        do {
            try accessProtectionVM.disableProtection(currentPin: disablePin)
            disablePin = ""
            accessProtectionStatusMessage = String(localized: "Access protection is off")
            accessProtectionErrorMessage = ""
        } catch {
            accessProtectionErrorMessage = error.localizedDescription
            accessProtectionStatusMessage = ""
        }
    }

    func changeAccessProtectionPIN() {
        do {
            try accessProtectionVM.changePIN(
                currentPin: currentPinForChange,
                newPin: newPin,
                confirmPin: newPinConfirm
            )
            currentPinForChange = ""
            newPin = ""
            newPinConfirm = ""
            accessProtectionStatusMessage = String(localized: "PIN updated")
            accessProtectionErrorMessage = ""
        } catch {
            accessProtectionErrorMessage = error.localizedDescription
            accessProtectionStatusMessage = ""
        }
    }

    func resetAccessProtectionForRecovery() {
        accessProtectionVM.resetProtectionForRecovery()
        disablePin = ""
        currentPinForChange = ""
        newPin = ""
        newPinConfirm = ""
        accessProtectionStatusMessage = String(localized: "Access protection was reset. Set the PIN again.")
        accessProtectionErrorMessage = ""
    }

    func enforcePlaybackModeInvariant() {
        playbackVM.enforcePlaybackModeInvariant(
            filterSelectionIsEmpty: filterVM.selection.isEmpty,
            isFilterEditorPresented: showFullScreenFilterEditor
        )
    }
}
