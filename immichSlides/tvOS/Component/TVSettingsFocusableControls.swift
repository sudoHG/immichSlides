import SwiftUI

// Custom focus is passed down through a custom environment value,
// since isFocused doesn't always reach the innermost label.

private enum SettingsControlMetrics {
    static let navigationRowSpacingPoints: CGFloat = 18
    static let iconCornerRadiusPoints: CGFloat = 18
    static let navigationIconSizePoints: CGFloat = 56
    static let subtitleSpacingPoints: CGFloat = 6
    static let chevronSizePoints: CGFloat = 40
    static let navigationHorizontalPaddingPoints: CGFloat = 20
    static let navigationVerticalPaddingPoints: CGFloat = 16
    static let navigationCornerRadiusPoints: CGFloat = 28
    static let focusedBorderWidthPoints: CGFloat = 4
    static let normalBorderWidthPoints: CGFloat = 1
    static let focusInsetPoints: CGFloat = 4
    static let innerBorderWidthPoints: CGFloat = 1.4
    static let focusedScaleMultiplier: CGFloat = 1.025
    static let restingScaleMultiplier: CGFloat = 1.0
    static let focusAnimationDurationSeconds: Double = 0.16
    static let stepperRowSpacingPoints: CGFloat = 14
    static let actionSpacingPoints: CGFloat = 10
    static let chipHorizontalPaddingPoints: CGFloat = 14
    static let chipVerticalPaddingPoints: CGFloat = 8
    static let stepperIconSizePoints: CGFloat = 34
    static let stepperHorizontalPaddingPoints: CGFloat = 22
    static let stepperVerticalPaddingPoints: CGFloat = 20
    static let stepperCornerRadiusPoints: CGFloat = 26
    static let optionMinimumHeightPoints: CGFloat = 78
    static let optionCornerRadiusPoints: CGFloat = 24
}

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
        HStack(spacing: SettingsControlMetrics.navigationRowSpacingPoints) {
            ZStack {
                RoundedRectangle(cornerRadius: SettingsControlMetrics.iconCornerRadiusPoints, style: .continuous)
                    .fill(iconBackgroundColor)
                    .frame(
                        width: SettingsControlMetrics.navigationIconSizePoints,
                        height: SettingsControlMetrics.navigationIconSizePoints)

                Image(systemName: icon)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: SettingsControlMetrics.subtitleSpacingPoints) {
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
                .frame(
                    width: SettingsControlMetrics.chevronSizePoints, height: SettingsControlMetrics.chevronSizePoints
                )
                .background(
                    Circle()
                        .fill(chevronBackgroundColor)
                )
        }
        .padding(.horizontal, SettingsControlMetrics.navigationHorizontalPaddingPoints)
        .padding(.vertical, SettingsControlMetrics.navigationVerticalPaddingPoints)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsControlMetrics.navigationCornerRadiusPoints, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsControlMetrics.navigationCornerRadiusPoints, style: .continuous)
                .strokeBorder(
                    borderColor,
                    lineWidth: isFocused
                        ? SettingsControlMetrics.focusedBorderWidthPoints
                        : SettingsControlMetrics.normalBorderWidthPoints)
        )
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: SettingsControlMetrics.navigationCornerRadiusPoints, style: .continuous)
                    .inset(by: SettingsControlMetrics.focusInsetPoints)
                    .strokeBorder(innerFocusBorderColor, lineWidth: SettingsControlMetrics.innerBorderWidthPoints)
            }
        }
        .shadow(color: focusShadowColor, radius: isFocused ? 16 : 0, x: 0, y: 0)
        .scaleEffect(
            isFocused ? SettingsControlMetrics.focusedScaleMultiplier : SettingsControlMetrics.restingScaleMultiplier
        )
        .animation(.easeInOut(duration: SettingsControlMetrics.focusAnimationDurationSeconds), value: isFocused)
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
        HStack(spacing: SettingsControlMetrics.stepperRowSpacingPoints) {
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(titleColor)
            }

            Spacer(minLength: 18)

            HStack(spacing: SettingsControlMetrics.actionSpacingPoints) {
                Text(LocalizedStringKey(value))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(valueColor)
                    .padding(.horizontal, SettingsControlMetrics.chipHorizontalPaddingPoints)
                    .padding(.vertical, SettingsControlMetrics.chipVerticalPaddingPoints)
                    .background(
                        Capsule(style: .continuous)
                            .fill(valueBackgroundColor)
                    )

                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(chevronColor)
                    .frame(
                        width: SettingsControlMetrics.stepperIconSizePoints,
                        height: SettingsControlMetrics.stepperIconSizePoints
                    )
                    .background(
                        Circle()
                            .fill(chevronBackgroundColor)
                    )
            }
        }
        .padding(.horizontal, SettingsControlMetrics.stepperHorizontalPaddingPoints)
        .padding(.vertical, SettingsControlMetrics.stepperVerticalPaddingPoints)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsControlMetrics.stepperCornerRadiusPoints, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsControlMetrics.stepperCornerRadiusPoints, style: .continuous)
                .strokeBorder(
                    borderColor,
                    lineWidth: isFocused
                        ? SettingsControlMetrics.focusedBorderWidthPoints
                        : SettingsControlMetrics.normalBorderWidthPoints)
        )
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: SettingsControlMetrics.stepperCornerRadiusPoints, style: .continuous)
                    .inset(by: SettingsControlMetrics.focusInsetPoints)
                    .strokeBorder(innerFocusBorderColor, lineWidth: SettingsControlMetrics.innerBorderWidthPoints)
            }
        }
        .shadow(color: focusShadowColor, radius: isFocused ? 16 : 0, x: 0, y: 0)
        .scaleEffect(
            isFocused ? SettingsControlMetrics.focusedScaleMultiplier : SettingsControlMetrics.restingScaleMultiplier
        )
        .opacity(isEnabled ? 1.0 : 0.52)
        .animation(.easeInOut(duration: SettingsControlMetrics.focusAnimationDurationSeconds), value: isFocused)
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
            .scaleEffect(
                hasVisualFocus
                    ? SettingsControlMetrics.focusedScaleMultiplier : SettingsControlMetrics.restingScaleMultiplier
            )
            .animation(
                .easeInOut(duration: SettingsControlMetrics.focusAnimationDurationSeconds), value: hasVisualFocus
            )
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
            // localization-audit: Stable UI test focus marker contract.
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
        HStack(spacing: SettingsControlMetrics.actionSpacingPoints) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 20, weight: .bold))

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .bold))
            }
        }
        .foregroundStyle(labelColor)
        .frame(maxWidth: .infinity, minHeight: SettingsControlMetrics.optionMinimumHeightPoints)
        .background(
            RoundedRectangle(cornerRadius: SettingsControlMetrics.optionCornerRadiusPoints, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsControlMetrics.optionCornerRadiusPoints, style: .continuous)
                .strokeBorder(
                    borderColor,
                    lineWidth: isFocused
                        ? SettingsControlMetrics.focusedBorderWidthPoints
                        : SettingsControlMetrics.normalBorderWidthPoints)
        )
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: SettingsControlMetrics.optionCornerRadiusPoints, style: .continuous)
                    .inset(by: SettingsControlMetrics.focusInsetPoints)
                    .strokeBorder(innerFocusBorderColor, lineWidth: SettingsControlMetrics.innerBorderWidthPoints)
            }
        }
        .shadow(color: focusShadowColor, radius: isFocused ? 14 : 0, x: 0, y: 0)
        .scaleEffect(
            isFocused ? SettingsControlMetrics.focusedScaleMultiplier : SettingsControlMetrics.restingScaleMultiplier
        )
        .animation(.easeInOut(duration: SettingsControlMetrics.focusAnimationDurationSeconds), value: isFocused)
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
