import SwiftUI

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
        VStack(alignment: .leading, spacing: 14) {
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
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 6)
        .padding(.horizontal, outerHorizontalInset)
    }
}
