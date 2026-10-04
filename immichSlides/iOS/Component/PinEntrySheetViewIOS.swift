import SwiftUI

struct PinEntrySheetViewIOS: View {

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let title: String
    let message: String
    let errorMessage: String?
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    @State private var pin: [String] = []
    // Briefly lock submission after 6 digits to avoid repeated taps.
    @State private var isSubmitting = false

    private var isCompact: Bool { horizontalSizeClass == .compact }

    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    private var keypadButtonHeight: CGFloat { isCompactHeight ? 46 : 52 }

    private var keypadCornerRadius: CGFloat { isCompactHeight ? 12 : 14 }

    private var sheetHeight: CGFloat { isCompactHeight ? 430 : 500 }

    var body: some View {
        NavigationStack {
            VStack(spacing: isCompactHeight ? 14 : 20) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: isCompactHeight ? 18 : 20, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(LocalizedStringKey(message))
                    .font(.system(size: isCompactHeight ? 13 : 15))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                pinIndicator

                if let errorMessage, !errorMessage.isEmpty {
                    Text(LocalizedStringKey(errorMessage))
                        .accessibilityIdentifier("pinEntry.error.message")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                keypad

                Spacer()
            }
            .padding(isCompactHeight ? 14 : 20)
            .appNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        onCancel()
                    }
                    .accessibilityIdentifier("pinEntry.close.button")
                }
            }
        }

        .presentationDetents([.height(sheetHeight)])
        .onChange(of: errorMessage) { _, _ in
            pin.removeAll()
        }
    }

    private var pinIndicator: some View {
        HStack(spacing: isCompactHeight ? 10 : 12) {
            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .fill(index < pin.count ? Color.primary : Color.clear)
                    .overlay(
                        Circle()
                            .stroke(
                                index < pin.count ? Color.primary : Color.secondary.opacity(0.35),
                                lineWidth: 1.2
                            )
                    )
                    .frame(
                        width: isCompactHeight ? 12 : 14,
                        height: isCompactHeight ? 12 : 14
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isCompactHeight ? 4 : 8)
    }

    private var keypad: some View {
        VStack(spacing: isCompactHeight ? 10 : 12) {
            keypadRow(["1", "2", "3"])
            keypadRow(["4", "5", "6"])
            keypadRow(["7", "8", "9"])

            HStack(spacing: isCompactHeight ? 10 : 12) {

                Color.clear
                    .frame(maxWidth: .infinity)

                keypadButton("0")

                Button {
                    removeDigit()
                } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: isCompactHeight ? 17 : 20))
                        .frame(maxWidth: .infinity, minHeight: keypadButtonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: keypadCornerRadius, style: .continuous)
                                .fill(PlatformCompat.secondarySystemBackground)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Delete"))
                .accessibilityIdentifier("pinEntry.delete.button")
            }
        }
    }

    private func keypadRow(_ digits: [String]) -> some View {
        HStack(spacing: isCompactHeight ? 10 : 12) {
            ForEach(digits, id: \.self) { digit in
                keypadButton(digit)
            }
        }
    }

    private func keypadButton(_ digit: String) -> some View {
        Button {
            addDigit(digit)
        } label: {
            Text(digit)
                .font(.system(size: isCompactHeight ? 19 : (isCompact ? 21 : 23), weight: .medium))
                .frame(maxWidth: .infinity, minHeight: keypadButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: keypadCornerRadius, style: .continuous)
                        .fill(PlatformCompat.secondarySystemBackground)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pinEntry.digit.\(digit).button")
    }

    private func addDigit(_ digit: String) {
        guard !isSubmitting, pin.count < 6 else { return }

        pin.append(digit)

        if pin.count == 6 {
            isSubmitting = true
            let value = pin.joined()
            onSubmit(value)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isSubmitting = false
            }
        }
    }

    private func removeDigit() {
        guard !pin.isEmpty else { return }
        _ = pin.popLast()
    }
}
