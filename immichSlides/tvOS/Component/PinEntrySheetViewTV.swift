import SwiftUI

// tvOS PIN entry uses a fixed 4x3 focus grid so the remote doesn't jump around.

struct PinEntrySheetViewTV: View {

    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let message: String
    let errorMessage: String?
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    private enum PinPadFocusTarget: Hashable {
        case digit(Int)
        case closeButton
        case deleteButton
    }

    @State private var pin: [String] = []
    @State private var isSubmitting = false
    @FocusState private var focusedTarget: PinPadFocusTarget?
    @Namespace private var pinPadFocusScope

    private let pinPadButtonHeight: CGFloat = 86
    private let pinPadButtonCornerRadius: CGFloat = 22
    private let pinPadGridWidth: CGFloat = 420

    var body: some View {
        ZStack {

            PlatformCompat.systemGroupedBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                header
                pinIndicator

                if let errorMessage, !errorMessage.isEmpty {
                    Text(LocalizedStringKey(errorMessage))
                        .accessibilityIdentifier("pinEntry.error.message")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                keypad
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(maxWidth: 780)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(cardBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(cardBorderColor, lineWidth: 1)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.16), radius: 24, x: 0, y: 14)
        }
        .appTVFocusScope(
            pinPadFocusScope,
            focused: $focusedTarget,
            default: .digit(1),
            // defaultFocus uses .automatic so it isn't forcibly re-evaluated while the user navigates with arrow keys.

            priority: .automatic
        )
        .onAppear {
            restoreInitialFocusToDigitOne()
        }
        .onChange(of: errorMessage) { _, _ in
            pin.removeAll()
            restoreInitialFocusToDigitOne()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 38, weight: .heavy))
                .foregroundStyle(.primary)

