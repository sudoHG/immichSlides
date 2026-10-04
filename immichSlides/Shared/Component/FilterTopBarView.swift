import SwiftUI

struct FilterTopBarCommandHint: Identifiable {
    let id: String
    let iconName: String
    let title: String
    let detail: String
    let accent: Color
}

struct FilterTopBarView: View {

    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let summary: String?
    let layout: ViewLayoutTraits
    let onBack: () -> Void
    let onSelectAll: () -> Void
    let onClear: () -> Void
    var backButtonAccessibilityID: String? = nil
    var selectAllButtonAccessibilityID: String? = nil
    var clearButtonAccessibilityID: String? = nil
    var commandHintSummary: String? = nil
    var commandHints: [FilterTopBarCommandHint] = []
    var commandHintAccessibilityID: String? = nil

    private var sideWidth: CGFloat {
        // Widen the tvOS sides to 320 so Select All / Clear do not wrap.

        if layout.isTV { return 320 }
        if layout.isCompactHeight { return layout.isPhone ? 120 : 220 }
        if layout.isPhonePortrait { return 92 }
        return layout.isCompactWidth ? 130 : 240
    }

    private var backButtonSize: CGFloat {
        layout.isPhonePortrait ? 36 : 44
    }

    private var actionSpacing: CGFloat {
        if layout.isTV { return 14 }
        return layout.isPhonePortrait ? 6 : 10
    }

    private var horizontalPadding: CGFloat {
        if layout.isTV { return 24 }
        return layout.isCompactHeight ? 12 : (layout.isPhonePortrait ? 12 : 20)
    }

    private var verticalPadding: CGFloat {
        if layout.isTV { return 14 }
        return layout.isCompactHeight ? 8 : (layout.isPhonePortrait ? 6 : 12)
    }

    private var actionButtonMinWidth: CGFloat {
        // Give tvOS buttons a minimum width so Chinese labels are not squeezed into a vertical column.

        layout.isTV ? 96 : 0
    }

    private var shouldShowCommandHintRow: Bool {
        guard layout.isTV else { return false }
        let hasSummary = commandHintSummary?.isEmpty == false
        let hasItems = commandHints.isEmpty == false
        return hasSummary || hasItems
    }

    private var commandHintRowSpacing: CGFloat {
        layout.isTV ? 10 : 0
    }

    private var commandHintChipSpacing: CGFloat {
        layout.isTV ? 10 : 8
    }

    // Avoid pure white on the light glass bar so the helper row keeps enough contrast.

    private var commandHintDividerColor: Color {
        if colorScheme == .light {
            return Color.black.opacity(0.14)
        }
        return Color.white.opacity(0.10)
    }

    private var commandHintSummaryColor: Color {
        if colorScheme == .light {
            return Color.black.opacity(0.64)
        }
        return Color.white.opacity(0.70)
    }

    private var shouldShowSummary: Bool {
        // Hide the summary in iPhone portrait so it does not overlap the side buttons.

        guard let summary, summary.isEmpty == false else { return false }
        return layout.isPhonePortrait == false
    }

    /// iPhone uses icon buttons to save width; iPad keeps text buttons.
    private var shouldUseIconActionButtons: Bool {
        layout.isPhone
    }

    private var shouldUseCompactPhoneIconButtons: Bool {
        // In iPhone portrait, draw custom round buttons so the system glass does not spread over the title.

        layout.isPhonePortrait
    }

