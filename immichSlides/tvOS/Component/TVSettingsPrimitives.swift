import SwiftUI

struct TVSettingsPageScaffold<Content: View>: View {
    let eyebrow: String
    let title: String
    let description: String
    let symbolName: String
    let accent: Color
    let secondaryAccent: Color
    let summary: String
    let summaryAccessibilityIdentifier: String?
    @ViewBuilder let content: Content

    init(
        eyebrow: String,
        title: String,
        description: String,
        symbolName: String,
        accent: Color,
        secondaryAccent: Color,
        summary: String,
        summaryAccessibilityIdentifier: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.description = description
        self.symbolName = symbolName
        self.accent = accent
        self.secondaryAccent = secondaryAccent
        self.summary = summary
        self.summaryAccessibilityIdentifier = summaryAccessibilityIdentifier
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            TVSettingsHeroPanel(
                eyebrow: eyebrow,
                title: title,
                description: description,
                symbolName: symbolName,
                accent: accent,
                secondaryAccent: secondaryAccent,
                summary: summary,
                summaryAccessibilityIdentifier: summaryAccessibilityIdentifier
            )
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TVSettingsHeroPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    let eyebrow: String
    let title: String
    let description: String
    let symbolName: String
    let accent: Color
    let secondaryAccent: Color
    let summary: String
    let summaryAccessibilityIdentifier: String?

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(colorScheme == .dark ? 0.92 : 0.76),
                                secondaryAccent.opacity(colorScheme == .dark ? 0.80 : 0.68)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 92, height: 92)

                Circle()
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.42), lineWidth: 1)
                    .frame(width: 92, height: 92)

                Image(systemName: symbolName)
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(colorScheme == .dark ? .white : .black)
            }

            VStack(alignment: .leading, spacing: 12) {
                if !eyebrow.isEmpty {
                    Text(LocalizedStringKey(eyebrow))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(2.2)
                }

                Text(LocalizedStringKey(title))
                    .font(.system(size: 50, weight: .heavy))
                    .foregroundStyle(.primary)

                if !description.isEmpty {
                    Text(LocalizedStringKey(description))
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !summary.isEmpty {
                    TVSettingsHeroSummaryBadge(
                        text: summary,
                        accent: accent,
                        secondaryAccent: secondaryAccent,
                        accessibilityIdentifier: summaryAccessibilityIdentifier
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(heroBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(heroBorderColor, lineWidth: 1)
        )
        .shadow(color: heroShadowColor, radius: 28, x: 0, y: 14)
    }

    private var heroBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.12, blue: 0.17).opacity(0.84)
            : Color.white.opacity(0.76)
    }

    private var heroBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.08)
    }

    private var heroShadowColor: Color {
        colorScheme == .dark
            ? .black.opacity(0.28)
            : secondaryAccent.opacity(0.08)
    }
}

private struct TVSettingsHeroSummaryBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    let text: String
    let accent: Color
    let secondaryAccent: Color
    let accessibilityIdentifier: String?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [accent, secondaryAccent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 10, height: 10)

            Text(LocalizedStringKey(text))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.08)
                        : Color.black.opacity(0.05)
                )
        )
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}

struct TVSettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            content
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(cardBorderColor, lineWidth: 1)
        )
        .shadow(color: cardShadowColor, radius: 24, x: 0, y: 12)
    }

    private var cardBackgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.09, green: 0.11, blue: 0.15).opacity(0.82)
            : Color.white.opacity(0.78)
    }

    private var cardBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.08)
    }

    private var cardShadowColor: Color {
        colorScheme == .dark
            ? .black.opacity(0.26)
            : Color(red: 0.18, green: 0.24, blue: 0.32).opacity(0.10)
    }
}

struct TVSettingsSectionBlock<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.primary)

                if let subtitle, subtitle.isEmpty == false {
                    Text(LocalizedStringKey(subtitle))
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
    }
}

struct TVSettingsActionRow: View {
    let title: String
    let value: String
    let valueTint: Color
    var isEnabled: Bool = true
    var accessibilityIdentifier: String? = nil
    let action: () -> Void

    var body: some View {
        TVSettingsFocusableControl(
            canFocus: isEnabled,
            accessibilityLabel: title,
            accessibilityValue: value,
            accessibilityIdentifier: accessibilityIdentifier,
            action: action
        ) {
            TVSettingsActionRowLabel(
                title: title,
                value: value,
                valueTint: valueTint,
                isEnabled: isEnabled
            )
        }
    }
}

struct TVSettingsReadOnlyRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let value: String
    var accessibilityIdentifier: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(LocalizedStringKey(value))
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.08)
                                : Color.black.opacity(0.05)
                        )
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.04)
                        : Color.black.opacity(0.03)
                )
        )
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}

struct TVSettingsStatusBanner: View {
    @Environment(\.colorScheme) private var colorScheme

    let text: String
    let tint: Color
    var accessibilityIdentifier: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)

            Text(LocalizedStringKey(text))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? tint.opacity(0.16)
                        : tint.opacity(0.12)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(tint.opacity(colorScheme == .dark ? 0.26 : 0.18), lineWidth: 1)
        )
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}

// Prominent banner for access protection results, so feedback isn't lost after the layout changes.

struct TVSettingsProminentResultBanner: View {
    @Environment(\.colorScheme) private var colorScheme

    let text: String
    let tint: Color
    let systemImage: String
    var accessibilityIdentifier: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(tint)

            Text(LocalizedStringKey(text))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? tint.opacity(0.24)
                        : tint.opacity(0.18)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(tint.opacity(colorScheme == .dark ? 0.42 : 0.30), lineWidth: 1.2)
        )
        .shadow(
            color: tint.opacity(colorScheme == .dark ? 0.20 : 0.12),
            radius: 14,
            x: 0,
            y: 4
        )
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}
