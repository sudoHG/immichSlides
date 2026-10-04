import SwiftUI

enum SettingSelection: CaseIterable, Identifiable, Hashable {
    case playback
    case accessProtection
    case server
    case cache
    case about

    var id: Self { self }

    var title: String {
        // Must use String(localized:) here; downstream code receives the finished localized string.
        switch self {
        case .server: String(localized: "Server")
        case .accessProtection: String(localized: "Access Protection")
        case .playback: String(localized: "Playback Settings")
        case .cache: String(localized: "Cache Management")
        case .about: String(localized: "About")
        }
    }

    var icon: String {
        switch self {
        case .server: "server.rack"
        case .accessProtection: "lock.shield"
        case .playback: "play.circle"
        case .cache: "externaldrive"
        case .about: "info.circle"
        }
    }
}

enum AccessPinInputTarget {
    case enablePin
    case enablePinConfirm
    case disablePin
    case currentPinForChange
    case newPin
    case newPinConfirm
}

enum SettingsCardLayout {
    static let sectionMaxWidth: CGFloat = 620
    static let cardOuterHorizontalInset: CGFloat = 20
    static let cardInnerHorizontalInset: CGFloat = 18
    static let cardInnerVerticalInset: CGFloat = 16
    static let cardCornerRadius: CGFloat = 20
    static let titleLeading: CGFloat = cardOuterHorizontalInset + cardInnerHorizontalInset
}
