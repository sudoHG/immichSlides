import SwiftUI

struct PinEntrySheetView: View {
    let title: String
    let message: String
    let errorMessage: String?
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    var body: some View {
        #if os(tvOS)
        PinEntrySheetViewTV(
            title: title,
            message: message,
            errorMessage: errorMessage,
            onCancel: onCancel,
            onSubmit: onSubmit
        )
        #else
        PinEntrySheetViewIOS(
            title: title,
            message: message,
            errorMessage: errorMessage,
            onCancel: onCancel,
            onSubmit: onSubmit
        )
        #endif
    }
}

#Preview {
    PinEntrySheetView(
        title: String(localized: "Enter PIN"),
        // Do not use String(localized:) for Preview samples, so they are not written into the Localizable catalog.
        message: "Verify the access protection PIN before opening Settings.",
        errorMessage: nil,
        onCancel: {},
        onSubmit: { _ in }
    )
}
