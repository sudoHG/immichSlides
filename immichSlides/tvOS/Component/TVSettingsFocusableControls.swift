import SwiftUI

// Custom focus is passed down through a custom environment value,
// since isFocused doesn't always reach the innermost label.

private struct TVSettingsVisualFocusKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private extension EnvironmentValues {
    var tvSettingsVisualFocus: Bool? {
        get { self[TVSettingsVisualFocusKey.self] }
        set { self[TVSettingsVisualFocusKey.self] = newValue }
    }
}

struct TVSettingsNavigationRowLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isFocused) private var environmentIsFocused
    @Environment(\.tvSettingsVisualFocus) private var visualFocusFromContainer

    let title: String
    var subtitle: String? = nil
    var summary: String? = nil
    let icon: String
    var isFocusedOverride: Bool? = nil

    private var isFocused: Bool {
        isFocusedOverride ?? visualFocusFromContainer ?? environmentIsFocused
    }

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(iconBackgroundColor)
                    .frame(width: 56, height: 56)

                Image(systemName: icon)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(titleColor)

                if let subtitle, !subtitle.isEmpty {
                    Text(LocalizedStringKey(subtitle))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                }

                if let summary, !summary.isEmpty {
                    Text(LocalizedStringKey(summary))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(summaryColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 16)

            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(chevronColor)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(chevronBackgroundColor)
                )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isFocused ? 4 : 1)
        )
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .inset(by: 4)
                    .strokeBorder(innerFocusBorderColor, lineWidth: 1.4)
            }
        }
        .shadow(color: focusShadowColor, radius: isFocused ? 16 : 0, x: 0, y: 0)
        .scaleEffect(isFocused ? 1.025 : 1.0)
        .animation(.easeInOut(duration: 0.16), value: isFocused)
    }

    private var backgroundColor: Color {
        if isFocused {
            return colorScheme == .dark
                ? Color.white.opacity(0.88)
                : Color.white
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }

    private var borderColor: Color {
        if isFocused {
            return colorScheme == .dark
                ? Color.black.opacity(0.28)
                : Color.blue.opacity(0.70)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.06)
    }

    private var innerFocusBorderColor: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.93, blue: 0.42)
            : Color.white.opacity(0.86)
    }

    private var focusShadowColor: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.88, blue: 0.30).opacity(0.30)
            : Color.blue.opacity(0.18)
    }

    private var titleColor: Color {
        if isFocused {
            return .black
        }

        return .primary
    }

    private var subtitleColor: Color {
        if isFocused {
            return Color.black.opacity(0.66)
        }

        return .secondary
    }

    private var summaryColor: Color {
        if isFocused {
            return Color.black.opacity(0.72)
        }

        return colorScheme == .dark
            ? Color.cyan.opacity(0.92)
            : Color.blue.opacity(0.86)
    }

    private var iconBackgroundColor: Color {
        if isFocused {
            return Color.black.opacity(0.10)
        }

        return colorScheme == .dark
            ? Color.cyan.opacity(0.18)
            : Color.cyan.opacity(0.12)
    }

    private var iconColor: Color {
        if isFocused {
            return .black
        }

        return .primary
    }

    private var chevronColor: Color {
        if isFocused {
            return .black
        }

        return .secondary
    }

    private var chevronBackgroundColor: Color {
        if isFocused {
            return Color.black.opacity(0.10)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }
}

struct TVSettingsSidebarButtonLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isFocused) private var environmentIsFocused
    @Environment(\.tvSettingsVisualFocus) private var visualFocusFromContainer

    let title: String
    let icon: String
    let isSelected: Bool
    var isFocusedOverride: Bool? = nil
    var onFocus: (() -> Void)? = nil

    private var isFocused: Bool {
        isFocusedOverride ?? visualFocusFromContainer ?? environmentIsFocused
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(iconBackgroundColor)
                    .frame(width: 52, height: 52)

                Image(systemName: icon)
                    .font(.system(size: 21, weight: .semibold))
            }

            Text(LocalizedStringKey(title))
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)

            Spacer(minLength: 0)

            if isSelected {
                Capsule(style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.32)
                            : Color.blue.opacity(0.38)
                    )
                    .frame(width: 8, height: 34)
            }
        }
        .foregroundStyle(labelColor)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isFocused ? 4 : 1)
        )
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .inset(by: 4)
                    .strokeBorder(innerFocusBorderColor, lineWidth: 1.4)
            }
        }
        .shadow(color: focusShadowColor, radius: isFocused ? 16 : 0, x: 0, y: 0)
        .scaleEffect(isFocused ? 1.025 : 1.0)
        .animation(.easeInOut(duration: 0.16), value: isFocused)
        .onChange(of: isFocused) { _, focused in
            if focused {
                onFocus?()
            }
        }
    }

    private var backgroundColor: Color {
        if isFocused {
            return colorScheme == .dark
                ? Color.white.opacity(0.88)
                : Color.white
        }

        if isSelected {
            return colorScheme == .dark
                ? Color.white.opacity(0.08)
                : Color.black.opacity(0.05)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.03)
            : Color.white.opacity(0.18)
    }

    private var borderColor: Color {
        if isFocused {
            return colorScheme == .dark
                ? Color.black.opacity(0.28)
                : Color.blue.opacity(0.70)
        }

        return isSelected
            ? Color.white.opacity(colorScheme == .dark ? 0.16 : 0.00)
            : Color.clear
    }

    private var innerFocusBorderColor: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.93, blue: 0.42)
            : Color.white.opacity(0.86)
    }

    private var focusShadowColor: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.88, blue: 0.30).opacity(0.30)
            : Color.blue.opacity(0.18)
    }

    private var labelColor: Color {
        if isFocused {
            return .black
        }

        return .primary
    }

    private var iconBackgroundColor: Color {
        if isFocused {
            return Color.black.opacity(0.10)
        }

        if isSelected {
            return colorScheme == .dark
                ? Color.cyan.opacity(0.18)
                : Color.cyan.opacity(0.12)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }
}

struct TVSettingsActionRowLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isFocused) private var environmentIsFocused
    @Environment(\.tvSettingsVisualFocus) private var visualFocusFromContainer

    let title: String
    let value: String
    let valueTint: Color
    let isEnabled: Bool
    var isFocusedOverride: Bool? = nil

    private var isFocused: Bool {
        isFocusedOverride ?? visualFocusFromContainer ?? environmentIsFocused
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(titleColor)
            }

            Spacer(minLength: 18)

            HStack(spacing: 10) {
                Text(LocalizedStringKey(value))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(valueColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(valueBackgroundColor)
                    )

                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(chevronColor)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(chevronBackgroundColor)
                    )
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isFocused ? 4 : 1)
        )
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .inset(by: 4)
                    .strokeBorder(innerFocusBorderColor, lineWidth: 1.4)
            }
        }
        .shadow(color: focusShadowColor, radius: isFocused ? 16 : 0, x: 0, y: 0)
        .scaleEffect(isFocused ? 1.025 : 1.0)
        .opacity(isEnabled ? 1.0 : 0.52)
        .animation(.easeInOut(duration: 0.16), value: isFocused)
    }

    private var backgroundColor: Color {
        if isFocused {
            return colorScheme == .dark
                ? Color.white.opacity(0.88)
                : Color.white
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }

    private var borderColor: Color {
        if isFocused {
            return colorScheme == .dark
                ? Color.black.opacity(0.28)
                : Color.blue.opacity(0.70)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.06)
    }

    private var innerFocusBorderColor: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.93, blue: 0.42)
            : Color.white.opacity(0.86)
    }

    private var focusShadowColor: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.88, blue: 0.30).opacity(0.30)
            : Color.blue.opacity(0.18)
    }

    private var titleColor: Color {
        if isFocused {
            return .black
        }

        return .primary
    }

    private var valueColor: Color {
        isEnabled ? valueTint : .secondary
    }

    private var chevronColor: Color {
        isEnabled ? .secondary : Color.secondary.opacity(0.55)
    }

    private var valueBackgroundColor: Color {
        if isFocused {
            return Color.black.opacity(0.10)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }

    private var chevronBackgroundColor: Color {
        if isFocused {
            return Color.black.opacity(0.10)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }
}

struct TVSettingsChoiceButton: View {
    let title: String
    let isSelected: Bool
    var accessibilityIdentifier: String? = nil
    let action: () -> Void

    var body: some View {
        // Discrete options also use the custom-focus control, to avoid the system Button's white shell overflowing.

        TVSettingsFocusableControl(
            accessibilityLabel: title,
            accessibilityValue: isSelected ? String(localized: "Selected") : String(localized: "Not Selected"),
            accessibilityIdentifier: accessibilityIdentifier,
            action: action
        ) {
            TVSettingsChoiceButtonLabel(title: title, isSelected: isSelected)
        }
    }
}

// Custom-focus control plus state-driven navigationDestination, to avoid clashing with the system focus shell.

struct TVSettingsFocusableNavigationControl<Destination: View, Label: View>: View {
    let accessibilityLabel: String
    var accessibilityValue: String? = nil
    var accessibilityIdentifier: String? = nil
    var onActivate: (() -> Void)? = nil
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label

    @State private var isNavigating = false

    var body: some View {
        TVSettingsFocusableControl(
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue,
            accessibilityIdentifier: accessibilityIdentifier,
            action: {
                onActivate?()
                isNavigating = true
            }
        ) {
            label()
        }
        .navigationDestination(isPresented: $isNavigating) {
            destination()
        }
    }
}

// Don't use the system Button: a custom border on top of the system focus shell overflows with a white edge.

struct TVSettingsFocusableControl<Label: View>: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusBindingIsFocused: Bool

    let canFocus: Bool
    let accessibilityLabel: String
    var accessibilityValue: String? = nil
    var accessibilityIdentifier: String? = nil
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(
        canFocus: Bool = true,
        accessibilityLabel: String,
        accessibilityValue: String? = nil,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.canFocus = canFocus
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
        self.label = label
    }

    var body: some View {
        label()
            .contentShape(Rectangle())
            .focusable(canFocus, interactions: .activate)
            .focused($focusBindingIsFocused)
            .environment(\.tvSettingsVisualFocus, hasVisualFocus)
            .appTVDisableDefaultFocusEffect()
            .shadow(color: focusHaloColor, radius: hasVisualFocus ? 18 : 0, x: 0, y: 0)
            .scaleEffect(hasVisualFocus ? 1.025 : 1.0)
            .animation(.easeInOut(duration: 0.16), value: hasVisualFocus)
            .allowsHitTesting(canFocus)
            .onTapGesture {
                guard canFocus else { return }
                action()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(LocalizedStringKey(accessibilityLabel)))
            .accessibilityValue(accessibilityValueText)
            .accessibilityAddTraits(.isButton)
            .accessibilityRespondsToUserInteraction(canFocus)
            .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }

    private var focusHaloColor: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.88, blue: 0.30).opacity(0.32)
            : Color.orange.opacity(0.20)
    }

    private var resolvedAccessibilityValue: String {
        // Only UI tests append focused to accessibilityValue; in production it still reads the normal text.

        let baseValue = accessibilityValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard shouldExposeUITestFocusMarker else {
            return baseValue
        }

        var parts: [String] = []
        if hasVisualFocus {
            parts.append("focused")
        }
        if baseValue.isEmpty == false {
            // The composite is emitted verbatim, so localize the value here the way production does.
            parts.append(NSLocalizedString(baseValue, comment: ""))
        }
        return parts.joined(separator: " | ")
    }

    private var shouldExposeUITestFocusMarker: Bool {
        ProcessInfo.processInfo.environment["UI_TEST_RESET_STATE"] == "1"
    }

    private var accessibilityValueText: Text {
        if shouldExposeUITestFocusMarker {
            return Text(verbatim: resolvedAccessibilityValue)
        }

        return Text(LocalizedStringKey(resolvedAccessibilityValue))
    }

    private var hasVisualFocus: Bool {
        isFocused || focusBindingIsFocused
    }
}

struct TVSettingsChoiceButtonLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isFocused) private var environmentIsFocused
    @Environment(\.tvSettingsVisualFocus) private var visualFocusFromContainer

    let title: String
    let isSelected: Bool
    var isFocusedOverride: Bool? = nil

    private var isFocused: Bool {
        isFocusedOverride ?? visualFocusFromContainer ?? environmentIsFocused
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 20, weight: .bold))

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .bold))
            }
        }
        .foregroundStyle(labelColor)
        .frame(maxWidth: .infinity, minHeight: 78)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isFocused ? 4 : 1)
        )
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .inset(by: 4)
                    .strokeBorder(innerFocusBorderColor, lineWidth: 1.4)
            }
        }
        .shadow(color: focusShadowColor, radius: isFocused ? 14 : 0, x: 0, y: 0)
        .scaleEffect(isFocused ? 1.025 : 1.0)
        .animation(.easeInOut(duration: 0.16), value: isFocused)
    }

    private var backgroundColor: Color {
        if isFocused {
            return colorScheme == .dark
                ? Color.white.opacity(0.88)
                : Color.white
        }

        if isSelected {
            return colorScheme == .dark
                ? Color.cyan.opacity(0.20)
                : Color.cyan.opacity(0.14)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.04)
    }

    private var borderColor: Color {
        if isFocused {
            return colorScheme == .dark
                ? Color.black.opacity(0.28)
                : Color.blue.opacity(0.70)
        }

        if isSelected {
            return Color.cyan.opacity(0.88)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.06)
    }

    private var innerFocusBorderColor: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.93, blue: 0.42)
            : Color.white.opacity(0.86)
    }

    private var focusShadowColor: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.88, blue: 0.30).opacity(0.28)
            : Color.blue.opacity(0.16)
    }

    private var labelColor: Color {
        if isFocused {
            return .black
        }

        return .primary
    }
}
