import SwiftUI

/// The single entry point for device and size class checks.

struct ViewLayoutTraits {
    let horizontalSizeClass: UserInterfaceSizeClass?
    let verticalSizeClass: UserInterfaceSizeClass?
    let userInterfaceIdiom: UIUserInterfaceIdiom

    var isPhone: Bool {
        userInterfaceIdiom == .phone
    }

    var isCompactWidth: Bool {
        horizontalSizeClass == .compact
    }

    var isCompactHeight: Bool {
        verticalSizeClass == .compact
    }

    /// iPhone portrait is the layout most likely to overflow.
    var isPhonePortrait: Bool {
        isPhone && isCompactWidth && !isCompactHeight
    }

    var isPhoneLandscape: Bool {
        isPhone && isCompactHeight
    }

    var isTV: Bool {
        userInterfaceIdiom == .tv
    }

    var isTouchDevice: Bool {
        userInterfaceIdiom == .phone || userInterfaceIdiom == .pad

    }
}