    var body: some View {
        VStack(spacing: shouldShowCommandHintRow ? commandHintRowSpacing : 0) {
            HStack(spacing: 12) {
                leftRegion
                centerRegion
                rightRegion
            }

            if shouldShowCommandHintRow {
                commandHintRegion
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity)
        .modifier(FilterTopBarBackgroundModifier())
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var leftRegion: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: layout.isPhonePortrait ? 15 : 18, weight: .semibold))
                    .frame(width: backButtonSize, height: backButtonSize)
            }
            .modifier(TopBarActionButtonStyleModifier(shouldUseCompactPhoneStyle: shouldUseCompactPhoneIconButtons))
            .accessibilityLabel(Text(LocalizedStringKey("Back")))
            .accessibilityIdentifier(backButtonAccessibilityID ?? "")
            Spacer(minLength: 0)
        }
        .frame(width: sideWidth)
    }

    private var centerRegion: some View {
        VStack(alignment: .center, spacing: shouldShowSummary ? 2 : 0) {
            Text(LocalizedStringKey(title))
                .font(.system(size: titleFontSize, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(titleMinimumScaleFactor)
                .allowsTightening(true)
                .clipped()
                .accessibilityIdentifier("filterTopBar.title")

            if shouldShowSummary, let summary {
                Text(LocalizedStringKey(summary))
                    .font(.system(size: summaryFontSize, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .accessibilityIdentifier("filterTopBar.summary")
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private var rightRegion: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: actionSpacing) {
                actionButton(systemIcon: "checkmark.circle", text: "Select All", action: onSelectAll)
                    .accessibilityLabel(Text(LocalizedStringKey("Select All")))
                    .accessibilityIdentifier(selectAllButtonAccessibilityID ?? "")
                actionButton(systemIcon: "xmark.circle", text: "Clear all", action: onClear)
                    .accessibilityLabel(Text(LocalizedStringKey("Clear all")))
                    .accessibilityIdentifier(clearButtonAccessibilityID ?? "")
            }
        }
        .frame(width: sideWidth, alignment: .trailing)
    }

    @ViewBuilder
    private func actionButton(systemIcon: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if shouldUseIconActionButtons {
                Image(systemName: systemIcon)
                    .font(.system(size: layout.isCompactHeight ? 13 : 15, weight: .semibold))
                    .frame(
                        width: layout.isCompactHeight ? 30 : (layout.isPhonePortrait ? 34 : 36),
                        height: layout.isCompactHeight ? 30 : (layout.isPhonePortrait ? 34 : 36)
                    )
            } else {
                Text(LocalizedStringKey(text))

                    .font(.system(size: layout.isTV ? 18 : 16, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.92)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: actionButtonMinWidth)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
            }
        }
        .modifier(TopBarActionButtonStyleModifier(shouldUseCompactPhoneStyle: shouldUseCompactPhoneIconButtons))
    }

    private var commandHintRegion: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(commandHintDividerColor)
                .frame(height: 1)

            HStack(alignment: .center, spacing: 16) {
                if let commandHintSummary, commandHintSummary.isEmpty == false {
                    Text(LocalizedStringKey(commandHintSummary))

                        .font(.system(size: layout.isTV ? 19 : 15, weight: .medium, design: .rounded))
                        .foregroundStyle(commandHintSummaryColor)
                        .lineLimit(1)
                        .minimumScaleFactor(layout.isTV ? 0.84 : 0.88)
                }

                Spacer(minLength: 0)

                if commandHints.isEmpty == false {
                    HStack(spacing: commandHintChipSpacing) {
                        ForEach(commandHints) { item in
                            commandHintChip(item)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(commandHintAccessibilityID ?? "")
    }

    private func commandHintChip(_ item: FilterTopBarCommandHint) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(item.accent.opacity(0.18))

                Image(systemName: item.iconName)
                    .font(.system(size: layout.isTV ? 15 : 13, weight: .bold))
                    .foregroundStyle(item.accent)
            }
            .frame(width: layout.isTV ? 34 : 30, height: layout.isTV ? 34 : 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(item.title))

                    .font(.system(size: layout.isTV ? 17 : 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(layout.isTV ? 0.86 : 1)

                Text(LocalizedStringKey(item.detail))

                    .font(.system(size: layout.isTV ? 16 : 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(1)
                    .minimumScaleFactor(layout.isTV ? 0.78 : 0.88)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    private var titleFontSize: CGFloat {
        if layout.isCompactHeight { return 18 }
        if layout.isPhonePortrait { return 18 }
        return layout.isCompactWidth ? 26 : 34
    }

    private var titleMinimumScaleFactor: CGFloat {
        // On narrow screens leave room to scale long localized titles so the right buttons do not cover them.

        layout.isPhonePortrait ? 0.64 : 0.86
    }

    private var summaryFontSize: CGFloat {
        if layout.isCompactHeight { return 12 }

        if layout.isTV { return 20 }
        return layout.isCompactWidth ? 15 : 18
    }
}

private struct FilterTopBarBackgroundModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, tvOS 26.0, *) {
            content
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(.clear)
                            .glassEffect(in: .rect)
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color(.blue).opacity(0.05))
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.24), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.15), radius: 18, x: 0, y: 8)
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        }
    }
}

private struct TopBarActionButtonStyleModifier: ViewModifier {
    let shouldUseCompactPhoneStyle: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if shouldUseCompactPhoneStyle {
            content
                .buttonStyle(.plain)
                .frame(width: 42, height: 42)
                // Declare a circular hit area explicitly so taps work outside the icon itself.

                .contentShape(Circle())
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                )
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 5)
        } else if #available(iOS 26.0, tvOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.appButtonRole(.secondary)
        }
    }
}