            Text(LocalizedStringKey(message))
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pinIndicator: some View {
        HStack(spacing: 16) {
            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .fill(index < pin.count ? Color.primary : Color.clear)
                    .overlay(
                        Circle()
                            .stroke(
                                index < pin.count ? Color.primary : Color.white.opacity(0.28),
                                lineWidth: 2
                            )
                    )
                    .frame(width: 18, height: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 6)
    }

    private var keypad: some View {
        VStack(spacing: 16) {
            keyRow([.digit(1), .digit(2), .digit(3)])
            keyRow([.digit(4), .digit(5), .digit(6)])
            keyRow([.digit(7), .digit(8), .digit(9)])
            keyRow([.closeButton, .digit(0), .deleteButton])
        }
        // Use a fixed width instead of maxWidth so a shrinking sheet doesn't squeeze out the 3 columns.

        .frame(width: pinPadGridWidth)
        .frame(maxWidth: .infinity)
        .appTVFocusSection()
    }

    private func keyRow(_ targets: [PinPadFocusTarget]) -> some View {
        HStack(spacing: 16) {
            ForEach(targets, id: \.self) { target in
                keyButton(for: target)
                    // The three keys in a row share the width equally so the Close/Delete keys don't wrap.

                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func keyButton(for target: PinPadFocusTarget) -> some View {
        switch target {
        case .digit(let number):
            Button {
                addDigit(String(number))
            } label: {
                TVPinPadButtonLabel(
                    title: String(number),
                    cornerRadius: pinPadButtonCornerRadius,
                    minimumHeight: pinPadButtonHeight
                )
            }
            .buttonStyle(.plain)
            .focused($focusedTarget, equals: .digit(number))
            .hoverEffectDisabled(true)
            .appTVDisableDefaultFocusEffect()
            // Expose focused/notFocused via accessibilityValue for UI tests.

            .accessibilityValue(focusedTarget == .digit(number) ? "focused" : "notFocused")
            .accessibilityIdentifier("pinEntry.digit.\(number).button")

        case .closeButton:
            Button {
                onCancel()
            } label: {
                TVPinPadButtonLabel(
                    title: "Close",
                    systemImage: "xmark",
                    cornerRadius: pinPadButtonCornerRadius,
                    minimumHeight: pinPadButtonHeight
                )
            }
            .buttonStyle(.plain)
            .focused($focusedTarget, equals: .closeButton)
            .hoverEffectDisabled(true)
            .appTVDisableDefaultFocusEffect()
            .accessibilityLabel(Text("Close"))
            .accessibilityValue(focusedTarget == .closeButton ? "focused" : "notFocused")
            .accessibilityIdentifier("pinEntry.close.button")

        case .deleteButton:
            Button {
                removeDigit()
            } label: {
                TVPinPadButtonLabel(
                    title: "Delete",
                    systemImage: "delete.left",
                    cornerRadius: pinPadButtonCornerRadius,
                    minimumHeight: pinPadButtonHeight
                )
            }
            .buttonStyle(.plain)
            .focused($focusedTarget, equals: .deleteButton)
            .hoverEffectDisabled(true)
            .appTVDisableDefaultFocusEffect()
            .accessibilityLabel(Text("Delete"))
            .accessibilityValue(focusedTarget == .deleteButton ? "focused" : "notFocused")
            .accessibilityIdentifier("pinEntry.delete.button")
        }
    }

    private var cardBackgroundColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.38)
            : Color.white.opacity(0.90)
    }

    private var cardBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.08)
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

    private func restoreInitialFocusToDigitOne() {
        // When the sheet appears or resets after an error, move
        // initial focus to 1 in two steps, to cover transition jitter.

        DispatchQueue.main.async {
            focusedTarget = .digit(1)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            // Fall back only when nothing has been entered and focus
            // is lost; don't take back focus the user has moved away.

            guard pin.isEmpty, focusedTarget == nil else { return }
            focusedTarget = .digit(1)
        }
    }

}

// Key appearance is separate from the key's action, which makes isFocused easy to read.

private struct TVPinPadButtonLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isFocused) private var isFocused

    let title: String
    var systemImage: String? = nil
    let cornerRadius: CGFloat
    let minimumHeight: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: contentSpacing) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: symbolFontSize, weight: .semibold))
            }

            Text(LocalizedStringKey(title))
                .font(.system(size: titleFontSize, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .allowsTightening(true)
        }
        .foregroundStyle(labelColor)
        .padding(.horizontal, horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: minimumHeight)
        .background(
            shape.fill(backgroundColor)
        )
        .overlay(
            shape
                .strokeBorder(borderColor, lineWidth: isFocused ? 3 : 1)
        )
        .overlay {
            if isFocused {
                shape
                    .inset(by: 4)
                    .strokeBorder(
                        Color.white.opacity(colorScheme == .dark ? 0.78 : 0.92),
                        lineWidth: 1.4
                    )
            }
        }
        .clipShape(shape)
        // Focus doesn't use scale-up or an outer shadow; it uses a brighter background with a double stroke instead.

        .scaleEffect(1.0)
        .animation(.easeInOut(duration: 0.16), value: isFocused)
    }

    private var backgroundColor: Color {
        if isFocused {
            return Color.white.opacity(colorScheme == .dark ? 0.38 : 0.92)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    private var borderColor: Color {
        if isFocused {
            return Color(red: 1.0, green: 0.86, blue: 0.28).opacity(0.98)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.08)
    }

    private var labelColor: Color {
        if isFocused {
            return colorScheme == .dark ? .white : .black
        }

        return .primary
    }

    private var isActionKey: Bool {
        systemImage != nil
    }

    private var titleFontSize: CGFloat {
        isActionKey ? 20 : 30
    }

    private var symbolFontSize: CGFloat {
        isActionKey ? 18 : 24
    }

    private var contentSpacing: CGFloat {
        isActionKey ? 8 : 0
    }

    private var horizontalPadding: CGFloat {
        isActionKey ? 8 : 10
    }
}
