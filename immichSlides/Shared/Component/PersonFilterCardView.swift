//
//  PersonFilterCardView.swift
//  immichSlides
//
//  Created by sudoHG on 2026/3/4.
//

import SwiftUI

struct PersonFilterCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var personName: String
    var personCoverURL: URL?
    var personAssetsCount: Int?
    @Binding var isSelected: Bool
    @Binding var matchMode: PersonMatchMode
    private var layout: ViewLayoutTraits {
        ViewLayoutTraits(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            userInterfaceIdiom: UIDevice.current.userInterfaceIdiom
        )
    }
    private var isCompact: Bool { layout.isCompactWidth }
    private var isCompactHeight: Bool { layout.isCompactHeight }
    private var cardCornerRadius: CGFloat { isCompact ? 22 : 30 }
    private var checkmarkSize: CGFloat { isCompactHeight ? 22 : 28 }
    // Aligned with the inset of the cover text area.
    private var contentHorizontalInset: CGFloat { isCompact ? 12 : 20 }
    // On iPhone, shrink the solo mode font so the lower half does not get too tall.
    private var toggleTitleSize: CGFloat { isCompact ? 13 : (isCompactHeight ? 14 : 16) }
    private var toggleSubtitleSize: CGFloat { isCompact ? 11 : (isCompactHeight ? 12 : 13) }

    var body: some View {

        VStack(spacing: 0) {

            ZStack(alignment: .topTrailing) {
                Group {

                    if let personCoverURL {
                        CoverCardView(name: personName, coverURL: personCoverURL, assetsCount: personAssetsCount)

                    } else {
                        placeholderCoverView
                    }
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: checkmarkSize, weight: .bold))
                    .foregroundStyle(isSelected ? Color.green : Color.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
                    .padding(isCompactHeight ? 10 : 16)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    isSelected.toggle()
                }
            }

            if isSelected {
                Toggle(
                    isOn: Binding(
                        get: { matchMode == .soloOnly },
                        set: { isSoloOnly in
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                matchMode = isSoloOnly ? .soloOnly : .normal
                            }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Solo Mode")
                            .font(.system(size: toggleTitleSize, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                        Text("Solo photos only")
                            .font(.system(size: toggleSubtitleSize, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                }
                .tint(.orange.opacity(0.85))
                .padding(.vertical, isCompact ? 6 : (isCompactHeight ? 8 : 10))
                .padding(.horizontal, contentHorizontalInset)
                .frame(maxWidth: .infinity, alignment: .leading)

                .background(Color.green.opacity(colorScheme == .dark ? 0.14 : 0.06))

                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }

        .frame(maxWidth: .infinity)
        .aspectRatio(isCompactHeight ? 1.0 : 3.0 / 4.0, contentMode: .fit)
        .background {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(colorScheme == .dark ? Color(red: 0.18, green: 0.18, blue: 0.20) : .white.opacity(0.9))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: isSelected ? 2.5 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 10)
    }

    private var placeholderCoverView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.ultraThinMaterial)

                Image(systemName: "person.fill")
                    .font(.system(size: isCompactHeight ? 54 : 72, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                LinearGradient(
                    colors: [.black.opacity(0.9), .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: geometry.size.height * 0.4)
                .frame(maxWidth: .infinity, alignment: .bottom)

                VStack(alignment: .leading) {
                    Text(personName)
                        .foregroundColor(.white)
                        .font(.system(size: isCompact ? 16 : (isCompactHeight ? 17 : 21), weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, contentHorizontalInset)
                    Text("Photo count unavailable")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.system(size: isCompact ? 12 : (isCompactHeight ? 14 : 18), weight: .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, contentHorizontalInset)
                }
                .shadow(radius: 30)
                .padding(.vertical, 5)
            }
            .clipped()
        }
    }

    private var borderColor: Color {
        if isSelected {
            return matchMode == .soloOnly
                ? Color.orange.opacity(0.75)
                : Color.green.opacity(0.8)
        }
        return PlatformCompat.separator.opacity(colorScheme == .dark ? 0.9 : 0.45)
    }
}

#Preview {
    PersonFilterCardPreview()
}

private struct PersonFilterCardPreview: View {

    @State private var isSelected: Bool = true
    @State private var matchMode: PersonMatchMode = .normal

    var body: some View {
        PersonFilterCardView(
            personName: "Sample Person 1",
            personCoverURL: URL(string: "https://example.invalid/preview/j6dG19_DY-.jpg")!,
            personAssetsCount: nil,
            isSelected: $isSelected,
            matchMode: $matchMode
        )
        .padding()
        .background(Color.gray.opacity(0.15))
    }
}
