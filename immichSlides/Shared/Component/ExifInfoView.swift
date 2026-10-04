//
//  ExifInfoView.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/22.
//

import SwiftUI

// Only expresses a light/dark text scheme, so Color values are not scattered across components.

enum ExifForegroundTone: Equatable {
    case lightText
    case darkText

    // Stable value for UI tests and diagnostics; never localized.

    var debugAccessibilityLabel: String {
        switch self {
        case .lightText:
            return "lightText"
        case .darkText:
            return "darkText"
        }
    }

    // The light scheme is white text with a dark shadow, placed over darker backgrounds.

    var textColor: Color {
        switch self {
        case .lightText:
            return .white
        case .darkText:
            return .black
        }
    }

    // Black text gets a light white shadow, since a black shadow looks dirty on bright backgrounds.

    var shadowColor: Color {
        switch self {
        case .lightText:
            return .black.opacity(0.8)
        case .darkText:
            return .white.opacity(0.45)
        }
    }
}

struct ExifInfoView: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var asset: Asset
    var foregroundTone: ExifForegroundTone = .lightText
    private var layout: ViewLayoutTraits {
        ViewLayoutTraits(
            horizontalSizeClass: nil,
            verticalSizeClass: verticalSizeClass,
            userInterfaceIdiom: UIDevice.current.userInterfaceIdiom
        )
    }
    private var isPhone: Bool { layout.isPhone }
    private var isCompactHeight: Bool { layout.isCompactHeight }
    private var containerPadding: CGFloat { isPhone ? (isCompactHeight ? 10 : 12) : 20 }
    private var textSize: CGFloat { isPhone ? (isCompactHeight ? 12 : 14) : 18 }
    private var cornerRadius: CGFloat { isPhone ? 16 : 25 }

    // 2pt on phone, 8pt on TV, so the default HStack spacing is neither too loose nor too tight.

    private var iconTextSpacing: CGFloat { isPhone ? 2 : 8 }

    @ViewBuilder
    private func exifRow<Content: View>(
        iconName: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: iconTextSpacing) {
            Image(systemName: iconName)
            content()
        }
    }

    // The date keeps its first 10 characters and make/model are joined directly; width follows the content to
    // avoid empty space on the right.
    @ViewBuilder
    private func exifContent(exifInfo: ExifInfo) -> some View {
        VStack(alignment: .leading, spacing: isPhone ? 6 : 10) {
            if let make = exifInfo.make,
                let model = exifInfo.model
            {
                exifRow(iconName: "camera.fill") {
                    Text("\(make) \(model)")
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }
            if let fNumber = exifInfo.fNumber,
                let exposureTime = exifInfo.exposureTime,
                let iso = exifInfo.iso,
                let focalLength = exifInfo.focalLength
            {
                exifRow(iconName: "slider.horizontal.3") {
                    // localization-audit: exif-technical-values
                    Text(
                        "\(Int(focalLength))mm   ƒ/\(String(format: "%.1f", fNumber))   \(exposureTime)s   ISO \(String(format:"%d",iso))"
                    )
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                }
            }
            if let dataTimeOriginal = exifInfo.dateTimeOriginal {

                let date = String(dataTimeOriginal.prefix(10))
                exifRow(iconName: "calendar") {
                    Text("\(date)")
                }
            }
            if let city = exifInfo.city,
                let state = exifInfo.state,
                let country = exifInfo.country
            {
                VStack(alignment: .leading, spacing: isPhone ? 6 : 10) {
                    exifRow(iconName: "mappin.and.ellipse") {
                        Text("\(city), \(state)")
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }

                    exifRow(iconName: "globe") {
                        Text("\(country)")
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
            }
        }

        .fixedSize(horizontal: true, vertical: false)
    }

    var body: some View {

        guard let exifInfo = asset.exifInfo else {
            return AnyView(EmptyView())
        }

        let hasContent =
            exifInfo.make != nil || exifInfo.fNumber != nil || exifInfo.dateTimeOriginal != nil || exifInfo.city != nil

        guard hasContent else {
            return AnyView(EmptyView())
        }

        if #available(iOS 26.0, tvOS 26.0, *) {
            return AnyView(
                exifContent(exifInfo: exifInfo)
                    .padding(containerPadding)
                    .font(.system(size: textSize, weight: .semibold))
                    // The text color comes from the caller; both paths apply only a single shadow layer.

                    .foregroundStyle(foregroundTone.textColor)

                    .shadow(color: foregroundTone.shadowColor, radius: 10)
                    .glassEffect(.clear, in: .rect(cornerRadius: cornerRadius))
            )
        } else {
            return AnyView(
                exifContent(exifInfo: exifInfo)
                    .padding(containerPadding)
                    .font(.system(size: textSize, weight: .semibold))

                    .foregroundStyle(foregroundTone.textColor)

                    .shadow(color: foregroundTone.shadowColor, radius: 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(cornerRadius)

            )
        }

    }
}

#Preview {
    ExifInfoView(asset: Asset.previewAssets[0])
        .padding(200)
        .background(Color.green.opacity(0.5))
}

#Preview {
    ExifInfoView(asset: Asset.previewAssets[1])
        .padding(200)
        .background(Color.yellow.opacity(0.5))
}
