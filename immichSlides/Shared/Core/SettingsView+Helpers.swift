import SwiftUI

struct SettingsAboutMetadata {
    let appDisplayName: String
    let versionAndBuildText: String
    let platformLabel: String

    var heroSummary: String {
        LocalizedText.format("Current %@", versionAndBuildText)
    }

    static func current(platformName: String) -> SettingsAboutMetadata {

        let appDisplayName =
            normalizedInfoValue(for: "CFBundleDisplayName") ?? normalizedInfoValue(for: "CFBundleName")
            ?? "immichSlides"

        let version =
            normalizedInfoValue(for: "CFBundleShortVersionString") ?? String(localized: "Unknown Version")

        let build =
            normalizedInfoValue(for: "CFBundleVersion") ?? String(localized: "Unknown Build")

        // Show the OS version as three numbers so it is easy to copy into feedback.

        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let platformLabel =
            "\(platformName) \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"

        return SettingsAboutMetadata(
            appDisplayName: appDisplayName,
            versionAndBuildText: "\(version) (\(build))",
            platformLabel: platformLabel
        )
    }

    private static func normalizedInfoValue(for key: String) -> String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

// The feedback email and mailto are shared by both platforms; tvOS only shows the address and does not open
// Mail.

enum SettingsSupportReference {
    static let emailAddress = "by331works@gmail.com"

    static var mailtoURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = emailAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: mailSubject),
            URLQueryItem(name: "body", value: mailBody)
        ]
        return components.url
    }

    static var entryTitle: String {
        NSLocalizedString("Contact Support", comment: "")
    }

    static var mailSubject: String {
        NSLocalizedString("immichSlides Support Request", comment: "")
    }

    static var mailBody: String {
        NSLocalizedString(
            "Please include the issue description, current version, platform, and steps to reproduce.", comment: "")
    }
}

extension SettingsView {
    var playbackModeBinding: Binding<DefaultPlaybackMode> {
        Binding(
            get: { playbackVM.settings.defaultPlaybackMode },
            set: { newMode in
                selectDefaultPlaybackMode(newMode)
            }
        )
    }

    var filterSummaryText: String {
        if filterVM.selection.isEmpty {
            return String(localized: "No filters set")
        }

        // Summary numbers go through LocalizedText.format so the Catalog does not generate dynamic keys.

        return LocalizedText.format(
            "Albums: %lld · People: %lld",
            Int64(filterVM.selectedAlbumCount),
            Int64(filterVM.selectedPersonCount)
        )
    }

    func settingsBinding<T>(_ keyPath: WritableKeyPath<PlaybackSettings, T>) -> Binding<T> {
        Binding(
            get: { playbackVM.settings[keyPath: keyPath] },
            set: { playbackVM.settings[keyPath: keyPath] = $0 }
        )
    }

    func sanitizePinInput(_ raw: String) -> String {
        String(raw.filter { $0.isNumber }.prefix(6))
    }

    func refreshCacheSummary() {
        cacheSummary = downloadManager.cacheSummary()
    }

    func formatBytes(_ bytes: UInt) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    var aboutMetadata: SettingsAboutMetadata {
        SettingsAboutMetadata.current(platformName: "iOS")
    }

    var openSourceLicenseNotices: [SettingsOpenSourceLicenseNotice] {
        SettingsOpenSourceLicenseNotice.currentCatalog
    }

    var openSourceLicensePackageSummary: String {
        SettingsOpenSourceLicenseNotice.packageSummaryText
    }

    var pinInputTitle: String {
        switch activePinInputTarget {
        case .enablePin: return String(localized: "Set PIN")
        case .enablePinConfirm: return String(localized: "Confirm PIN")
        case .disablePin: return String(localized: "Enter Current PIN")
        case .currentPinForChange: return String(localized: "Enter Current PIN")
        case .newPin: return String(localized: "Enter New PIN")
        case .newPinConfirm: return String(localized: "Confirm New PIN")
        case .none: return String(localized: "Enter PIN")
        }
    }

    func settingsItemAccessibilityID(_ selection: SettingSelection) -> String {
        switch selection {
        case .playback: return "settings.item.playback"
        case .accessProtection: return "settings.item.accessProtection"
        case .server: return "settings.item.server"
        case .cache: return "settings.item.cache"
        case .about: return "settings.item.about"
        }
    }

    func pinInputAccessibilityID(_ target: AccessPinInputTarget) -> String {
        switch target {
        case .enablePin: return "settings.pin.input.enable"
        case .enablePinConfirm: return "settings.pin.input.enableConfirm"
        case .disablePin: return "settings.pin.input.disableCurrent"
        case .currentPinForChange: return "settings.pin.input.changeCurrent"
        case .newPin: return "settings.pin.input.changeNew"
        case .newPinConfirm: return "settings.pin.input.changeConfirm"
        }
    }

    func applyPinInput(_ pin: String) {
        let sanitized = sanitizePinInput(pin)

        switch activePinInputTarget {
        case .enablePin:
            enablePin = sanitized
        case .enablePinConfirm:
            enablePinConfirm = sanitized
        case .disablePin:
            disablePin = sanitized
        case .currentPinForChange:
            currentPinForChange = sanitized
        case .newPin:
            newPin = sanitized
        case .newPinConfirm:
            newPinConfirm = sanitized
        case .none:
            break
        }
    }
}
