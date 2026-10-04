import SwiftUI

private enum SettingsSectionMetrics {
    static let spacingPoints: CGFloat = 14
    static let borderOpacity: Double = 0.06
    static let borderWidthPoints: CGFloat = 1
    static let shadowOpacity: Double = 0.06
    static let shadowRadiusPoints: CGFloat = 12
    static let shadowOffsetXPoints: CGFloat = 0
    static let shadowOffsetYPoints: CGFloat = 6
}

/// Settings section card; keeps corner radius, border, shadow and padding in one place.
struct SettingsSectionCardView<Content: View>: View {
    let innerHorizontalInset: CGFloat
    let innerVerticalInset: CGFloat
    let outerHorizontalInset: CGFloat
    let cornerRadius: CGFloat
    @ViewBuilder let content: Content

    init(
        innerHorizontalInset: CGFloat,
        innerVerticalInset: CGFloat,
        outerHorizontalInset: CGFloat,
        cornerRadius: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.innerHorizontalInset = innerHorizontalInset
        self.innerVerticalInset = innerVerticalInset
        self.outerHorizontalInset = outerHorizontalInset
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSectionMetrics.spacingPoints) {
            content
        }
        .padding(.horizontal, innerHorizontalInset)
        .padding(.vertical, innerVerticalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(PlatformCompat.systemBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    Color.black.opacity(SettingsSectionMetrics.borderOpacity),
                    lineWidth: SettingsSectionMetrics.borderWidthPoints)
        )
        .shadow(
            color: .black.opacity(SettingsSectionMetrics.shadowOpacity),
            radius: SettingsSectionMetrics.shadowRadiusPoints,
            x: SettingsSectionMetrics.shadowOffsetXPoints,
            y: SettingsSectionMetrics.shadowOffsetYPoints
        )
        .padding(.horizontal, outerHorizontalInset)
    }
}
